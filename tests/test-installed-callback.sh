#!/usr/bin/env bash
# Tests for the Appbox installed callback, run against a local mock API (needs
# bash, curl and python3; no Docker):
#   - appbox-installed-callback retries network errors, 408, 429 and 5xx,
#     stops after one try on any other status, sends CALLBACK_TOKEN in
#     X-Cylo-Callback-Token, passes an optional JSON body, and never logs the
#     callback token carried in INSTANCE_ID;
#   - entrypoint.sh execs the app straight away even when the API rejects the
#     callback, sends a pending callback once, and clears the pending flag;
#   - its admin setup (run against a stub appbox-kuma-admin) creates the admin
#     on a fresh install, only marks an existing admin on the first update,
#     retries after a restart part-way through, and fails closed when Uptime
#     Kuma rejects the account or never answers: exit 1, no setup marker, no
#     callback, pending flag kept.
#
# Usage: tests/test-installed-callback.sh
set -u

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
helper="${repo_root}/appbox-installed-callback"
token_id='999?callback_token=querytoken0123456789'
header_token='headertoken0123456789'

# Answers GET with 200 (readiness) and each POST with the next status from a
# comma-separated list, logging what it received.
mock_server='
import http.server, json, os, sys
port, codes, log = int(sys.argv[1]), [int(c) for c in sys.argv[2].split(",")], sys.argv[3]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"type": "entryPage"}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        seen = sum(1 for _ in open(log)) if os.path.exists(log) else 0
        code = codes[min(seen, len(codes) - 1)]
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "code": code, "body": body,
                                "token": self.headers.get("X-Cylo-Callback-Token", "")}) + "\n")
        self.send_response(code)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
'

failures=0
work=""
server=""

pass() { echo "ok   $*"; }
fail() {
    echo "FAIL $*"
    [[ -f "${work}/output" ]] && sed 's/^/     /' "${work}/output"
    failures=$((failures + 1))
}

start_mock() {
    work="$(mktemp -d)"
    port=$((20000 + RANDOM % 20000))
    python3 -c "${mock_server}" "${port}" "$1" "${work}/requests" &
    server=$!
    for _ in $(seq 1 50); do
        curl -s -o /dev/null "http://127.0.0.1:${port}/" && return 0
        sleep 0.1
    done
    echo "mock API did not start" >&2
    exit 2
}

stop_mock() {
    kill "${server}" 2>/dev/null
    wait "${server}" 2>/dev/null
    rm -rf "${work}"
}

# Run a command, killing it (exit 124) if it is still running after $1 seconds,
# so a callback that never stops fails the test instead of hanging it.
run_limited() {
    local limit=$1 pid ticks=0
    shift
    "$@" &
    pid=$!
    while kill -0 "${pid}" 2>/dev/null && [[ "${ticks}" -lt $((limit * 10)) ]]; do
        sleep 0.1
        ticks=$((ticks + 1))
    done
    if kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null
        wait "${pid}" 2>/dev/null
        return 124
    fi
    wait "${pid}"
}

request_count() { cat "${work}/requests" 2>/dev/null | wc -l | tr -d ' '; }
token_logged() { grep -cE 'querytoken|headertoken' "${work}/output"; }

# --- helper ------------------------------------------------------------------

helper_case() {
    local codes=$1 want_exit=$2 want_requests=$3
    shift 3
    start_mock "${codes}"
    run_limited 20 env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
        APPBOX_CALLBACK_RETRY_DELAY=1 \
        "$@" "${helper}" >"${work}/output" 2>&1
    local rc=$? requests leaked
    requests=$(request_count)
    leaked=$(token_logged)
    if [[ "${rc}" == "${want_exit}" && "${requests}" == "${want_requests}" && "${leaked}" == 0 ]]; then
        pass "helper codes=${codes} exit=${rc} requests=${requests}"
    else
        fail "helper codes=${codes} exit=${rc}/${want_exit} requests=${requests}/${want_requests} token_logged=${leaked}"
    fi
    stop_mock
}

helper_case 200 0 1
helper_case 401 1 1
helper_case 404 1 1
helper_case 409 1 1
helper_case 422 1 1
helper_case 503,502,200 0 3
helper_case 429,408,204 0 3
helper_case 500,401 1 2
helper_case 200 0 0 SKIP_APPBOX_CALLBACK=1

