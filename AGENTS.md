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
├── icon.png         # App icon (512x512 PNG) for the store listing
├── moduser.sh       # Password change script (required for all apps)
├── README.md        # Full documentation and schema reference
└── TESTING.md       # Testing framework — complete before submitting
```

## Key Constraints

When creating or modifying an Appbox app, always follow these rules:

1. **Single container** — Everything in one Docker container. No docker-compose, no sidecars, no external database containers. If the app needs a database, embed it (e.g. SQLite) or bundle it inside the same container.

2. **UID 1000** — The app process MUST run as UID 1000 inside the container. All data directories MUST be owned by 1000:1000. The entrypoint runs as root only for setup, then drops to 1000 via `gosu`. This is a hard requirement.

3. **User namespaces** — All containers run with userns enabled. UID 0 inside the container is NOT root on the host. Never assume host-level root access.

4. **Entrypoint lifecycle** — The entrypoint script must follow this pattern:
   - Check `/etc/app_configured` to detect first boot vs restart
   - Fresh install: start app, configure admin user, stop app
   - Upgrade: skip user creation (data exists), run migrations if needed
   - Call platform API callback: `POST https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}`
   - Start app with `exec gosu 1000:1000 "$@"`

5. **Secure by default** — Use `complexPassword` validation for admin passwords. Disable public registration. Never hardcode credentials.

6. **Volume UID** — Set `uid: 1000` in all volume definitions in `appbox.yml`.

7. **Prefer upstream images** — Build on official, well-maintained Docker images rather than building from scratch. If the app needs multiple services running in a single container (e.g. app + database + worker), you MUST use **s6-overlay** as the init/process supervisor — it handles process lifecycle, restarts, and signal forwarding correctly. For single-process apps, a plain bash entrypoint with `exec` is fine. Any init system is acceptable when reusing upstream images.

8. **moduser.sh** — All apps MUST include `/moduser.sh` in the container. It accepts one argument (`new_password`) and overwrites the default user's password. This is used for account recovery when a user is locked out.

9. **Web app ports** — If your app is a web app (`is_web_app: true`) and only serves a web UI, do NOT define ports in the `ports` section. The platform reverse-proxies HTTP via nginx automatically. Instead, set a `VIRTUAL_PORT` env var to the HTTP port your app listens on (default is 80). This must always be a plain HTTP port — the platform handles SSL. Defining the HTTP port in `ports` would expose it publicly, bypassing the reverse proxy and SSL.

10. **Shared file system** — App volumes are stored in a shared area on the host (`/cylostore/<disk>/<cylo>/home/apps/<domain>/`). Other apps can access this data if they have the shared file system mounted. If your app needs to read/write data from other apps (e.g. file manager browsing all data, AI assistant accessing files), use the `shared_data` section in `appbox.yml` to mount the user's home directory into the container. The source uses template variables: `/cylostore/%CYLO.DISK_NAME%/%CYLO.ID%/home/apps/`. By convention, the destination is `/APPBOX_DATA`. Do not use `/APPBOX_DATA` for your app's own state/config/database; keep that in normal persistent app volumes. `/APPBOX_DATA/apps` is for cross-app access, while `/APPBOX_DATA/storage` is user general storage.

## appbox.yml

The `appbox.yml` file is the single source of truth for app configuration. See `README.md` for the full schema reference.

- Only `app` and `image` sections are required; all others have defaults.
- Template variables use `%TABLE.FIELD%` syntax (ALL CAPS), e.g. `%INSTANCE.ID%`, `%PORTS|0.EXTERNAL%`.
- Custom fields become environment variables inside the container, keyed by the field name.
- Fields of type `externalURL` render as clickable links on the installed app page. For predictable URLs, set `default_value` to a template like `https://%DOMAIN.DOMAIN%/` with `template_type: instance` — the platform resolves this at install time. For URLs only known at runtime (dynamic ports, generated paths), set the value via the API callback instead (include `custom_fields` array in the POST body). For other field type updates via callback, contact support.
- Use the `shared_data` section to mount the user's shared home directory if the app needs access to other apps' data. Source must use template variables (e.g. `/cylostore/%CYLO.DISK_NAME%/%CYLO.ID%/home/apps/`).
- Do not include fields that are platform-managed (e.g. `privileged`, `security_opt`, `network_mode`, `dns`, `type`, `registry`). They will be ignored.

## Dockerfile Pattern

### Single-process apps

