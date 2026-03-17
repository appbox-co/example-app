# =============================================================================
# Dockerfile — Appbox App Container
# =============================================================================
#
# This Dockerfile wraps the official Uptime Kuma image with the Appbox
# entrypoint that handles first-run setup, upgrades, and platform callbacks.
#
# DESIGN PHILOSOPHY:
#   Appbox prefers reusing official, well-maintained upstream images rather
#   than building from scratch. This approach means:
#     - Security patches come from the upstream maintainer
#     - The app stays up to date with minimal effort
#     - Less custom code to maintain
#
# INIT SYSTEM NOTE:
#   Appbox's preferred init system is s6-overlay. However, when building on
#   an existing upstream image (as we do here), any init approach is fine.
#   The priority is reusing well-maintained images over custom builds.
#   Uptime Kuma uses Node.js directly, so we use a simple bash entrypoint
#   with `exec` for proper PID 1 signal handling.
#
# SINGLE CONTAINER REQUIREMENT:
#   Appbox apps MUST be fully self-contained in a single container with no
#   external dependencies. No separate database containers, no docker-compose,
#   no sidecar services. If an app needs a database, it must be embedded
#   (e.g. SQLite, as Uptime Kuma does) or bundled inside the same container.
#
# USER NAMESPACES (userns):
#   All Appbox containers run with user namespaces enabled. This means that
#   UID 0 (root) inside the container is mapped to an unprivileged UID on
#   the host, providing an extra layer of security. Your app MUST run its
#   main process as UID 1000 inside the container. All files and directories
#   that the app reads or writes MUST be owned by 1000:1000 inside the
#   container. The entrypoint runs as root (UID 0 inside the container) to
#   handle /etc/resolv.conf and /etc/hosts, then drops to 1000 via gosu.
#
# =============================================================================

# BASE IMAGE
# We use the official Uptime Kuma image from Docker Hub. The `:1` tag tracks
# the latest 1.x release, giving us patch updates automatically while
# avoiding breaking major version changes.
#
# When using the Appbox private registry (repo.cylo.io), the image is pulled
# from there instead. The `image.registry` field in appbox.yml controls this.
FROM louislam/uptime-kuma:1

# INSTALL REQUIRED TOOLS
# These packages are needed by the entrypoint script:
#
#   bash  — The entrypoint is a bash script. Many base images only include
#           /bin/sh (dash/ash), which lacks features we need (e.g. [[ ]]).
#
#   curl  — Used for two purposes:
#           1. Initial setup: making API calls to configure the app on first run
#           2. Platform callback: notifying Appbox that installation is complete
#              by POSTing to https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}
#
#   gosu  — A lightweight tool for dropping root privileges. The entrypoint
#           runs as root (to write /etc/resolv.conf, /etc/hosts, etc.) then
#           uses gosu to exec the app process as a non-root user. Unlike
#           `su` or `sudo`, gosu properly execs (replaces the process) so
#           the app becomes PID 1 and receives signals correctly.
#
# The `--no-cache` flag avoids storing the package index in the image layer,
# keeping the image smaller.
#
# NOTE: Uptime Kuma's base image is Node.js on Alpine Linux, so we use `apk`.
# For Debian/Ubuntu-based images, use `apt-get install -y` instead.
# For images without a package manager, install tools in a multi-stage build.
RUN apk add --no-cache bash curl && \
    apk add gosu --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing

# ADD ENTRYPOINT SCRIPT
# Copy our custom entrypoint into the container. This script handles:
#   - Container DNS and networking setup
#   - First-run detection and initial app configuration
#   - Upgrade detection and handling
#   - Platform callback to signal installation complete
#   - Privilege dropping and exec of the main app process
ADD entrypoint.sh /entrypoint.sh

# ADD PASSWORD CHANGE SCRIPT
# All Appbox apps MUST include moduser.sh at the container root.
# This allows users to recover access if they are locked out.
# Usage: docker exec <container> /moduser.sh <current_password> <new_password>
ADD moduser.sh /moduser.sh
RUN chmod +x /moduser.sh

# ENTRYPOINT vs CMD
# These work together:
#   ENTRYPOINT — Always runs first. Our script handles setup then execs CMD.
#   CMD        — The actual app command, passed as arguments to ENTRYPOINT.
#
# This split means:
#   - `docker run <image>` runs: /entrypoint.sh node server/server.js
#   - `docker run <image> bash` runs: /entrypoint.sh bash (for debugging)
#   - The CMD can be overridden without losing the entrypoint setup logic
#
# The entrypoint script ends with `exec gosu <uid> "$@"`, which replaces
# itself with CMD, making the app process PID 1 for proper signal handling.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["node", "server/server.js"]

# EXPOSE
# Documents which port the app listens on inside the container. This does
# NOT publish the port to the host — that is handled by the platform based
# on the `ports` section in appbox.yml.
#
# The port here (3001) should match what's configured in appbox.yml:
#   ports.tcp.range: "3001"
#
# The platform assigns a random available external (host) port and maps
# it to this internal port. The external port is accessible via the
# template variable %PORTS|0.external%.
EXPOSE 3001
