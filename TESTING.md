# Testing Framework for Appbox App Submissions

This document defines the testing framework for Appbox apps. Complete all applicable tests before submitting your app for review.

---

## Prerequisites

Before testing, ensure you have:

- Docker installed and running
- Your `Dockerfile`, `entrypoint.sh`, `moduser.sh`, `appbox.yml`, and `icon.png` in the repo
- The environment variables your app expects (from `custom_fields` in `appbox.yml`)

---

## 1. Build

The image must build cleanly with no errors.

```bash
docker build --platform linux/amd64 -t my-app .
```

**Checklist:**

- [ ] Build completes without errors
- [ ] No hardcoded secrets or credentials in the Dockerfile
- [ ] Base image is an official or well-maintained upstream image (preferred, not required)
- [ ] `bash`, `curl`, and `gosu` are installed
- [ ] `entrypoint.sh` is added and set as `ENTRYPOINT`
- [ ] `CMD` is set to the app's default start command

---

## 2. Fresh Install

Simulates a brand new user installing the app for the first time. No prior data exists.

```bash
# Create an empty volume for persistent data
docker volume create my-app-data

# Run with required environment variables
docker run --rm --platform linux/amd64 \
  -e USERNAME=admin \
  -e PASSWORD='TestPass123!' \
  -e INSTANCE_ID=test-fresh \
  -e SKIP_APPBOX_CALLBACK=1 \
  -v my-app-data:/app/data \
  -p 3001:3001 \
  my-app
```

Replace `/app/data` with your app's actual data path (from `appbox.yml` `volumes[].destination`), and the port/env vars with your app's values.

**Checklist:**

- [ ] Container starts without errors
- [ ] Logs contain no installation password, callback token, or other secret
- [ ] `/etc/app_configured` is created (visible in logs via `touch`)
- [ ] App starts in background, waits for readiness, then configures
- [ ] Admin user is created with the provided USERNAME/PASSWORD
- [ ] Admin user setup completes without errors
- [ ] Background app is stopped cleanly
- [ ] Callback is sent in the background (with `SKIP_APPBOX_CALLBACK=1` the log shows `[appbox-callback] skipped`)
- [ ] App starts as the main process without waiting for the callback
- [ ] App is accessible at `http://localhost:<port>`
- [ ] You can log in with the credentials provided during install
- [ ] Repeat the fresh install with a password containing `"`, `\`, `'`, `$` and a space (all allowed by `complexPassword`); you can still log in
- [ ] A persistent "setup done" marker is written only after the admin account is confirmed

### Rejected admin setup

Make setup fail on purpose, for example with an email or username the app
rejects, and check that the install fails closed:

- [ ] No "setup done" marker is written and no installed callback is sent
- [ ] `/etc/appbox_callback_pending` is still present
- [ ] The app does not serve an open setup or sign-up page (the port does not answer, or the container exits non-zero and Docker restarts it)
- [ ] The app has no user accounts
- [ ] After a restart, setup runs again
- [ ] A container re-created on the same volumes with valid values finishes setup, and you can log in
- [ ] The password does not appear in the log

---

## 3. Restart

Simulates a normal container restart (e.g. Docker restart, host reboot). The container filesystem including `/etc/app_configured` persists.

```bash
# Stop the running container
docker stop <container_id>

# Start the same container again (NOT a new one)
docker start <container_id>
```

Or if using `docker run --rm` (container removed on stop), simulate by running again with the same volume — but note this tests the upgrade path, not restart. To test true restart, run without `--rm`:

```bash
# Initial run (without --rm)
docker run -d --platform linux/amd64 --name my-app-test \
  -e USERNAME=admin \
  -e PASSWORD='TestPass123!' \
  -e INSTANCE_ID=test-restart \
  -e SKIP_APPBOX_CALLBACK=1 \
  -v my-app-data:/app/data \
  -p 3001:3001 \
  my-app

# Wait for startup to complete, then restart
docker restart my-app-test
```

**Checklist:**