# Network errors are retried: nothing listens on the port for the first try.
work="$(mktemp -d)"
port=$((20000 + RANDOM % 20000))
(
    sleep 1.5
    exec python3 -c "${mock_server}" "${port}" 200 "${work}/requests"
) &
server=$!
run_limited 20 env INSTANCE_ID="${token_id}" APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    APPBOX_CALLBACK_RETRY_DELAY=1 "${helper}" >"${work}/output" 2>&1
rc=$?
if [[ "${rc}" == 0 ]] && grep -q 'HTTP 000, retrying' "${work}/output" && [[ "$(request_count)" == 1 ]]; then
    pass "helper retries a network error"
else
    fail "helper network error exit=${rc} requests=$(request_count)"
fi
stop_mock

# An invalid APPBOX_CALLBACK_RETRY_DELAY falls back to the 5s default.
start_mock 503,200
run_limited 20 env INSTANCE_ID="${token_id}" APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    APPBOX_CALLBACK_RETRY_DELAY='1;x' "${helper}" >"${work}/output" 2>&1
rc=$?
if [[ "${rc}" == 0 ]] && grep -q 'retrying in 5s' "${work}/output" && [[ "$(request_count)" == 2 ]]; then
    pass "helper ignores an invalid retry delay"
else
    fail "helper invalid retry delay exit=${rc} requests=$(request_count)"
fi
stop_mock

# Token header, query string and optional body reach the API.
start_mock 200
run_limited 20 env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
    APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    "${helper}" '{"custom_fields":[{"key":"ADMIN_PANEL","value":"https://example.test/"}]}' \
    >"${work}/output" 2>&1
if python3 - "${work}/requests" "${header_token}" <<'PY'
import json, sys
req = json.loads(open(sys.argv[1]).readline())
assert req["path"] == "/v1/apps/installed/999?callback_token=querytoken0123456789", req
assert req["token"] == sys.argv[2], req
assert json.loads(req["body"])["custom_fields"][0]["key"] == "ADMIN_PANEL", req
PY
then
    pass "helper sends path, X-Cylo-Callback-Token and body"
else
    fail "helper request contents"
fi
stop_mock


entrypoint="${repo_root}/entrypoint.sh"
# --- entrypoint ----------------------------------------------------------------

# Stand-in for appbox-kuma-admin. KUMA_STUB picks Uptime Kuma's state:
#   admin       a user exists (needSetup false)
#   fresh       no user; setup succeeds and needSetup turns false
#   rejected    no user; setup is refused
#   down        Uptime Kuma never answers
# Each call is logged to $KUMA_STUB_LOG.
kuma_stub='#!/bin/bash
echo "$1" >>"${KUMA_STUB_LOG}"
state="${KUMA_STUB_LOG}.created"
case "${KUMA_STUB}:$1" in
    admin:need-setup) echo false ;;
    fresh:need-setup) [[ -f "${state}" ]] && echo false || echo true ;;
    fresh:setup) touch "${state}"; echo ok ;;
    rejected:need-setup) echo true ;;
    rejected:setup) echo rejected ;;
    *) exit 1 ;;
esac'

