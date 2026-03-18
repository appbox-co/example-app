#!/bin/bash
# =============================================================================
# moduser.sh — Change the Default User's Password
# =============================================================================
#
# REQUIREMENT:
#   All Appbox apps MUST include a moduser.sh script in the container root.
#   This allows password recovery when a user is locked out of their app.
#
# INTERFACE:
#   /moduser.sh <new_password>
#
# IMPLEMENTATION NOTES:
#   - The script changes the password for the app's default (admin) user
#   - It overwrites the existing password unconditionally (this is a recovery tool)
#   - It does not need to return anything, but should exit non-zero on failure
#   - The script is run via: docker exec <container> /moduser.sh newpass
#
# ADAPTING FOR YOUR APP:
#   Every app stores passwords differently. Common approaches:
#
#   1. CLI tool (preferred if the app provides one — used below):
#      /app/bin/reset-password --new "$1"
#
#   2. Direct database update:
#      Hash the new password, update the database directly.
#
#   3. Configuration file:
#      Hash the new password, update the config file.
#
# =============================================================================

NEW_PASSWORD="$1"

if [[ -z "${NEW_PASSWORD}" ]]; then
    echo "Usage: /moduser.sh <new_password>"
    exit 1
fi

# Uptime Kuma v2 provides an official CLI for password resets.
# This is the preferred approach — always use the app's native tools
# when available rather than manipulating the database directly.
cd /app || exit 1
npm run reset-password -- --new-password="${NEW_PASSWORD}"
