#!/bin/bash
# =============================================================================
# entrypoint.sh — Appbox App Entrypoint
# =============================================================================
#
# This script is the first thing that runs when the container starts. It
# handles the complete app lifecycle:
#
#   1. State detection (fresh install vs upgrade vs restart)
#   2. First-run configuration (create admin user, apply settings)
#   3. Platform callback (marked pending, then sent in the background once
#      the app answers, so it can never block the app from starting)
#   4. Privilege dropping and exec of the main app process
#
# NOTE: Password changes are handled by /moduser.sh (separate script).
# All apps MUST include moduser.sh for user password recovery.
#
# USER NAMESPACES (userns):
#   All Appbox containers run with user namespaces enabled. The entrypoint
#   runs as UID 0 INSIDE the container (which maps to an unprivileged UID
#   on the host). The app itself MUST run as UID 1000 inside the container.
#   All files and directories the app needs to access MUST be owned by
#   1000:1000 inside the container. The gosu command at the end of this
#   script drops from UID 0 to UID 1000 before exec'ing the app.
#
# CONTAINER STATES:
#
#   Two flags decide what happens on each start:
#     /etc/appbox_callback_pending  (container filesystem) the installed
#                                   callback has not been sent yet
#     /app/data/.appbox_setup_done  (persistent volume) the admin account has
#                                   been confirmed
#
#   FRESH INSTALL:
#     New container, no setup marker. The script starts the app temporarily,
#     creates the admin user, confirms it exists, writes the setup marker and
#     stops the app.
#
#   UPGRADE:
#     New container (the image was replaced), setup marker present. The script
#     skips user creation but still sends the callback and runs any migration
#     steps. An install made before the marker existed gets one setup pass
#     that only finds its admin and writes the marker.
#
#   SETUP FAILED:
#     The app could not confirm an admin account. The script fails closed: no
#     marker, no callback, the pending flag stays, and it exits 1 so the app's
#     open setup page is never served. Docker restarts the container
#     (unless-stopped) and setup runs again, as it does after a restart
#     part-way through first boot.
#
#   RESTART:
#     Callback already sent and setup marker present. The script skips all
#     setup and goes straight to running the app.
#
# WHY /etc/app_configured?
#   This file lives on the container's ephemeral filesystem, NOT on a
#   persistent volume. It is automatically deleted when the container image
#   is replaced (during upgrades), but survives normal restarts. This lets
#   us distinguish between "the container restarted" and "a new version was
#   deployed" without needing version tracking logic.
#
# WHY A SETUP MARKER INSTEAD OF "THE DATABASE EXISTS"?
#   The app creates its database before the admin account. If setup fails
#   after that, "the database exists" would make the next start look like an
#   upgrade and setup would never run again. The marker is written only after
#   the admin is confirmed.
#
# =============================================================================

# Enable debug output so all commands are logged to the container logs.
# Avoid unconditional `set -x`: expanded commands can expose installation
# passwords and callback tokens. Enable targeted tracing only around code that
# cannot process secrets.
set -e

# =============================================================================
# Constants
# =============================================================================

CONFIG_FLAG="/etc/app_configured"
SETUP_MARKER="/app/data/.appbox_setup_done"
APP_USER="1000:1000"
LOCAL_URL="http://localhost:3001"
READY_URL="${LOCAL_URL}/api/entry-page"
CALLBACK_PENDING_FLAG="/etc/appbox_callback_pending"
CALLBACK_HELPER="/usr/local/bin/appbox-installed-callback"
KUMA_ADMIN="/usr/local/bin/appbox-kuma-admin"

# =============================================================================
# Helper Functions
# =============================================================================

# Poll an HTTP endpoint until it responds successfully.
# Used to wait for the app to finish starting before calling its setup API.
#
# Usage: wait_for_http <url> [max_attempts] [sleep_seconds]
wait_for_http() {
    local url="$1"
    local attempts="${2:-60}"
    local sleep_seconds="${3:-2}"
    local i=0

    until curl -sf "${url}" >/dev/null 2>&1; do
        i=$((i + 1))
        if [[ "${i}" -ge "${attempts}" ]]; then
            echo "Timed out waiting for ${url}"
            return 1
        fi
        sleep "${sleep_seconds}"
    done
}