```dockerfile
FROM <upstream-image>:<tag>
RUN <install bash, curl, gosu>
ADD entrypoint.sh /entrypoint.sh
ADD moduser.sh /moduser.sh
RUN chmod +x /entrypoint.sh /moduser.sh
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
RUN chmod +x /entrypoint.sh /moduser.sh
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
set -x

APP_USER="1000:1000"

callback_installed() {
    if [[ "${SKIP_APPBOX_CALLBACK:-0}" == "1" ]]; then return 0; fi
    local callback_url="https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}"
    local headers=(-H "Accept: application/json" -H "Content-Type:application/json")
    if [[ -n "${CALLBACK_TOKEN:-}" ]]; then
        headers+=(-H "Authorization: Bearer ${CALLBACK_TOKEN}")
    fi
    until curl -fsS -o /dev/null "${headers[@]}" -X POST "${callback_url}"; do
        sleep 5
    done
}

if [[ ! -f /etc/app_configured ]]; then
    touch /etc/app_configured

    if [[ ! -f "<persisted-data-path>" ]]; then
        # FRESH INSTALL: start app, configure, stop
        gosu "${APP_USER}" "$@" &
        # ... wait for ready, create admin user, kill app
    else
        # UPGRADE: skip user creation
    fi

    callback_installed
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

# ... helper functions (wait_for_http, callback_installed, create_admin_user) ...

# === One-time setup (runs BEFORE s6-overlay /init) ===
# Initialize database directories, run migrations, etc.
# These steps happen once and must complete before services start.
mkdir -p /config/database
chown -R 1000:1000 /config/database

# === Appbox lifecycle in a background subshell ===
if [[ ! -f "${CONFIG_FLAG}" ]]; then
    touch "${CONFIG_FLAG}"

    (
        set +e   # CRITICAL: prevent set -e from killing the subshell on timeout

        if [[ ! -f "${FRESH_MARKER}" ]]; then
            echo "Fresh install, waiting for app..."
            wait_for_http "${LOCAL_URL}/api/health" 300 2
            create_admin_user && touch "${FRESH_MARKER}"
        else
            echo "Upgrade detected"
            wait_for_http "${LOCAL_URL}/api/health" 300 2
        fi

        callback_installed
    ) &
fi

# Hand off to s6-overlay
exec "$@"
```

**Key differences from single-process pattern:**
- `set -e` (not `set -x`) is preferred since s6 services produce their own logs.
- The lifecycle subshell uses `set +e` to prevent inherited `set -e` from killing it when `wait_for_http` times out.
- Use a generous timeout (300 × 2s = 10 min) for `wait_for_http` since s6 init scripts may take time before services start.
- `exec "$@"` becomes `exec /init` (from CMD), NOT `exec gosu ... "$@"`. s6-overlay's service `run` scripts handle user switching via `gosu` or `s6-setuidgid`.

## Testing

See `TESTING.md` for the complete testing framework with checklists. All tests must pass before submission.

Quick smoke test:

```bash
docker build -t my-app .
docker run -e USERNAME=admin -e PASSWORD='TestPass123!' \
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
- Not persisting data in volumes — data lost on restart/upgrade
- Running the app as PID 1 without `exec` — signals not forwarded, graceful shutdown fails
- Including platform-managed fields in appbox.yml — they are ignored
- Not testing the upgrade path — user data gets wiped or admin user re-created
- Missing moduser.sh — required for password recovery; submission will be rejected without it
- Defining HTTP ports in the `ports` section for web apps — exposes the port publicly bypassing nginx/SSL. Use `VIRTUAL_PORT` env var instead
- Forgetting `VIRTUAL_PORT` when the app doesn't listen on port 80 — nginx proxies to port 80 by default and the app won't load
- Not adding `EXPOSE` in the Dockerfile for the web UI port (80 or custom) — the platform reads this to know which ports the container uses
- **`set -e` in background subshells** — `set -e` propagates into `( ... ) &` subshells. If any command in the subshell returns non-zero (e.g. `wait_for_http` timing out), the entire subshell dies and `callback_installed` never runs. Always add `set +e` at the top of background subshells
- **Insufficient `wait_for_http` timeout** — Services may take minutes to start if s6 init scripts are slow (e.g. LSIO image running expensive chowns). Use at least 300 attempts × 2s = 10 minutes, not 60 × 2s = 2 minutes
- **Missing s6 service dependencies** — s6-rc starts services in parallel with init scripts. Without explicit `dependencies.d` files, services start before directories are chowned, before the user is created, etc. Always check the s6 dependency graph
- **Docker volumes start root-owned** — A new Docker volume has root:root ownership. Your entrypoint or init scripts must chown it before the app writes to it. For LSIO images, the app-specific init script (e.g. `init-config-*`) usually handles this, but only if services wait for it (see s6 dependency ordering)
- **LSIO `DB_PASSWORD` check** — Some LSIO images (like imagegenius/immich) require `DB_PASSWORD` to be non-empty even when using local trust auth. Set it to a dummy value in `appbox.yml`
