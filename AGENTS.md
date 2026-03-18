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

## appbox.yml

The `appbox.yml` file is the single source of truth for app configuration. See `README.md` for the full schema reference.

- Only `app` and `image` sections are required; all others have defaults.
- Template variables use `%TABLE.FIELD%` syntax (ALL CAPS), e.g. `%INSTANCE.ID%`, `%PORTS|0.EXTERNAL%`.
- Custom fields become environment variables inside the container, keyed by the field name.
- Fields of type `externalURL` render as clickable links on the installed app page. For predictable URLs, set `default_value` to a template like `https://%DOMAIN.DOMAIN%/` with `template_type: instance` — the platform resolves this at install time. For URLs only known at runtime (dynamic ports, generated paths), set the value via the API callback instead (include `custom_fields` array in the POST body). For other field type updates via callback, contact support.
- Do not include fields that are platform-managed (e.g. `privileged`, `security_opt`, `network_mode`, `dns`, `type`, `registry`). They will be ignored.

## Dockerfile Pattern

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

## entrypoint.sh Pattern

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