- [ ] Container restarts without errors
- [ ] Entrypoint skips ALL setup (the `if [[ ! -f /etc/app_configured ]]` block is not entered)
- [ ] No duplicate admin user creation attempted
- [ ] No API callback attempted (`/etc/appbox_callback_pending` is absent)
- [ ] App goes straight to `exec gosu 1000:1000 "$@"`
- [ ] App is accessible and working
- [ ] Previous data and login credentials still work

---

## 4. Upgrade

Simulates the platform deploying a new version of your app. The persistent volume data survives, but the container filesystem is fresh (no `/etc/app_configured`).

```bash
# Stop and remove the old container
docker stop my-app-test && docker rm my-app-test

# Rebuild the image (simulating a new version)
docker build --platform linux/amd64 -t my-app .

# Run with the SAME volume (data persists) but a new container
docker run --rm --platform linux/amd64 \
  -e USERNAME=admin \
  -e PASSWORD='TestPass123!' \
  -e INSTANCE_ID=test-upgrade \
  -e SKIP_APPBOX_CALLBACK=1 \
  -v my-app-data:/app/data \
  -p 3001:3001 \
  my-app
```

**Checklist:**

- [ ] Container starts without errors
- [ ] Entrypoint detects existing data and enters the UPGRADE path
- [ ] Admin user creation is SKIPPED (data already exists)
- [ ] Upgrade-specific steps run if applicable (migrations, etc.)
- [ ] API callback is sent in the background
- [ ] App starts as the main process without waiting for the callback
- [ ] App is accessible and working
- [ ] ALL previous data is preserved (accounts, settings, content)
- [ ] Login still works with original credentials

---

## 5. Process and UID Verification

Verify the app runs as the correct user and is PID 1.

```bash
# While the container is running:
docker exec my-app-test ps aux
```

**Checklist (single-process apps):**

- [ ] The main app process is running as UID 1000 (not root)
- [ ] The main app process is PID 1 (proper signal handling via `exec`)
- [ ] No orphan processes left behind from the entrypoint setup phase

**Checklist (multi-service / s6-overlay apps):**

- [ ] s6-svscan is PID 1 (this is correct — s6 is the init system)
- [ ] All app services are running as UID 1000 (not root)
- [ ] Each service is supervised by s6 (`s6-supervise` parent in process tree)
- [ ] Database services are running and accepting connections

```bash
# For s6 apps, verify the full process tree:
docker exec my-app-test ps ajxf
```

Check file ownership:

```bash
docker exec my-app-test ls -ln /app/data/
```

- [ ] All data files and directories are owned by `1000:1000`
- [ ] The app can read and write to all paths listed in `appbox.yml` `volumes`

---

## 6. Signal Handling

Verify the app shuts down cleanly when Docker sends SIGTERM.

```bash
# Time how long graceful shutdown takes
time docker stop my-app-test
```

**Checklist:**