# UPTIME KUMA v2 SETUP — STAGE 1: Database Initialization
# Uptime Kuma v2 serves a database setup page until a database engine is
# chosen; its /api/entry-page then answers {"type":"setup-database"}. Choose
# SQLite if it asks (single file, no external DB needed, which fits the
# single-container model), then wait for the main server.
#
# ADAPTING FOR OTHER APPS:
#   Most apps don't need this step. If your app auto-initializes its database
#   on first start, just wait for it to answer.
ensure_database() {
    local attempts=90
    local i=0
    local info page

    while [[ "${i}" -lt "${attempts}" ]]; do
        page=$(curl -sf "${READY_URL}" 2>/dev/null)
        if [[ -n "${page}" && "${page}" != *'"setup-database"'* ]]; then
            return 0
        fi

        info=$(curl -sf "${LOCAL_URL}/setup-database-info" 2>/dev/null)
        if [[ "${info}" == *'"needSetup":true'* && "${info}" != *'"runningSetup":true'* ]]; then
            curl -fsS -o /dev/null \
                -H "Content-Type: application/json" \
                -X POST "${LOCAL_URL}/setup-database" \
                --data '{"dbConfig":{"type":"sqlite"}}' 2>/dev/null
        fi

        i=$((i + 1))
        sleep 2
    done

    echo "ERROR: Uptime Kuma did not finish starting"
    return 1
}

# UPTIME KUMA v2 SETUP — STAGE 2: Admin User Creation
# /usr/local/bin/appbox-kuma-admin talks to Uptime Kuma's Socket.IO API:
# `need-setup` prints true while it has no user and false once it has one;
# `setup` creates the admin from USERNAME and PASSWORD in the environment and
# prints ok or rejected. The credentials never reach a command line.
#
# Only needSetup decides that an admin exists. A refused setup while Uptime
# Kuma still needs one means the account was rejected (a weak password, for
# example): fail at once instead of reporting success. No answer at all is
# retried. Returns 0 once an admin exists, made now or already there.
#
# ALTERNATIVE APPROACHES FOR OTHER APPS:
#
#   1. Simple REST API (like Audiobookshelf). Build the body with jq from the
#      environment: a hand-built '{"password":"'"${PASSWORD}"'"}' is invalid
#      JSON once the password contains " or \, which complexPassword allows.
#      Then confirm from the app's own state that the admin exists; do not
#      treat an HTTP 400 as "already exists" (AGENTS.md rule 19).
#      jq -n '{username: env.USERNAME, password: env.PASSWORD}' \
#          | curl -s -o /dev/null -w '%{http_code}' 'http://localhost:PORT/init' \
#              -H 'Content-Type: application/json' --data-binary @-
#
#   2. CLI command (some apps provide setup commands):
#      /app/bin/setup --username "${USERNAME}" --password "${PASSWORD}"
#
#   3. Direct database manipulation (last resort):
#      sqlite3 /app/data/app.db "INSERT INTO users ..."
#
#   4. Configuration file generation. Write values with an encoder for the
#      file's format, never by pasting them into a heredoc: a quote, colon or
#      backslash in the password breaks the file. For YAML (a JSON document
#      is valid YAML):
#      jq -n '{admin_user: env.USERNAME, admin_pass: env.PASSWORD}' > /app/config.yml
ensure_admin_user() {
    local attempts=30
    local i=0
    local result

    while [[ "${i}" -lt "${attempts}" ]]; do
        case "$("${KUMA_ADMIN}" need-setup 2>/dev/null)" in
            false)
                echo "Uptime Kuma already has an admin account, skipping admin creation"
                return 0
                ;;
            true)
                result=$("${KUMA_ADMIN}" setup 2>/dev/null)
                if [[ "$("${KUMA_ADMIN}" need-setup 2>/dev/null)" == "false" ]]; then
                    if [[ "${result}" == "ok" ]]; then
                        echo "Admin user created successfully"
                    else
                        echo "Uptime Kuma has an admin account"
                    fi
                    return 0
                fi
                if [[ "${result}" == "rejected" ]]; then
                    echo "ERROR: Uptime Kuma rejected the admin account and still has no admin"
                    return 1
                fi
                ;;
        esac

        i=$((i + 1))
        sleep 2
    done

    echo "ERROR: Uptime Kuma still has no admin account after ${attempts} attempts"
    return 1
}

