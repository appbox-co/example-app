---
description:
alwaysApply: false
---

# AGENTS.md

This repository is an Appbox example app — a reference implementation for packaging apps for the [Appbox](https://appbox.co) platform. AI coding agents are welcome to use this as a template when creating new Appbox apps.

## AI-Generated Code Policy

You are welcome to use AI/LLM tools to create Appbox apps. However:

- **All AI-generated code MUST be reviewed by a human before submission.** No exceptions.
- Appbox performs a thorough review of every submitted app. We expect all code to be pre-checked by the submitter before it reaches us.
- Do not blindly trust generated Dockerfiles, entrypoint scripts, or config files. Verify that they work, are secure, and follow the conventions documented here.
- If you are an AI agent: flag any assumptions or uncertainties to the human reviewer. Do not silently guess at security-sensitive values.

## Project Structure

```
example-app/
├── AGENTS.md        # This file — instructions for AI agents
├── appbox.yml       # App configuration (metadata, ports, volumes, env, fields)
├── Dockerfile       # Container image definition
├── entrypoint.sh    # Lifecycle script (setup, upgrade, callback)
├── appbox-installed-callback  # Sends the installed callback (copy as-is)
├── icon.png         # App icon (512x512 PNG) for the store listing
├── moduser.sh       # Password change script (required for all apps)
├── README.md        # Full documentation and schema reference
├── TESTING.md       # Testing framework — complete before submitting
└── tests/
    └── test-installed-callback.sh  # Callback helper and entrypoint tests
```

## Key Constraints

When creating or modifying an Appbox app, always follow these rules:

1. **Single container** — Everything in one Docker container. No docker-compose, no sidecars, no external database containers. If the app needs a database, embed it (e.g. SQLite) or bundle it inside the same container.

2. **Architecture `linux/amd64`** — All images MUST be built for `linux/amd64`. The platform runs exclusively on x86_64 hosts. When building on an ARM machine (e.g. Apple Silicon), always pass `--platform linux/amd64` to `docker build` and `docker run`. If the app downloads architecture-specific binaries, use Docker's `TARGETARCH` build arg to select the correct variant.

3. **UID 1000** — The app process MUST run as UID 1000 inside the container. All data directories MUST be owned by 1000:1000. The entrypoint runs as root only for setup, then drops to 1000 via `gosu`. This is a hard requirement.

4. **User namespaces** — All containers run with userns enabled. UID 0 inside the container is NOT root on the host. Never assume host-level root access.

5. **Entrypoint lifecycle** — The entrypoint script must follow this pattern:
   - Check `/etc/app_configured` to detect first boot vs restart
   - Fresh install: start app, configure admin user, stop app. If the admin account cannot be confirmed, fail closed (see rule 19)
   - Upgrade: skip user creation (setup already confirmed), run migrations if needed
   - Mark the platform callback (`POST https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}`) as pending, then send it **in the background** with `appbox-installed-callback`. Never make `exec`, cont-init or an s6 oneshot wait for it. See [Platform Callback](#platform-callback).
   - Start app with `exec gosu 1000:1000 "$@"`

6. **Secure by default** — Use `complexPassword` validation for admin passwords. Disable public registration. Never hardcode credentials.

7. **Volume UID** — Set `uid: 1000` in all volume definitions in `appbox.yml`.

8. **Prefer upstream images** — Build on official, well-maintained Docker images rather than building from scratch. If the app needs multiple services running in a single container (e.g. app + database + worker), you MUST use **s6-overlay** as the init/process supervisor — it handles process lifecycle, restarts, and signal forwarding correctly. For single-process apps, a plain bash entrypoint with `exec` is fine. Any init system is acceptable when reusing upstream images.

9. **moduser.sh** — All apps MUST include `/moduser.sh` in the container. It accepts one argument (`new_password`) and overwrites the default user's password. This is used for account recovery when a user is locked out.

10. **Web app ports** — If your app is a web app (`is_web_app: true`) and only serves a web UI, do NOT define ports in the `ports` section. The platform reverse-proxies HTTP via nginx automatically. Instead, set a `VIRTUAL_PORT` env var to the HTTP port your app listens on (default is 80). This must always be a plain HTTP port — the platform handles SSL. Defining the HTTP port in `ports` would expose it publicly, bypassing the reverse proxy and SSL.

11. **Shared file system** — If the app needs to read or write data from other
apps, use `shared_data` with the documented platform source template and a
container-visible destination such as `/APPBOX_DATA`. Do not use shared data
for the app's own configuration or database; keep app state in normal
persistent volumes.

12. **Declarative actions** — If the app uses Custom Tables or Custom Buttons, define explicit typed operations backed by a fixed manager executable in the app image. Use stable table, field, button, and operation IDs across compatible versions. Never build shell commands from row or form values. Pass validated JSON through stdin and mark credentials as sensitive. See `CUSTOM_TABLES.md`.

13. **Immutable action releases** — Typed operations require an immutable released image containing the exact declared manager. Do not publish an action-enabled version that relies only on a mutable image tag.

14. **Conditional installation fields** — Use `condition` with another field's
manifest key for optional or mutually exclusive install inputs. Prefer
`clear_when_hidden: true` for credentials. Conditions affect presentation and
submission only; they must never replace server-side or manager validation.
See the main README for the supported operators and complete examples.

15. **Conditional Custom Buttons** — Use `visibility_conditions` only with
declared, non-sensitive installation fields. All conditions must match. Missing
fields fail closed, and `in`/`not_in` use a YAML list in `value`. The platform
must enforce the conditions at execution time; frontend hiding is never an
authorization boundary. See `CUSTOM_TABLES.md`.

16. **Sensitive field reveal policy** — Declare `sensitive: true` for every
stored credential. Such fields are write-only by default: the importer stores
an omitted `revealable` as `false`. The initial admin or login password the
owner signs in with must set `sensitive: true`, `revealable: true` and
`params.showOnInstalled: true`, so the owner can Show it on the installed app.
Add `revealable: true` to other credentials only when an authorized instance
owner must recover them; never expose any of them in ordinary responses, logs,
or errors.

17. **Operation readiness** — Platform/container readiness only permits typed-operation dispatch. Docker `HEALTHCHECK` is optional and does not prove operation readiness or success. Managers must use bounded, operation-specific readiness checks, verify authoritative postconditions, and return non-zero when success cannot be established. Treat `initial_rows_operation` as part of install completion and make it idempotent and convergent after partial work.

18. **Version variants** — Mark an extra build of a release with a letters-only variant suffix, such as `3.3.5-ml`, and keep the standard build unsuffixed. Update keeps an instance on its variant. Put build revisions before the variant (`3.3.5-1-ml`, never `3.3.5-ml-1`), and never end a version with letters unless it is a variant (use `1.0.0-beta1`, not `1.0.0-beta`). See "Version strings and variants" in `README.md`.

19. **Initial admin setup** — Create the admin account from the install fields
and report the install finished only once the app confirms the account exists.
   - Build request bodies and config files with an encoder, never by shell
     string interpolation: `jq -n '{email: env.EMAIL, password: env.PASSWORD}' | curl --data-binary @-`.
     `complexPassword` allows `"`, `\`, `'` and `$`, and a hand-built body
     breaks on them. Reading the values from the environment also keeps them
     off command lines.
   - Decide that an admin already exists from the app's own state (for
     example Immich's `GET /api/server/config` `isInitialized`), checked
     before and after the request. Never infer it from an HTTP status such as
     400, which also means "invalid request".
   - Fail closed when setup cannot be confirmed. Do not write the persistent
     setup marker, do not send the installed callback, and do not leave the
     app serving an open setup or sign-up page. Keep the pending flag so the
     next start retries. A single-process app can exit non-zero; containers run
     with `unless-stopped`, so Docker restarts it and setup runs again. Under
     s6, stop the web service's whole process group: `s6-svc -d` signals only
     the service's main process, and a child worker can keep the port open.
   - Mark setup as done with a persistent marker written only after success,
     not with "the data directory exists". Otherwise a failed first attempt
     looks like an upgrade on the next start and setup never runs again.
   - A restart part-way through first boot must finish setup before it sends
     the pending callback.
   - Never log the password, request bodies or the app's error bodies, which
     can echo submitted values.

## appbox.yml

The `appbox.yml` file is the single source of truth for app configuration. See `README.md` for the full schema reference.

- Only `app` and `image` sections are required; all others have defaults.
- Template variables use `%TABLE.FIELD%` syntax (ALL CAPS), e.g. `%INSTANCE.ID%`, `%PORTS|0.EXTERNAL%`.
- Custom fields become environment variables inside the container, keyed by the field name.
- Fields of type `externalURL` render as clickable links on the installed app page. For predictable URLs, set `default_value` to a template like `https://%DOMAIN.DOMAIN%/` with `template_type: instance` — the platform resolves this at install time. For URLs only known at runtime (dynamic ports, generated paths), set the value via the API callback instead (include `custom_fields` array in the POST body). For other field type updates via callback, contact support.
- Use `shared_data` with the documented platform source template when the app
  needs access to other apps' data.
- Do not include fields that are platform-managed (e.g. `privileged`, `security_opt`, `network_mode`, `dns`, `type`, `registry`). They will be ignored.
- Optional `custom_tables`, `custom_buttons`, and `typed_operations` are documented in `CUSTOM_TABLES.md`. Do not add them unless the image contains and tests the fixed manager executable.

## Dockerfile Pattern

### Single-process apps

```dockerfile
FROM <upstream-image>:<tag>
RUN <install bash, curl, gosu>
ADD entrypoint.sh /entrypoint.sh
ADD moduser.sh /moduser.sh
COPY appbox-installed-callback /usr/local/bin/appbox-installed-callback
RUN chmod +x /entrypoint.sh /moduser.sh /usr/local/bin/appbox-installed-callback
ENTRYPOINT ["/entrypoint.sh"]
CMD [<app's default command>]
EXPOSE <internal port>
```

- Always install `bash`, `curl`, and `gosu`.
- For Debian/Ubuntu images: `apt-get install -y --no-install-recommends bash curl gosu && rm -rf /var/lib/apt/lists/*`
- For Alpine images: `apk add --no-cache bash curl gosu`
- Use `ENTRYPOINT` + `CMD` split so the entrypoint handles setup and CMD can be overridden for debugging.

### Multi-service apps (s6-overlay)

When bundling multiple services (e.g. app + PostgreSQL + Redis) in a single container, use s6-overlay for process supervision. If building on a LinuxServer.io (LSIO) base image, s6-overlay is already included.

```dockerfile
FROM <lsio-or-s6-base-image>

# Install additional services (e.g. database, cache)
RUN apt-get update && apt-get install -y --no-install-recommends \
        postgresql-14 redis-server gosu && \
    rm -rf /var/lib/apt/lists/*

# Define s6 longrun services (one directory per service)
RUN mkdir -p /etc/s6-overlay/s6-rc.d/svc-postgres && \
    echo "longrun" > /etc/s6-overlay/s6-rc.d/svc-postgres/type && \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-postgres
COPY svc-postgres-run /etc/s6-overlay/s6-rc.d/svc-postgres/run
RUN chmod +x /etc/s6-overlay/s6-rc.d/svc-postgres/run

# CRITICAL: Add explicit s6 dependencies (see "s6 Dependency Ordering" below)
RUN mkdir -p /etc/s6-overlay/s6-rc.d/svc-postgres/dependencies.d && \
    touch /etc/s6-overlay/s6-rc.d/svc-postgres/dependencies.d/legacy-cont-init

ADD entrypoint.sh /entrypoint.sh
ADD moduser.sh /moduser.sh
COPY appbox-installed-callback /usr/local/bin/appbox-installed-callback
RUN chmod +x /entrypoint.sh /moduser.sh /usr/local/bin/appbox-installed-callback
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/init"]
EXPOSE <internal port>
```

- `CMD ["/init"]` hands off to s6-overlay after the entrypoint completes.
- The entrypoint runs one-time setup (database init, etc.) BEFORE `/init` starts, then `exec "$@"` to hand off.
- Each s6 service needs a `run` script that execs the process in the foreground (no daemonizing):
  ```bash
  #!/bin/bash
  exec gosu 1000:1000 /usr/lib/postgresql/14/bin/postgres -D /config/postgres
  ```

## entrypoint.sh Pattern

### Single-process apps

```bash
#!/bin/bash
set -e

APP_USER="1000:1000"
LOCAL_URL="http://localhost:<port>"
CALLBACK_PENDING_FLAG="/etc/appbox_callback_pending"
SETUP_MARKER="<volume>/.appbox_setup_done"   # persistent; written only after confirmed setup

# ... wait_for_http, ensure_admin_user (see rule 19) ...

send_pending_callback() {
    set +e   # runs in the background; never let a timeout kill it
    wait_for_http "${LOCAL_URL}/<health-path>" 150 2 || true
    /usr/local/bin/appbox-installed-callback
    rm -f "${CALLBACK_PENDING_FLAG}"
}

if [[ ! -f /etc/app_configured ]]; then
    touch "${CALLBACK_PENDING_FLAG}"   # first, and do NOT call the API here
    touch /etc/app_configured
fi

if [[ -f "${CALLBACK_PENDING_FLAG}" && ! -f "${SETUP_MARKER}" ]]; then
    # FRESH INSTALL, or an earlier attempt did not finish: start app, set up, stop
    gosu "${APP_USER}" "$@" &
    app_pid=$!
    # ... wait for ready ...
    ensure_admin_user && touch "${SETUP_MARKER}"
    kill "${app_pid}"; wait "${app_pid}" || true
    if [[ ! -f "${SETUP_MARKER}" ]]; then
        # Fail closed: no callback, nothing serving; Docker restarts the
        # container (unless-stopped) and the next start retries.
        echo "ERROR: admin setup failed; the install is not reported as finished"
        exit 1
    fi
fi
# UPGRADE (marker present): skip user creation; run migrations if needed

if [[ -f "${CALLBACK_PENDING_FLAG}" ]]; then
    send_pending_callback &   # background: the app starts whatever the API says
fi

exec gosu "${APP_USER}" "$@"
```

### Multi-service apps (s6-overlay)

When s6-overlay manages the services, the entrypoint handles one-time setup then hands off to `/init`. The app lifecycle (admin creation, callback) runs in a **background subshell** since `exec "$@"` (which becomes `exec /init`) takes over the process.

```bash
#!/bin/bash
set -e

APP_USER="1000:1000"
CONFIG_FLAG="/etc/app_configured"
FRESH_MARKER="/config/.app_configured"   # persistent marker in volume
LOCAL_URL="http://localhost:8080"
CALLBACK_PENDING_FLAG="/etc/appbox_callback_pending"

# ... helper functions (wait_for_http, create_admin_user) ...

# === One-time setup (runs BEFORE s6-overlay /init) ===
# Initialize database directories, run migrations, etc.
# These steps happen once and must complete before services start.
mkdir -p /config/database
chown -R 1000:1000 /config/database

# === Appbox lifecycle in a background subshell ===
if [[ ! -f "${CONFIG_FLAG}" ]]; then
    touch "${CALLBACK_PENDING_FLAG}"   # before CONFIG_FLAG
    touch "${CONFIG_FLAG}"
fi

if [[ -f "${CALLBACK_PENDING_FLAG}" ]]; then
    (
        set +e   # CRITICAL: prevent set -e from killing the subshell on timeout

        if [[ ! -f "${FRESH_MARKER}" ]]; then
            # Also runs after a restart part-way through first boot.
            echo "Fresh install, waiting for app..."
            wait_for_http "${LOCAL_URL}/api/health" 300 2
            if ! ensure_admin_user; then   # see rule 19
                # Fail closed: no marker, no callback, pending flag kept, and
                # the web service's process group stopped until the next start.
                echo "ERROR: admin setup failed; the install is not reported as finished"
                stop_web_service
                exit 1
            fi
            touch "${FRESH_MARKER}"
        else
            echo "Upgrade detected"
            wait_for_http "${LOCAL_URL}/api/health" 300 2
        fi

        /usr/local/bin/appbox-installed-callback
        rm -f "${CALLBACK_PENDING_FLAG}"
    ) &
fi

# Hand off to s6-overlay
exec "$@"
```

**Key differences from single-process pattern:**
- `set -e` is preferred. Do not enable unconditional `set -x`; expanded commands can expose passwords and tokens in logs.
- The lifecycle subshell uses `set +e` to prevent inherited `set -e` from killing it when `wait_for_http` times out.
- Use a generous timeout (300 × 2s = 10 min) for `wait_for_http` since s6 init scripts may take time before services start.
- `stop_web_service` must close the port. Read the service's pid with `/command/s6-svstat -o pid /run/service/<svc>`, run `/command/s6-svc -d`, then `kill -TERM -- -<pid>` for its process group. Escalate to `SIGKILL` if the port still answers, and finish with `/command/s6-svwait -D`. Immich's `immich-api` worker kept serving after a plain `s6-svc -d`. CyloTech/immich `entrypoint.sh` (`stop_immich_server`) is a tested example.
- `exec "$@"` becomes `exec /init` (from CMD), NOT `exec gosu ... "$@"`. s6-overlay's service `run` scripts handle user switching via `gosu` or `s6-setuidgid`.

### Setup in cont-init or an s6 oneshot (LSIO images)

When first-run setup lives in `/etc/cont-init.d/` or an `init-*` oneshot instead of the entrypoint, s6 waits for it to finish before starting services. Never call the API there. Mark the callback pending and send it from a longrun service:

```bash
# /etc/cont-init.d/50-appbox (or your init-config-<app> oneshot)
if [[ ! -f /etc/app_configured ]]; then
    touch /etc/appbox_callback_pending   # before the configured marker
    touch /etc/app_configured
    # ... first-run setup ...
fi
```

```bash
#!/command/with-contenv bash
# /etc/s6-overlay/s6-rc.d/svc-appbox-callback/run   (type: longrun)
if [[ -f /etc/appbox_callback_pending ]]; then
    # optional: wait_for_http "http://localhost:<port>/<health-path>" 300 2
    /usr/local/bin/appbox-installed-callback
    rm -f /etc/appbox_callback_pending
fi
exec s6-pause   # stay up so s6 does not restart it and send the callback again
```

```dockerfile
RUN mkdir -p /etc/s6-overlay/s6-rc.d/svc-appbox-callback/dependencies.d && \
    echo longrun > /etc/s6-overlay/s6-rc.d/svc-appbox-callback/type && \
    touch /etc/s6-overlay/s6-rc.d/svc-appbox-callback/dependencies.d/legacy-cont-init && \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-appbox-callback
COPY svc-appbox-callback-run /etc/s6-overlay/s6-rc.d/svc-appbox-callback/run
```

If setup runs in an `init-config-<app>` oneshot, add that to `dependencies.d` as well. On s6-overlay v2 images (`/etc/services.d/`), put the same `run` script in `/etc/services.d/appbox-callback/run` with `#!/usr/bin/with-contenv bash`.

## Platform Callback

With `behavior.expect_callback: true`, Appbox shows the app as "installing" until the container sends `POST https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}`. Use the `appbox-installed-callback` helper from this repo unchanged; it implements these rules:

- **Never block startup on it.** The API accepts one installed callback per install or update. After that, when the platform has already sent it for the container, or after a migration has finished, it answers 401 or another 4xx, and retrying will not change that. An `until curl -f ...; sleep 5; done` loop in front of `exec`, in cont-init or in an s6 oneshot keeps the app down until someone restarts it by hand. Send the callback from a background job or an s6 longrun.
- **Retry only transient failures**: network errors, 408, 429 and 5xx, with backoff. Log any other status once and stop.
- **Mark it pending on first boot** (`/etc/appbox_callback_pending`, touched just before `/etc/app_configured` so a stop between the two cannot lose it) and remove the flag after the attempt. A restart while the API is unreachable then tries again, and a rejected callback is not repeated.
- **Auth**: when `callback_requires_auth` is true, send `CALLBACK_TOKEN` in the `X-Cylo-Callback-Token` header (the API does not read `Authorization: Bearer`). `INSTANCE_ID` may also carry `?callback_token=...`.
- **Secrets**: never echo `INSTANCE_ID` or `CALLBACK_TOKEN`, and keep them out of commands traced by `set -x`. Log only `${INSTANCE_ID%%\?*}`.
- **No single-shot callback under `set -e`** (`set -e; curl -f .../installed/...`): a rejected callback then exits the entrypoint and the container restart-loops.
- **Match `expect_callback` to the image**: `true` only if the image sends the callback. If the catalogue says `false`, the platform sends the callback itself and the container's own call is rejected; if it says `true` and the image never calls back, the install never leaves "installing".

`tests/test-installed-callback.sh` runs the helper and the entrypoint against a local mock API; keep it passing when you change either.

## Testing

See `TESTING.md` for the complete testing framework with checklists. All tests must pass before submission.

Quick smoke test:

```bash
docker build --platform linux/amd64 -t my-app .
docker run --platform linux/amd64 -e USERNAME=admin -e PASSWORD='TestPass123!' \
  -e INSTANCE_ID=test -e SKIP_APPBOX_CALLBACK=1 \
  -p 3001:3001 my-app
```

The three container states that MUST be tested:
- **Fresh install**: run with empty/no volume
- **Upgrade**: stop container, rebuild image, start with same volume
- **Restart**: stop and start without rebuilding

## Submission

Submit via support ticket at: https://billing.appbox.co/submitticket.php?step=2&deptid=1

Include: app name, publisher, repo URL, Docker image, version, tag, short description, and categories. See `README.md` for the full ticket template.

## s6 Dependency Ordering (LSIO / s6-overlay)

When building on an LSIO base image or using s6-overlay with multiple services, **service start ordering is not automatic**. s6-rc resolves dependencies and starts services in parallel. If your service needs an init script to complete first (e.g. user creation, directory permissions), you must declare explicit dependencies.

### The problem

LSIO images have init oneshots (e.g. `init-adduser`, `init-config-*`) and longrun services (e.g. `svc-server`). Without explicit dependencies, services start **in parallel with** init scripts, causing race conditions:
- Services start before user `abc` (UID 1000) is created
- Services write to directories before init scripts fix ownership
- Permission errors (`EACCES`) on volumes like `/photos`, `/config`, etc.

### The fix

Add dependency files in each service's `dependencies.d/` directory:

```dockerfile
# Make svc-myapp wait for ALL LSIO init scripts to complete
RUN mkdir -p /etc/s6-overlay/s6-rc.d/svc-myapp/dependencies.d && \
    touch /etc/s6-overlay/s6-rc.d/svc-myapp/dependencies.d/legacy-cont-init

# If the LSIO image has app-specific init (e.g. init-config-immich),
# add that too — it's a SEPARATE oneshot, not part of legacy-cont-init
RUN touch /etc/s6-overlay/s6-rc.d/svc-myapp/dependencies.d/init-config-<appname>
```

**How to discover init service names:**
```bash
docker exec <container> ls /etc/s6-overlay/s6-rc.d/user/contents.d/
```
Look for entries starting with `init-`. Check what each does:
```bash
docker exec <container> cat /etc/s6-overlay/s6-rc.d/init-config-<appname>/run
```

### Common LSIO init hierarchy

| Service | Type | What it does |
|---------|------|-------------|
| `legacy-cont-init` | oneshot | Runs legacy `/etc/cont-init.d/` scripts |
| `init-adduser` | oneshot | Creates the `abc` user with PUID/PGID |
| `init-config` | oneshot | General LSIO config |
| `init-config-<appname>` | oneshot | App-specific setup (directory creation, chown) |
| `init-custom-files` | oneshot | Runs `/custom-cont-init.d/` scripts |

**Critical:** `legacy-cont-init` and `init-config-<appname>` are **independent** — they run in parallel. If your service needs both, add both as dependencies.

### Overriding slow LSIO init scripts

Some LSIO init scripts (like `init-config-immich`) run expensive operations on every boot, such as:
```bash
find /app/immich -path "*/node_modules" -prune -o -exec chown abc:abc {} +
```
This chowns thousands of **immutable image-layer files** on every startup — completely unnecessary and can take minutes on slow storage. Override these by copying your own version of the script into the Dockerfile:

```dockerfile
COPY init-config-myapp /etc/s6-overlay/s6-rc.d/init-config-myapp/run
RUN chmod +x /etc/s6-overlay/s6-rc.d/init-config-myapp/run
```

Keep the essential operations (directory creation, volume chown) and remove the pointless image-layer chowns.

## Embedding PostgreSQL

When bundling PostgreSQL inside the container:

1. **UID 1000 must exist in `/etc/passwd` before `initdb`** — The entrypoint runs before LSIO's `/init` creates the `abc` user. PostgreSQL's `initdb` calls `getpwuid()` and fails if the UID has no passwd entry. Bootstrap it:
   ```bash
   if ! getent passwd 1000 >/dev/null 2>&1; then
       echo "appuser:x:1000:1000::/config:/usr/sbin/nologin" >> /etc/passwd
   fi
   ```

2. **Socket directory permissions** — Create and chown `/var/run/postgresql` before starting PG:
   ```bash
   mkdir -p /var/run/postgresql
   chown 1000:1000 /var/run/postgresql
   ```

3. **Data directory must be mode 700** — LSIO init may reset `/config` permissions to 755. Fix it in the s6 `run` script, immediately before starting PG:
   ```bash
   chmod 700 /config/postgres
   exec gosu 1000:1000 /usr/lib/postgresql/14/bin/postgres -D /config/postgres
   ```

4. **Stale PID cleanup** — After unclean shutdown, a stale `postmaster.pid` blocks PG from starting. Clean it up before starting PG (both in the entrypoint's temporary start and in the s6 `run` script):
   ```bash
   if [ -f /config/postgres/postmaster.pid ]; then
       OLD_PID=$(head -1 /config/postgres/postmaster.pid)
       if ! kill -0 "$OLD_PID" 2>/dev/null; then
           pkill -9 -u 1000 postgres 2>/dev/null || true
           sleep 1
           rm -f /config/postgres/postmaster.pid
       fi
   fi
   ```

5. **Extension version matching** — PostgreSQL extensions (`.so` files) are compiled for a specific PG major version. If copying extensions from another image, the PG versions must match exactly.

## moduser.sh for Apps with Embedded Databases

When the app uses an embedded database (PostgreSQL, MySQL, SQLite) and has no CLI for password reset, `moduser.sh` must update the database directly:

- **Hash the password** using the app's expected algorithm (e.g. bcrypt). Install the hashing library globally during build: `npm install -g bcryptjs`
- **Set `NODE_PATH`** if the runtime can't find globally installed modules: `NODE_PATH=/usr/lib/node_modules node -e "..."`
- **Know the exact schema** — table and column names may differ from what you expect (e.g. Immich uses `"user"` not `users`, and `"isAdmin"` is camelCase with quotes for reserved SQL keywords).

## Common Mistakes

- Using a UID other than 1000 — will break with userns
- Forgetting the API callback — app stays stuck in "installing" state
- **Blocking startup on the API callback** — `until curl -f .../apps/installed/...; do sleep 5; done` before `exec`, in cont-init or in an s6 oneshot. Once the API rejects the callback (401 after the token was used, or the platform already marked the instance installed) the loop never ends and the app never starts. Use `appbox-installed-callback` in the background (see [Platform Callback](#platform-callback))
- Not persisting data in volumes — data lost on restart/upgrade
- Running the app as PID 1 without `exec` — signals not forwarded, graceful shutdown fails
- Including platform-managed fields in appbox.yml — they are ignored
- Not testing the upgrade path — user data gets wiped or admin user re-created
- **Building the admin request by string interpolation** — `--data '{"password":"'"${PASSWORD}"'"}'` produces invalid JSON as soon as the password contains `"` or `\`, both allowed by `complexPassword`. Build it with `jq` from the environment (rule 19)
- **Treating an HTTP 400 as "admin already exists"** — a 400 also means the request was rejected. Ask the app whether an admin exists instead. Immich 3.3.5 and earlier reported installs as finished with no admin account and an open sign-up page
- **Warning and carrying on when admin setup fails** — the install is reported finished with no working login. Fail closed and retry on the next start (rule 19)
- **Leaving the admin password write-only** — `sensitive: true` without `revealable: true` and `params.showOnInstalled: true` imports as write-only, and Show on the installed app answers 403 "Custom field is write-only"
- Missing moduser.sh — required for password recovery; submission will be rejected without it
- Defining HTTP ports in the `ports` section for web apps — exposes the port publicly bypassing nginx/SSL. Use `VIRTUAL_PORT` env var instead
- Forgetting `VIRTUAL_PORT` when the app doesn't listen on port 80 — nginx proxies to port 80 by default and the app won't load
- Not adding `EXPOSE` in the Dockerfile for the web UI port (80 or custom) — the platform reads this to know which ports the container uses
- **`set -e` in background subshells** — `set -e` propagates into `( ... ) &` subshells. If any command in the subshell returns non-zero (e.g. `wait_for_http` timing out), the entire subshell dies and the callback is never sent. Always add `set +e` at the top of background subshells
- **Insufficient `wait_for_http` timeout** — Services may take minutes to start if s6 init scripts are slow (e.g. LSIO image running expensive chowns). Use at least 300 attempts × 2s = 10 minutes, not 60 × 2s = 2 minutes
- **Missing s6 service dependencies** — s6-rc starts services in parallel with init scripts. Without explicit `dependencies.d` files, services start before directories are chowned, before the user is created, etc. Always check the s6 dependency graph
- **Docker volumes start root-owned** — A new Docker volume has root:root ownership. Your entrypoint or init scripts must chown it before the app writes to it. For LSIO images, the app-specific init script (e.g. `init-config-*`) usually handles this, but only if services wait for it (see s6 dependency ordering)
- **LSIO `DB_PASSWORD` check** — Some LSIO images (like imagegenius/immich) require `DB_PASSWORD` to be non-empty even when using local trust auth. Set it to a dummy value in `appbox.yml`
- **Building for the wrong architecture** — The platform is `linux/amd64` only. Building without `--platform linux/amd64` on an ARM host (e.g. Apple Silicon Mac) produces an `arm64` image that will not run in production. Always pass `--platform linux/amd64` to both `docker build` and `docker run`
