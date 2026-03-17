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
#   1. CLI tool (preferred if the app provides one):
#      /app/bin/reset-password --new "$1"
#
#   2. Direct database update (as demonstrated below):
#      Hash the new password, update the database.
#
#   3. Configuration file:
#      Hash the new password, update the config file.
#
# =============================================================================

NEW_PASSWORD="$1"

if [ -z "$NEW_PASSWORD" ]; then
    echo "Usage: /moduser.sh <new_password>"
    exit 1
fi

# Uptime Kuma stores passwords as bcrypt hashes in a SQLite database.
# Both `bcryptjs` and `better-sqlite3` are available as Node.js dependencies
# inside the container, so we use a Node.js script for the update.
MODUSER_NEW="$NEW_PASSWORD" node -e "
const Database = require('better-sqlite3');
const bcrypt = require('bcryptjs');

const db = new Database('/app/data/kuma.db');
const user = db.prepare('SELECT id FROM user LIMIT 1').get();

if (!user) {
    console.error('No user found in database');
    process.exit(1);
}

const hash = bcrypt.hashSync(process.env.MODUSER_NEW, 10);
db.prepare('UPDATE user SET password = ? WHERE id = ?').run(hash, user.id);
console.log('Password changed successfully');
"
