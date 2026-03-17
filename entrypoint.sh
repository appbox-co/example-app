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
# STEP 1: First-Boot Detection
# =============================================================================
# Only run setup on first boot of this container image (not on normal
# restarts where /etc/app_configured already exists).

if [[ ! -f /etc/app_configured ]]; then

    # Mark this container image as configured. This file persists across
    # container restarts but is lost when the container image is replaced
    # (during upgrades). See "THREE CONTAINER STATES" above.
    touch /etc/app_configured

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

    if [[ ! -f "/app/data/kuma.db" ]]; then

        # =================================================================
        # FRESH INSTALL — First-Run Setup
        # =================================================================
        # No existing database found. We need to:
        #   1. Start the app in the background
        #   2. Wait for it to become ready
        #   3. Create the admin user using the credentials from custom fields
        #   4. Stop the app (it will be properly started at the end of this script)
        #
        # WHY START AND STOP?
        #   Many apps (like Uptime Kuma) only allow initial setup through
        #   their web interface or API — there's no CLI flag or config file
        #   for setting the initial admin user. We need the app running to
        #   call its setup endpoint, then we stop it so it can be cleanly
        #   started with `exec` as PID 1 at the end of this script.
        #
        # ENVIRONMENT VARIABLES:
        #   USERNAME and PASSWORD come from the custom_fields defined in
        #   appbox.yml. The platform injects each custom field's value as
        #   an environment variable using the field's key name.

        # Start the app in the background. The "$@" expands to the CMD
        # from the Dockerfile (e.g. "node server/server.js").
        # We use gosu to run as the correct user (UID 1000 for Uptime Kuma).
        "/usr/bin/gosu" "1000:1000" "$@" &
        APP_PID=$!

        # WAIT FOR THE APP TO BE READY
        # Poll the app's HTTP endpoint until it responds. This is necessary
        # because the app takes a few seconds to start up, initialize its
        # database, and begin listening for connections.
        #
        # We check for the presence of specific content in the response to
        # confirm the app is fully loaded, not just the port being open.
        # For Uptime Kuma, we look for the Nuxt.js marker in the HTML.
        #
        # The `sleep 5` between retries prevents hammering the app during
        # startup. Adjust based on your app's typical startup time.
        echo "Waiting for Uptime Kuma to start..."
        while ! curl -sf http://localhost:3001 > /dev/null 2>&1
        do
            sleep 5
        done
        echo "Uptime Kuma is ready, configuring admin user..."

        # CREATE THE ADMIN USER
        # Uptime Kuma uses Socket.IO (WebSocket) for its setup API rather
        # than a simple REST endpoint. The "setup" event accepts a username,
        # password, and callback function.
        #
        # Since Node.js and socket.io-client are already available inside the
        # Uptime Kuma container, we use a Node.js one-liner to connect and
        # emit the setup event.
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
        #
        # SECURITY NOTE: Environment variables containing passwords are
        # visible in /proc/PID/environ to processes running as the same user.
        # This is acceptable because the container is isolated and the
        # password is only used during initial setup.

        node -e "
const { io } = require('socket.io-client');
const socket = io('http://localhost:3001', { reconnection: false, timeout: 30000 });

socket.on('connect', () => {
    socket.emit('setup', process.env.USERNAME, process.env.PASSWORD, (res) => {
        if (res.ok) {
            console.log('Admin user created successfully');
        } else {
            console.error('Setup failed:', res.msg);
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
        SETUP_EXIT=$?

        if [ $SETUP_EXIT -ne 0 ]; then
            echo "WARNING: Admin user setup failed (exit code: $SETUP_EXIT)"
            echo "The app may require manual setup through the web interface."
        else
            echo "Uptime Kuma has been configured successfully"
        fi

        # STOP THE BACKGROUND APP PROCESS
        # We kill the app so it can be cleanly restarted with `exec` at the
        # end of this script. Using `exec` makes the app PID 1, which is
        # important for proper signal handling (SIGTERM for graceful shutdown).
        kill $APP_PID 2>/dev/null
        wait $APP_PID 2>/dev/null

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
        # Uptime Kuma handles migrations automatically on startup, so we
        # don't need to do anything extra here.

        echo "Upgrade detected: existing data found at /app/data/kuma.db"
        echo "Skipping user creation, database migrations will run on startup"
    fi

    # =========================================================================
    # STEP 3: Platform Callback
    # =========================================================================
    # Notify the Appbox platform that the app has finished its setup and is
    # ready for the user to access.
    #
    # HOW IT WORKS:
    #   The platform sets `expect_callback: true` in appbox.yml, which tells
    #   it to wait for this POST request before showing the app as "installed"
    #   to the user. Without this callback, the user might try to access the
    #   app before setup is complete.
    #
    # THE ENDPOINT:
    #   POST https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}
    #   - INSTANCE_ID is injected as an environment variable by the platform
    #   - The platform responds with HTTP 200 when it acknowledges the callback
    #
    # WHY RETRY IN A LOOP:
    #   The API server might be temporarily unavailable, or there could be
    #   a brief network issue. We retry every 5 seconds until we get a 200
    #   response. This is safe because the callback is idempotent.
    #
    # CALLBACK_REQUIRES_AUTH:
    #   If `callback_requires_auth` is true in appbox.yml, you must include
    #   the CALLBACK_TOKEN as a Bearer token:
    #     -H "Authorization: Bearer ${CALLBACK_TOKEN}"
    #
    # SETTING CUSTOM FIELD VALUES (externalURL only):
    #   The callback can also pass clickable links back to the platform for
    #   display to the user. This is done by including a "custom_fields" array
    #   in the JSON body. Only fields with type "externalURL" in appbox.yml can
    #   be set this way — the values render as clickable links on the installed
    #   app page.
    #
    #   This is useful when a URL is only known after the app starts (e.g. an
    #   admin panel on a dynamic port, or an API endpoint).
    #
    #   Example JSON body:
    #     {"custom_fields": [{"key": "ADMIN_PANEL", "value": "https://..."}]}
    #
    #   The "key" must match the field name defined in appbox.yml under
    #   custom_fields. If you need to update other field types via callback,
    #   contact support. See README.md for a full example.

    until [[ $(curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}" | grep '200') ]]
    do
        sleep 5
    done

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
#   container. This is a hard requirement — do not use other UIDs. With
#   user namespaces enabled, UID 1000 inside the container is mapped to an
#   unprivileged host UID, providing security isolation.
#
#   IMPORTANT: Ensure all app data directories are owned by 1000:1000 inside
#   the container. If the upstream image uses a different UID, add a
#   `chown -R 1000:1000 /path/to/data` step in the Dockerfile or here.
#
#   "$@" expands to the CMD from the Dockerfile (e.g. "node server/server.js").
#   This means you can override the command at runtime:
#     docker run <image> bash    # drops into a shell for debugging
#     docker run <image>         # runs the default CMD

exec "/usr/bin/gosu" "1000:1000" "$@"