- [ ] Container stops within 10 seconds (Docker's default grace period)
- [ ] No `killing` message in Docker logs (which means SIGTERM was ignored and Docker sent SIGKILL)
- [ ] No data corruption after stop (verify by starting again)

### Multi-service apps (s6-overlay)

For apps using s6-overlay, also verify:

- [ ] s6-overlay propagates SIGTERM to all supervised services
- [ ] All services stop cleanly (check `docker logs` for each service's shutdown messages)
- [ ] Database shutdown is clean (e.g. PostgreSQL: "database system is shut down")
- [ ] No stale PID files left behind after stop

---

## 7. Custom Fields and Environment Variables

Verify that all custom fields from `appbox.yml` are correctly used.

```bash
# Check that env vars are injected
docker exec my-app-test env | grep -E 'USERNAME|PASSWORD|INSTANCE_ID'
```

**Checklist:**

- [ ] Every custom field defined in `appbox.yml` is available as an environment variable
- [ ] Default values are applied when not overridden
- [ ] Password fields work with complex passwords (upper, lower, number, special char), including `"`, `\`, `'` and `$`
- [ ] The app does not crash or misbehave with special characters in field values, and every request or config file carrying them is built with an encoder
- [ ] Test with minimum valid input (only required fields)
- [ ] Fields with `params.showOnInstalled: false` are absent from the installed app's Configuration card
- [ ] Empty custom-field values do not leave blank rows in the installed app's Configuration card

---

## 8. Persistence Verification

Ensure data survives container replacement.

```bash
# 1. Fresh install and create some data in the app
#    (add a monitor, write a post, upload a file, etc.)

# 2. Stop and remove the container
docker stop my-app-test && docker rm my-app-test

# 3. Start a new container with the same volume
docker run -d --platform linux/amd64 --name my-app-test2 \
  -e USERNAME=admin \
  -e PASSWORD='TestPass123!' \
  -e INSTANCE_ID=test-persist \
  -e SKIP_APPBOX_CALLBACK=1 \
  -v my-app-data:/app/data \
  -p 3001:3001 \
  my-app

# 4. Verify data is still there
```

**Checklist:**

- [ ] User-created data persists across container replacement
- [ ] Admin account and credentials persist
- [ ] App settings and configuration persist
- [ ] No files are stored outside the declared `volumes` paths that should persist
- [ ] Temporary/cache files that DON'T need to persist are NOT in a volume path (keeps volumes clean)

---

## 9. Security

**Checklist:**

- [ ] Admin password uses `complexPassword` type with validation
- [ ] No default/hardcoded credentials anywhere in the image
- [ ] Public registration is disabled (only admin can create accounts)
- [ ] The app binds to `0.0.0.0` (not `127.0.0.1`) on its internal port
- [ ] No unnecessary services or ports exposed
- [ ] No secrets visible in `docker history my-app` (use env vars, not build args for secrets)
- [ ] `entrypoint.sh` does not download external scripts or binaries at runtime
- [ ] No `privileged`, `security_opt`, `pid_mode`, `network_mode`, or `dns` in `appbox.yml`

---

## 10. Service Crash Recovery (multi-service apps only)

For apps using s6-overlay, verify that crashed services are automatically restarted.

```bash
# Find the PID of a supervised service (e.g. postgres)
docker exec my-app-test pgrep -f postgres

# Kill it (simulating a crash)
docker exec my-app-test kill <pid>

# Wait a moment, then verify s6 restarted it
sleep 3
docker exec my-app-test pgrep -f postgres
```

**Checklist:**

- [ ] Killing a supervised service does NOT kill the container
- [ ] s6 restarts the crashed service automatically within seconds
- [ ] The service recovers to a working state after restart
- [ ] Other services continue running during the crash/restart
- [ ] Database services handle crash recovery correctly (stale PID cleanup, WAL recovery)
- [ ] Killing and restarting a database service does not corrupt data

---

## 11. Password Change Script (moduser.sh)

All apps must include `/moduser.sh` for password recovery. Run these tests against a container that has completed fresh install.

**Test password reset:**

```bash
docker exec my-app /moduser.sh "NewPassword456!"
# Exit code should be 0
echo $?
```

**Test that the new password works:**

After a successful password change, verify you can log in with the new password through the app's web interface or API.

**Test with missing argument:**

```bash
docker exec my-app /moduser.sh
# Should print usage and exit non-zero
```

**Checklist:**

- [ ] `/moduser.sh` exists in the container
- [ ] Script is executable (`chmod +x`)
- [ ] Accepts one argument: new password
- [ ] Successfully overwrites the existing password
- [ ] New password works for login after change
- [ ] Prints usage and exits non-zero when called with no arguments

---

## 12. appbox.yml Validation

**Checklist:**

- [ ] `app.display_name`, `app.publisher` are set
- [ ] `app.description` and `app.short_description` are meaningful
- [ ] `app.icon` points to a valid 512x512 PNG
- [ ] `app.categories` uses existing categories (or suggests a new one)
- [ ] `image.name`, `image.version` are set
- [ ] `ports` matches what the app actually listens on
- [ ] `volumes` covers all paths that need to persist
- [ ] All volume `uid` fields are `1000`
- [ ] `custom_fields` have appropriate validation rules
- [ ] `behavior.expect_callback` is `true` if the entrypoint does a callback
- [ ] The callback never runs in front of `exec`, in cont-init or in an s6 oneshot, and `tests/test-installed-callback.sh` passes
- [ ] No platform-managed fields are included (they will be ignored)
- [ ] Template variables use ALL CAPS field names (e.g. `%INSTANCE.ID%`)

---

## 13. Documentation

**Checklist:**

- [ ] `README.md` exists and explains what the app does
- [ ] `appbox.yml` comments explain non-obvious configuration choices
- [ ] `entrypoint.sh` explains the setup logic for this specific app
- [ ] If AI tools were used: code has been fully reviewed by a human

---

## 14. Custom Tables, Buttons, and Typed Operations (if used)

Complete these tests when the manifest uses any feature documented in
`CUSTOM_TABLES.md`.

**Manifest and installation:**

- [ ] Table, field, button, row-action, and operation IDs are stable and unique
- [ ] Every action references an operation declared for this app version
- [ ] Every manager executable exists and is executable in the released image
- [ ] Operation schemas reject unknown fields and invalid values
- [ ] Initial rows resolve installation fields and are not duplicated
- [ ] `initial_rows_operation`, if declared, dispatches once per seeded row
      before installation completes
- [ ] `initial_rows_operation` remains part of install completion and retries
      after partial work converge without duplicate side effects
- [ ] Retried callbacks reuse the lifecycle execution identity without exposing
      sensitive row values in logs or identifiers
- [ ] Tables without `initial_rows_operation` seed rows without dispatching an
      internal container operation
- [ ] Installation succeeds when optional initial values are omitted

**User-visible behavior:**

- [ ] Row limits and add/edit/delete flags are enforced
- [ ] Non-editable identity fields cannot be changed
- [ ] Administrator-only tables and buttons reject non-administrators
- [ ] Sensitive values are masked in ordinary views
- [ ] Reveal requires authorization
- [ ] Editing without replacing a masked secret preserves the original value
- [ ] Row actions use values from the selected row, not another row
- [ ] Confirmation phrases require an exact match
- [ ] Custom Button forms submit the expected value types
- [ ] Buttons without `visibility_conditions` remain visible and executable
- [ ] Every Custom Button condition must match before the button is returned
      or executable
- [ ] `equals`, `not_equals`, `in`, and `not_in` are tested; set operators use
      a YAML list in `value`
- [ ] Missing controlling fields fail closed for all operators, including
      `not_equals` and `not_in`
- [ ] Import rejects unknown and sensitive installation-field references
- [ ] Direct invocation of a hidden button is rejected by the API
- [ ] Matching button responses expose normalized `visibilityConditions`
- [ ] Success and failure states are understandable without command output

**Manager safety and reliability:**

- [ ] Manager reads one bounded JSON document from stdin
- [ ] Manager rejects malformed JSON, unknown operations, and unknown fields
- [ ] Identifiers and paths are validated again inside the manager
- [ ] No user value is interpolated into shell text
- [ ] Secrets do not appear in logs, process arguments, stdout, stderr, or errors
- [ ] Platform/container readiness permits dispatch only; it is not treated as
      operation readiness or success
- [ ] Managers use bounded, operation-specific checks for each required API,
      database, socket, or resource
- [ ] Tests do not require Docker `HEALTHCHECK` or treat container health as
      proof of operation readiness or success
- [ ] Managers verify authoritative postconditions and return non-zero when
      readiness, execution, or verification cannot be established
- [ ] Repeating an operation safely reconciles state
- [ ] Conflicting operations are serialized
- [ ] Timeout and non-zero exit behavior are tested

**Upgrade:**

- [ ] Existing rows and secrets remain available after an app-version upgrade
- [ ] Stable `type_of`, field IDs, button IDs, and operation IDs still map
- [ ] Newly declared initial rows are not expected to appear during upgrade
- [ ] The upgraded immutable image contains the matching manager contract

---

## 15. Conditional Installation Fields (if used)

- [ ] Fields without a `condition` remain visible
- [ ] `equals` and `not_equals` use the controlling field's manifest key
- [ ] `in` and `not_in` use a `values` array
- [ ] `truthy` and `falsy` work without a comparison value
- [ ] Controlling-field defaults affect initial visibility
- [ ] Nested defaults reveal the correct dependent field immediately
- [ ] Changing a controlling value updates dependent fields
- [ ] Hidden fields are excluded from validation and submission
- [ ] `clear_when_hidden: true` removes inactive passwords, keys, and tokens
- [ ] Re-enabling a cleared field does not restore its previous secret
- [ ] Server or manager validation does not trust visibility as authorization

---

## 16. Sensitive Installation Field Reveal Policy

- [ ] Sensitive fields are masked in ordinary instance responses
- [ ] Sensitive fields without `revealable: true` do not render a reveal action
- [ ] Their reveal endpoint returns 403 even to an authorized owner
- [ ] A field with both `sensitive: true` and `revealable: true` can be revealed
      only by a user authorized for that installed instance
- [ ] `revealable: true` without `sensitive: true` is rejected during import
- [ ] Reveal values do not appear in logs, bulk responses, or error messages
- [ ] The initial admin/login password sets `sensitive: true`, `revealable: true` and `params.showOnInstalled: true`; after install it starts masked, the owner's Show returns the value (no 403 "Custom field is write-only"), and Hide masks it again

---

## 17. Installed Instance Templates and Conditions

- [ ] `template_type: instance` resolves system placeholders and then
      `%FIELD_NAME%` references from the same installed instance
- [ ] Unknown field references remain literal instead of becoming empty
- [ ] Sensitive source values do not expand into non-sensitive destinations
- [ ] Sensitive-to-sensitive expansion remains masked in ordinary responses
- [ ] Installed Configuration hides fields whose `condition` does not match
- [ ] Missing controlling fields fail closed

---

## Quick Reference: Test Commands

```bash
# Build
docker build --platform linux/amd64 -t my-app .

# Fresh install
docker volume create my-app-data
docker run -d --platform linux/amd64 --name my-app-test \
  -e USERNAME=admin -e PASSWORD='TestPass123!' -e INSTANCE_ID=test \
  -e SKIP_APPBOX_CALLBACK=1 \
  -v my-app-data:/app/data -p 3001:3001 my-app

# Check logs
docker logs -f my-app-test

# Check process owner and PID
docker exec my-app-test ps aux

# Check file ownership
docker exec my-app-test ls -ln /app/data/

# Restart test
docker restart my-app-test

# Upgrade test
docker stop my-app-test && docker rm my-app-test
docker build --platform linux/amd64 -t my-app .
docker run -d --platform linux/amd64 --name my-app-test \
  -e USERNAME=admin -e PASSWORD='TestPass123!' -e INSTANCE_ID=test \
  -e SKIP_APPBOX_CALLBACK=1 \
  -v my-app-data:/app/data -p 3001:3001 my-app

# Password change test
docker exec my-app-test /moduser.sh "NewPassword456!"

# Graceful shutdown test
time docker stop my-app-test

# Shell into container for debugging
docker exec -it my-app-test bash

# Cleanup
docker stop my-app-test && docker rm my-app-test
docker volume rm my-app-data
```

---

## Reporting Test Results

When submitting your app, include a summary of test results in your ticket notes. At minimum confirm:

1. Fresh install works and admin user is created
2. Restart preserves state and skips setup
3. Upgrade preserves data and skips user creation
4. App runs as UID 1000 and is PID 1 (or supervised by s6 as UID 1000 for multi-service apps)
5. Graceful shutdown completes within 10 seconds
6. `/moduser.sh` changes the password successfully
7. All `appbox.yml` fields are valid

For multi-service apps, additionally confirm:

8. All services supervised by s6 and restart on crash
9. s6 dependency ordering is correct (services don't start before init scripts complete)
10. Database crash recovery works (stale PID cleanup, WAL replay)