# =============================================================================
# Platform Callback
# =============================================================================
# Notify the Appbox platform that the app has finished its setup and is
# ready for the user to access.
#
# HOW IT WORKS:
#   With `expect_callback: true` in appbox.yml, the platform waits for one
#   POST to /v1/apps/installed/${INSTANCE_ID} before showing the app as
#   "installed". The /usr/local/bin/appbox-installed-callback helper sends it.
#
# NEVER BLOCK STARTUP ON THE CALLBACK:
#   The API accepts ONE installed callback per install or update. After that
#   (or after the platform sent it on the container's behalf, or a migration
#   finished) it answers 401 or another 4xx, and repeating the request can
#   never succeed. An `until curl -f ...; sleep 5; done` loop in front of
#   `exec` therefore keeps the app down forever. So:
#     - first boot only marks the callback as pending (CALLBACK_PENDING_FLAG);
#     - a background job sends it once the app answers, while `exec` starts
#       the app straight away;
#     - the helper retries only network errors, 408, 429 and 5xx, logs any
#       other status once and stops;
#     - the pending flag is removed after the attempt, so a restart while the
#       API is unreachable retries, but a rejected callback is not repeated.
#
# CALLBACK_REQUIRES_AUTH:
#   If `callback_requires_auth` is true in appbox.yml, the helper sends
#   CALLBACK_TOKEN in the X-Cylo-Callback-Token header. INSTANCE_ID may also
#   carry `?callback_token=...`. Both are secrets: never echo them, and do
#   not reference them in commands traced by `set -x`.
#
# SETTING CUSTOM FIELD VALUES (externalURL only):
#   Pass a JSON body to the helper to set clickable links, e.g.
#     "${CALLBACK_HELPER}" '{"custom_fields":[{"key":"ADMIN_PANEL","value":"https://..."}]}'
#   Only externalURL fields can be set this way. See README.md.
#
#   Note: if the URL is predictable (e.g. https://<domain>/), prefer using
#   template_type: instance with %DOMAIN.DOMAIN% in appbox.yml instead of
#   setting it via the callback. Only use the callback for URLs that depend
#   on runtime values (dynamic ports, generated paths, etc.).
#
# SKIP_APPBOX_CALLBACK:
#   Set SKIP_APPBOX_CALLBACK=1 for local development/testing to skip the
#   callback entirely (it would fail outside the platform anyway).
send_pending_callback() {
    # This runs in a background subshell. `set -e` (if enabled) is inherited
    # and would kill it when the readiness check times out.
    set +e

    if ! wait_for_http "${READY_URL}" 150 2; then
        echo "WARNING: app did not answer ${READY_URL}; sending the installed callback anyway."
    fi

    "${CALLBACK_HELPER}"
    rm -f "${CALLBACK_PENDING_FLAG}"
}

# =============================================================================
# STEP 1: First-Boot Detection
# =============================================================================
# On the first boot of this container image, mark the platform callback as
# pending BEFORE marking the container as configured, so a container that
# stops between the two still sends it on its next start. Do NOT call the API
# here: it would delay (or, if rejected, block) the app start. STEP 3 sends it
# in the background.

if [[ ! -f "${CONFIG_FLAG}" ]]; then
    touch "${CALLBACK_PENDING_FLAG}"
    touch "${CONFIG_FLAG}"
