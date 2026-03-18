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
#   3. Platform callback (notify Appbox that the app is ready)
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
# THREE CONTAINER STATES:
#
#   FRESH INSTALL:
#     No persisted data exists AND /etc/app_configured does not exist.
#     The script performs full first-run setup: starts the app temporarily,
#     creates the admin user, configures settings, then stops the app.
#
#   UPGRADE:
#     Persisted data exists (from a previous install) BUT /etc/app_configured
#     does not exist. This happens when the container image is replaced during
#     an update — the persistent volume data survives, but the container
#     filesystem (including /etc/app_configured) is fresh.
#     The script skips user creation (data already exists) but still runs
#     the callback and any migration steps.
#
#   RESTART:
#     Both persisted data AND /etc/app_configured exist. This is a normal
#     container restart (not an image replacement). The script skips all
#     setup and goes straight to running the app.
#
# WHY /etc/app_configured?
#   This file lives on the container's ephemeral filesystem, NOT on a
#   persistent volume. It is automatically deleted when the container image
#   is replaced (during upgrades), but survives normal restarts. This lets
#   us distinguish between "the container restarted" and "a new version was
#   deployed" without needing version tracking logic.
#
# =============================================================================

# Enable debug output so all commands are logged to the container logs.
# This is invaluable for debugging installation issues. Remove in production
# if logs are too verbose.
set -x

# =============================================================================
# Constants
# =============================================================================

CONFIG_FLAG="/etc/app_configured"
DATA_DB="/app/data/kuma.db"
APP_USER="1000:1000"
LOCAL_URL="http://localhost:3001"

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
# Uptime Kuma v2 requires an explicit HTTP POST to /setup-database to choose
# the database engine before the app enters its normal running state. We use
# SQLite (single-file, no external DB needed — fits the single-container model).
#
# ADAPTING FOR OTHER APPS:
#   Most apps don't need this step. If your app auto-initializes its database
#   on first start, you can skip this entirely.
setup_sqlite_database() {
    wait_for_http "${LOCAL_URL}/setup-database-info" 90 2 || return 1

    curl -fsS -o /dev/null \
        -H "Content-Type: application/json" \
        -X POST "${LOCAL_URL}/setup-database" \
        --data '{"dbConfig":{"type":"sqlite"}}'
}

# UPTIME KUMA v2 SETUP — STAGE 2: Admin User Creation
# After the database is initialized, Uptime Kuma accepts a "setup" Socket.IO
# event to create the initial admin user. We retry in a loop because the app
# may take a moment to restart after database configuration.
#
# ALTERNATIVE APPROACHES FOR OTHER APPS:
#
#   1. Simple REST API (like Audiobookshelf):
#      curl 'http://localhost:PORT/init' \
#          -H 'Content-Type: application/json' \
#          --data-raw '{"username":"'"${USERNAME}"'","password":"'"${PASSWORD}"'"}'
#
#   2. CLI command (some apps provide setup commands):
#      /app/bin/setup --username "${USERNAME}" --password "${PASSWORD}"
#
#   3. Direct database manipulation (last resort):
#      sqlite3 /app/data/app.db "INSERT INTO users ..."
#
#   4. Configuration file generation:
#      cat > /app/config.yml << CONF
#      admin_user: ${USERNAME}
#      admin_pass: ${PASSWORD}
#      CONF
create_admin_user() {
    local attempts=30
    local sleep_seconds=2
    local i=0

    while [[ "${i}" -lt "${attempts}" ]]; do
        node -e "
const { io } = require('socket.io-client');
const socket = io('${LOCAL_URL}', { reconnection: false, timeout: 30000 });

socket.on('connect', () => {
    socket.emit('setup', process.env.USERNAME, process.env.PASSWORD, (res) => {
        if (!res.ok) {
            console.error('Setup failed:', res.msg);
        } else {
            console.log('Admin user created successfully');
        }
        socket.disconnect();
        process.exit(res.ok ? 0 : 1);
    });
});

socket.on('connect_error', (err) => {
    console.error('Socket connection failed:', err.message);
    process.exit(1);
});
"
        if [[ $? -eq 0 ]]; then
            return 0
        fi

        i=$((i + 1))
        sleep "${sleep_seconds}"
    done

    return 1
}