# Run a copy of entrypoint.sh with its paths pointed into a scratch directory,
# gosu removed, short sleeps, the stub above as appbox-kuma-admin and a fake
# app as CMD that records when it first started.
#   entrypoint_case <state> <stub> <codes> <want_exit> <want_requests> <want_setups>
#   state: fresh (nothing), upgrade (data only, no setup marker), updated
#   (setup marker only), restart-pending (CONFIG_FLAG, pending flag and setup
#   marker), restart-setup (CONFIG_FLAG and pending flag, no marker) or
#   restart (CONFIG_FLAG and setup marker).
entrypoint_case() {
    local state=$1 stub=$2 codes=$3 want_exit=$4 want_requests=$5 want_setups=$6
    start_mock "${codes}"
    local sandbox="${work}/entrypoint.sh"
    printf '%s\n' "${kuma_stub}" >"${work}/kuma-admin"
    chmod +x "${work}/kuma-admin"
    sed -e "s|^CONFIG_FLAG=.*|CONFIG_FLAG=\"${work}/app_configured\"|" \
        -e "s|^SETUP_MARKER=.*|SETUP_MARKER=\"${work}/setup_done\"|" \
        -e "s|^LOCAL_URL=.*|LOCAL_URL=\"http://127.0.0.1:${port}\"|" \
        -e "s|^CALLBACK_PENDING_FLAG=.*|CALLBACK_PENDING_FLAG=\"${work}/callback_pending\"|" \
        -e "s|^CALLBACK_HELPER=.*|CALLBACK_HELPER=\"${helper}\"|" \
        -e "s|^KUMA_ADMIN=.*|KUMA_ADMIN=\"${work}/kuma-admin\"|" \
        -e 's|^\([[:space:]]*\)gosu "${APP_USER}" "$@" &$|\1"$@" \&|' \
        -e 's|gosu "${APP_USER}" touch|touch|' \
        -e 's|^\([[:space:]]*\)sleep 2$|\1sleep 0.05|' \
        -e 's|^exec gosu "${APP_USER}" "$@"$|exec "$@"|' \
        "${entrypoint}" >"${sandbox}"
    chmod +x "${sandbox}"
    if ! grep -q '^exec "\$@"$' "${sandbox}" || grep -v '^[[:space:]]*#' "${sandbox}" | grep -q 'gosu'; then
        fail "entrypoint ${state}: could not sandbox gosu and the final exec"
        stop_mock
        return
    fi

    case "${state}" in
        upgrade) touch "${work}/kuma.db" ;;
        updated) touch "${work}/setup_done" ;;
        restart-pending) touch "${work}/app_configured" "${work}/callback_pending" "${work}/setup_done" ;;
        restart-setup) touch "${work}/app_configured" "${work}/callback_pending" ;;
        restart) touch "${work}/app_configured" "${work}/setup_done" ;;
    esac

    local started_at app_at entrypoint_pid rc waited=0
    started_at=$(date +%s)
    env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
        APPBOX_CALLBACK_RETRY_DELAY=1 \
        KUMA_STUB="${stub}" KUMA_STUB_LOG="${work}/kuma-calls" \
        "${sandbox}" bash -c "[[ -f '${work}/app_started' ]] || date +%s >'${work}/app_started'; sleep 1" \
        >"${work}/output" 2>&1 &
    entrypoint_pid=$!

    # A callback or setup that blocks would never finish; give up after 15s
    # instead of hanging.
    while kill -0 "${entrypoint_pid}" 2>/dev/null && [[ "${waited}" -lt 15 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "${entrypoint_pid}" 2>/dev/null; then
        pkill -P "${entrypoint_pid}" 2>/dev/null
        kill "${entrypoint_pid}" 2>/dev/null
    fi
    wait "${entrypoint_pid}"
    rc=$?

    # The background sender outlives the fake app; wait for it to finish.
    waited=0
    while [[ "${want_exit}" == 0 && -f "${work}/callback_pending" && "${waited}" -lt 20 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    sleep 0.5

    app_at=$(cat "${work}/app_started" 2>/dev/null || echo 0)
    local requests leaked setups marker pending
    requests=$(request_count)
    leaked=$(token_logged)
    setups=$(grep -cx setup "${work}/kuma-calls" 2>/dev/null)
    marker=$([[ -f "${work}/setup_done" ]] && echo yes || echo no)
    pending=$([[ -f "${work}/callback_pending" ]] && echo yes || echo no)
    local want_marker=yes want_pending=no
    if [[ "${want_exit}" != 0 ]]; then
        want_marker=no want_pending=yes
    fi
    if [[ "${rc}" == "${want_exit}" && "${app_at}" -gt 0 && $((app_at - started_at)) -le 2 \
        && -f "${work}/app_configured" && "${requests}" == "${want_requests}" \
        && "${setups:-0}" == "${want_setups}" && "${marker}" == "${want_marker}" \
        && "${pending}" == "${want_pending}" && "${leaked}" == 0 ]]; then
        pass "entrypoint ${state} stub=${stub} codes=${codes}: exit=${rc} marker=${marker} pending=${pending} requests=${requests} setups=${setups:-0}"
    else
        fail "entrypoint ${state} stub=${stub} codes=${codes}: exit=${rc}/${want_exit} app_started=${app_at} start=${started_at} marker=${marker}/${want_marker} pending=${pending}/${want_pending} requests=${requests}/${want_requests} setups=${setups:-0}/${want_setups} token_logged=${leaked}"
    fi
    if [[ "${want_exit}" != 0 ]] && ! grep -q '^ERROR: admin setup failed' "${work}/output"; then
        fail "entrypoint ${state} stub=${stub}: no admin setup failure in the log"
    fi
    stop_mock
}

entrypoint_case fresh fresh 200 0 1 1
entrypoint_case fresh rejected 200 1 0 1
entrypoint_case fresh down 200 1 0 0
entrypoint_case upgrade admin 200 0 1 0
entrypoint_case upgrade admin 401 0 1 0
entrypoint_case updated down 200 0 1 0
entrypoint_case restart-pending down 503,200 0 2 0
entrypoint_case restart-setup fresh 200 0 1 1
entrypoint_case restart down 200 0 0 0

if grep -qE '^[[:space:]]*set -x' "${entrypoint}"; then
    fail "entrypoint.sh traces commands with set -x"
else
    pass "entrypoint.sh does not trace commands"
fi

exit "${failures}"