fi

# =============================================================================
# STEP 2: First-Run Setup
# =============================================================================
# Setup runs while the callback is pending and the setup marker is missing:
# on a fresh install, after a restart part-way through it, after a failed
# attempt, and once on the first update of an install made before the marker
# existed (where it only finds the existing admin).
#
#   1. Start the app in the background
#   2. Choose the database (Uptime Kuma v2 requires this)
#   3. Make sure the admin user exists, using the credentials from custom
#      fields, and write the setup marker only once it does
#   4. Stop the app (it is properly started at the end)
#
# WHY START AND STOP?
#   Many apps only allow initial setup through their web interface or API.
#   There's no CLI flag or config file for setting the initial admin user, so
#   the app must be running to call its setup endpoint. It is then stopped so
#   it can be cleanly started with `exec` as PID 1 at the end of this script.
#
# FAIL CLOSED:
#   Without a confirmed admin, the script exits 1: no marker, no callback,
#   the pending flag stays, and the app's open setup page is never served.
#   Docker restarts the container (unless-stopped) and setup runs again. See
#   AGENTS.md rule 19.
#
# ENVIRONMENT VARIABLES:
#   USERNAME and PASSWORD come from the custom_fields defined in appbox.yml.
#   The platform injects each custom field's value as an environment variable
#   using the field's key name.
#
# IMPORTANT: The setup marker MUST be inside a directory listed in the
# `volumes` section of appbox.yml. Otherwise it would not persist and every
# update would run setup again.

if [[ -f "${CALLBACK_PENDING_FLAG}" && ! -f "${SETUP_MARKER}" ]]; then
    echo "Setting up Uptime Kuma..."

    gosu "${APP_USER}" "$@" &
    APP_PID=$!

    if ensure_database && ensure_admin_user; then
        gosu "${APP_USER}" touch "${SETUP_MARKER}"
    fi

    # Stop the background app so it can be restarted with exec below.
    kill "${APP_PID}" 2>/dev/null || true
    wait "${APP_PID}" 2>/dev/null || true

    if [[ ! -f "${SETUP_MARKER}" ]]; then
        echo "ERROR: admin setup failed; the install is not reported as finished. It is retried on the next start."
        exit 1
    fi
else
    # UPGRADE or RESTART: the admin already exists. If your app needs explicit
    # migration steps during upgrades, run them here, for example:
    #
    #   /app/bin/migrate --run-pending
    #
    # Uptime Kuma handles migrations automatically on startup.
    echo "Existing setup found, skipping admin creation"
fi

# =============================================================================
# STEP 3: Send a Pending Callback in the Background
# =============================================================================
# The flag is set on the first boot of this image and removed after the
# attempt. It lives on the container filesystem like CONFIG_FLAG, so a restart
# before the API answered tries again.
if [[ -f "${CALLBACK_PENDING_FLAG}" ]]; then
    send_pending_callback &
fi

# =============================================================================
# STEP 4: Start the App
# =============================================================================
# This runs on EVERY container start (fresh install, upgrade, and restart),
# whether or not the callback has been sent or accepted.
#
# EXEC AND GOSU:
#   `exec` replaces the current shell process with the app process, making
#   the app PID 1 inside the container. This is critical because:
#     - Docker sends SIGTERM to PID 1 for graceful shutdown
#     - Without exec, the shell would be PID 1 and might not forward signals
#     - The app process would be orphaned if the shell exits
#
#   `gosu` drops privileges from root to the specified UID:GID. The entrypoint
#   runs as UID 0 inside the container (needed to write /etc/resolv.conf,
#   /etc/hosts, etc.) but the app itself MUST run as UID 1000 for security.
#
#   "1000:1000" is the UID:GID that ALL Appbox apps must use inside the
#   container. This is a hard requirement — do not use other UIDs.
#
#   "$@" expands to the CMD from the Dockerfile (e.g. "node server/server.js").

exec gosu "${APP_USER}" "$@"