# =============================================================================
# Platform Callback
# =============================================================================
# Notify the Appbox platform that the app has finished its setup and is
# ready for the user to access.
#
# HOW IT WORKS:
#   The platform sets `expect_callback: true` in appbox.yml, which tells
#   it to wait for this POST request before showing the app as "installed"
#   to the user. Without this callback, the user might try to access the
#   app before setup is complete.
#
# WHY RETRY IN A LOOP:
#   The API server might be temporarily unavailable, or there could be
#   a brief network issue. We retry every 5 seconds until we get a 200
#   response. This is safe because the callback is idempotent.
#
# CALLBACK_REQUIRES_AUTH:
#   If `callback_requires_auth` is true in appbox.yml, include the
#   CALLBACK_TOKEN as a Bearer token.
#
# SETTING CUSTOM FIELD VALUES (externalURL only):
#   The callback can also pass clickable links back to the platform by
#   including a "custom_fields" array in the JSON body. Only externalURL
#   fields can be set this way. See README.md for a full example.
#
#   Note: if the URL is predictable (e.g. https://<domain>/), prefer using
#   template_type: instance with %DOMAIN.DOMAIN% in appbox.yml instead of
#   setting it via the callback. Only use the callback for URLs that depend
#   on runtime values (dynamic ports, generated paths, etc.).
#
# SKIP_APPBOX_CALLBACK:
#   Set SKIP_APPBOX_CALLBACK=1 for local development/testing to skip the
#   callback entirely (it would fail outside the platform anyway).
callback_installed() {
    if [[ "${SKIP_APPBOX_CALLBACK:-0}" == "1" ]]; then
        echo "Skipping Appbox callback because SKIP_APPBOX_CALLBACK=1"
        return 0
    fi

    local callback_url="https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}"
    local headers=(
        -H "Accept: application/json"
        -H "Content-Type:application/json"
    )

    if [[ -n "${CALLBACK_TOKEN:-}" ]]; then
        headers+=(-H "Authorization: Bearer ${CALLBACK_TOKEN}")
    fi

    until curl -fsS -o /dev/null "${headers[@]}" -X POST "${callback_url}"; do
        sleep 5
    done
}

# =============================================================================
# STEP 1: First-Boot Detection
# =============================================================================
# Only run setup on first boot of this container image (not on normal
# restarts where /etc/app_configured already exists).

if [[ ! -f "${CONFIG_FLAG}" ]]; then

    # Mark this container image as configured. This file persists across
    # container restarts but is lost when the container image is replaced
    # (during upgrades). See "THREE CONTAINER STATES" above.
    touch "${CONFIG_FLAG}"

    # =========================================================================
    # STEP 2: State Detection and First-Run Setup
    # =========================================================================
    # Check if this is a FRESH INSTALL or an UPGRADE by looking for
    # persisted state in the volume mount.
    #
    # For Uptime Kuma, the database file at /app/data/kuma.db is the
    # indicator. If it exists, we have data from a previous install
    # (upgrade scenario). If it doesn't, this is a brand new install.
    #
    # IMPORTANT: The path checked here MUST be inside a directory listed
    # in the `volumes` section of appbox.yml. Otherwise the data won't
    # persist and every restart would look like a fresh install.

    if [[ ! -f "${DATA_DB}" ]]; then

        # =================================================================
        # FRESH INSTALL — First-Run Setup
        # =================================================================
        # No existing database found. We need to:
        #   1. Start the app in the background
        #   2. Initialize the database (Uptime Kuma v2 requires this)
        #   3. Create the admin user using the credentials from custom fields
        #   4. Stop the app (it will be properly started at the end)
        #
        # WHY START AND STOP?
        #   Many apps only allow initial setup through their web interface
        #   or API — there's no CLI flag or config file for setting the
        #   initial admin user. We need the app running to call its setup
        #   endpoint, then we stop it so it can be cleanly started with
        #   `exec` as PID 1 at the end of this script.
        #
        # ENVIRONMENT VARIABLES:
        #   USERNAME and PASSWORD come from the custom_fields defined in
        #   appbox.yml. The platform injects each custom field's value as
        #   an environment variable using the field's key name.

        echo "Fresh install detected, bootstrapping Uptime Kuma..."

        gosu "${APP_USER}" "$@" &
        APP_PID=$!

        # Stage 1: Initialize the SQLite database
        if ! setup_sqlite_database; then
            echo "WARNING: Failed to initialize SQLite database via /setup-database."
        fi

        # After DB config, Kuma restarts into the main server process.
        wait_for_http "${LOCAL_URL}/api/entry-page" 90 2 || true

        # Stage 2: Create the admin user via Socket.IO
        if ! create_admin_user; then
            echo "WARNING: Admin setup failed. Manual setup may be required."
        fi

        # Stop the background app so it can be restarted with exec below.
        kill "${APP_PID}" 2>/dev/null || true
        wait "${APP_PID}" 2>/dev/null || true

    else
        # =================================================================
        # UPGRADE — Existing Data Detected
        # =================================================================
        # The database exists from a previous install, but /etc/app_configured
        # was missing (meaning this is a new container image).
        #
        # In this state:
        #   - The admin user already exists (skip creation)
        #   - Database migrations may need to run (most apps handle this
        #     automatically on startup)
        #   - Platform callback still needs to happen
        #
        # If your app needs explicit migration steps during upgrades,
        # add them here. For example:
        #
        #   /app/bin/migrate --run-pending
        #   sqlite3 /app/data/app.db "UPDATE settings SET value='new' WHERE key='schema_version'"
        #
        # Uptime Kuma handles migrations automatically on startup.

        echo "Upgrade detected: existing data found at ${DATA_DB}"
        echo "Skipping user creation."
    fi

    # =========================================================================
    # STEP 3: Platform Callback
    # =========================================================================
    callback_installed

fi

# =============================================================================
# STEP 4: Start the App
# =============================================================================
# This runs on EVERY container start (fresh install, upgrade, and restart).
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
