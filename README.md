# Appbox Example App — Uptime Kuma

This repository is a comprehensive example of how to package an app for the Appbox platform. It uses [Uptime Kuma](https://github.com/louislam/uptime-kuma) (a self-hosted monitoring tool) as the base, demonstrating every configuration option, the entrypoint lifecycle, and best practices.

Use this as a template and reference when creating your own Appbox app.

---

## Table of Contents

- [Packaging Requirements](#packaging-requirements)
- [Repository Structure](#repository-structure)
- [appbox.yml Schema Reference](#appboxyml-schema-reference)
  - [app — Store Metadata](#app--store-metadata)
  - [image — Docker Image](#image--docker-image)
  - [container — Runtime Configuration](#container--runtime-configuration)
  - [networking — Domain and SSL](#networking--domain-and-ssl)
  - [behavior — Platform Behavior](#behavior--platform-behavior)
  - [install — Install Descriptions](#install--install-descriptions)
  - [ports — Port Configuration](#ports--port-configuration)
  - [volumes — Persistent Bind Mounts](#volumes--persistent-bind-mounts)
  - [shared_data — Shared File System Access](#shared_data--shared-file-system-access)
  - [env — Environment Variables](#env--environment-variables)
  - [custom_fields — User Input](#custom_fields--user-input)
  - [advanced — Advanced Settings](#advanced--advanced-settings)
- [Custom Field Types](#custom-field-types)
- [Custom Field Validation Rules](#custom-field-validation-rules)
- [Template Variables](#template-variables)
- [Available Categories](#available-categories)
- [Port Types Explained](#port-types-explained)
- [Volume Bind Types](#volume-bind-types)
- [Shared File System](#shared-file-system)
- [Multi-Service Apps (s6-overlay)](#multi-service-apps-s6-overlay)
- [Entrypoint Lifecycle](#entrypoint-lifecycle)
- [API Callback](#api-callback)
- [Password Change Script (moduser.sh)](#password-change-script-modusersh)
- [Embedding Databases](#embedding-databases)
- [Security Checklist](#security-checklist)
- [Step-by-Step: Creating a New App](#step-by-step-creating-a-new-app)
- [Submitting Your App](#submitting-your-app)

---

## Packaging Requirements

1. **Single container** — Apps must be fully self-contained in one Docker container with no external dependencies. No separate database containers, no docker-compose, no sidecar services. If the app needs a database, it must be embedded (e.g. SQLite) or bundled inside the same container.

2. **Init system** — If your app needs multiple services running in a single container (e.g. app server + database + background worker), you MUST use **s6-overlay** as the init/process supervisor. It handles process lifecycle, restarts, and signal forwarding correctly for multi-service containers. For single-process apps, a plain bash entrypoint with `exec` is sufficient. When building on an existing upstream image (as this example does with Uptime Kuma), any init approach is acceptable — the priority is reusing well-maintained official images over custom builds.

3. **Entrypoint** — Regardless of init system, the app must follow the Appbox entrypoint lifecycle: first-run setup, upgrade detection, platform callback, then exec the main process. See [Entrypoint Lifecycle](#entrypoint-lifecycle).

4. **Secure by default** — Apps should be configured securely out of the box. Use strong password validation, disable public registration, and bind to appropriate interfaces.

5. **User namespaces (userns)** — All Appbox containers run with user namespaces enabled for security. UID 0 (root) inside the container is mapped to an unprivileged UID on the host. Your app's main process **must run as UID 1000** inside the container. All files and directories the app touches **must be owned by 1000:1000** inside the container. The entrypoint runs as root (UID 0 inside the container) only for `/etc/resolv.conf` and `/etc/hosts` setup, then drops to UID 1000 via `gosu`.

6. **UID 1000 everywhere** — This is critical. Whether you're creating directories in the Dockerfile, chowning data paths in the entrypoint, or running the main process, always use UID/GID 1000. If the upstream image uses a different UID, add `chown -R 1000:1000 /path/to/data` in your Dockerfile or entrypoint.

7. **Password change script** — All apps **must** include a `moduser.sh` script at the container root (`/moduser.sh`). This allows users to reset the default user's password if they get locked out. The script accepts one argument: the new password. It is run via `docker exec <container> /moduser.sh <new_password>`.

---

## Repository Structure

```
example-app/
├── AGENTS.md        # Instructions for AI coding agents
├── appbox.yml       # App configuration (metadata, ports, volumes, env, fields, etc.)
├── Dockerfile       # Container image definition
├── entrypoint.sh    # Lifecycle script (setup, upgrade, callback)
├── icon.png         # App icon (512x512 PNG) for the store listing
├── moduser.sh       # Password change script (required for all apps)
├── README.md        # This documentation
└── TESTING.md       # Testing framework for pre-submission validation
```

| File | Purpose |
|------|---------|
| `AGENTS.md` | Instructions for AI coding agents working on Appbox apps. Covers constraints, patterns, and the human review policy. |
| `appbox.yml` | Single source of truth for all app configuration. The platform reads this to create database records for the app. |
| `Dockerfile` | Wraps the upstream image with the Appbox entrypoint, installing required tools (bash, curl, gosu). |
| `entrypoint.sh` | Handles first-run setup (creating admin user), upgrade detection, platform callback, and privilege dropping. |
| `icon.png` | 512x512 PNG icon displayed in the app store. Uploaded to the platform's image server during registration. |
| `moduser.sh` | Password change script. Allows users to change the default user's password if locked out. Required for all apps. |
| `TESTING.md` | Testing framework with checklists for all test scenarios. Complete before submitting. |

---

## appbox.yml Schema Reference

The `appbox.yml` file is organized into sections. Only `app` and `image` are required; all other sections have sensible defaults and can be omitted.

### app — Store Metadata

Controls how your app appears in the Appbox app store. Maps to the `apps` database table.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `display_name` | string | Yes | — | App name shown in the store. Must be unique. |
| `publisher` | string | Yes | — | Developer or organization name. |
| `description` | string | Yes | — | Full description (Markdown supported). Shown on the app detail page. |
| `short_description` | string | No | Truncated `description` | Brief summary for store cards. |
| `icon` | string | No | `default-app.png` | Path to icon file relative to repo root. Must be 512x512 PNG. |
| `categories` | list | No | `[]` | Category names for store filtering. See [Available Categories](#available-categories). |
| `devsite` | string | No | `null` | Developer website URL. Shown as "Visit developer" link. |
| `source_repo` | string | No | `null` | Source code repository URL. |

### image — Docker Image

Defines the Docker image to pull. Maps to `apps` and `app_versions` tables.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | Yes | — | Docker image name (e.g. `louislam/uptime-kuma`) |
| `version` | string | Yes | — | Version string shown to users |
| `tag` | string | No | Same as `version` | Docker tag to pull |

### container — Runtime Configuration

Docker container settings. All optional. Maps to `apps` table.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `cmd` | string | `null` | Override container CMD |
| `user` | string | `null` | Container user (e.g. `"1000"`, `"user:group"`) |
| `group_add` | string | `null` | Additional groups, comma-separated |
| `memory` | integer | `0` | Memory limit in GB (0 = unlimited) |
| `memory_swap` | integer | `0` | Memory + swap limit in GB |
| `memory_reservation` | integer | `0` | Soft memory limit in GB |
| `cpus` | float | `0` | CPU limit (0 = unlimited, 0.5 = half core) |
| `init` | boolean | `false` | Use tini init process |
| `cap_add` | string | `null` | Linux capabilities to add (e.g. `"NET_ADMIN,SYS_PTRACE"`) |
| `cap_drop` | string | `null` | Capabilities to drop (e.g. `"ALL"`) |
| `shm_size` | integer | `null` | Shared memory size in bytes |
| `pids_limit` | integer | `null` | Max process count |

### networking — Domain and SSL

Controls domain assignment and reverse proxy behavior. Maps to `apps` table.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `subdomain` | string | — | Default subdomain prefix (required for web apps) |
| `is_web_app` | boolean | `false` | Accessible via HTTP reverse proxy |
| `requires_domain` | boolean | `false` | Requires domain assignment during install |
| `ssl` | boolean | `false` | Provision SSL certificate |
| `multiple_domains` | boolean | `false` | Allow multiple domains |
| `tcp_passthrough` | boolean | `false` | Forward TCP directly (no HTTP proxy) |

### behavior — Platform Behavior

Controls the app's lifecycle on the platform. Maps to `apps` table.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `app_slots` | integer | `1` | Resource slots consumed (required) |
| `expect_callback` | boolean | `false` | Wait for container callback before marking installed |
| `callback_requires_auth` | boolean | `false` | Callback must include CALLBACK_TOKEN |
| `restart_text` | string | `null` | Warning shown before restart |
| `can_update` | boolean | `true` | Allow user-initiated updates |
| `update_text` | string | `null` | Warning shown before update |
| `allow_downgrade` | boolean | `false` | Allow version downgrades |
| `ssl_restart` | boolean | `false` | Auto-restart every 15 days for SSL renewal |

### install — Install Descriptions

Text shown during installation. Maps to `apps` table.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `pre_description` | string | `null` | Shown above the custom fields form |
| `post_description` | string | `null` | Shown after installation completes |
| `custom_description` | string | `null` | Replaces default install description |

### ports — Port Configuration

Defines ports to be **publicly exposed** on the host. See [Port Types Explained](#port-types-explained) for details.

> **Web apps**: If your app is a web app (`is_web_app: true`) and only exposes a web UI, you do **not** need any ports here. The platform reverse-proxies HTTP traffic via nginx automatically. Instead, set `VIRTUAL_PORT` in the `env` section to the HTTP port your app listens on (default: 80). Only define ports here for non-HTTP traffic (game servers, custom protocols, etc.). Defining your HTTP port here would expose it publicly, bypassing the reverse proxy and SSL.

```yaml
ports:
  tcp:
    range: null         # Fixed internal port(s), random external
    dynamic: 0          # Count of random ports (internal = external)
  udp:
    range: null
    dynamic: 0
  combined:             # Both TCP and UDP on same port
    range: null
    dynamic: 0
```

Maps to `apps` table: `TCPPortRange`, `UDPPortRange`, `CombinedPortRange`, `TCPDynamicPorts`, `UDPDynamicPorts`, `CombinedDynamicPorts`.

### volumes — Persistent Bind Mounts

Directories persisted across restarts and upgrades. Maps to `appbinds` table.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | string | Yes | Host directory name (relative to `/apps/<domain>/`) |
| `destination` | string | Yes | Mount point inside the container |
| `permissions` | string | Yes | `rw` (read-write) or `ro` (read-only) |
| `uid` | integer | Yes | Owner UID inside the container. Always `1000` (see note below) |

> **UID explained**: The `uid` field should always be `1000`, matching the UID your app runs as inside the container. The platform handles host-side UID remapping via user namespaces automatically — you do not need to worry about host UIDs.

### shared_data — Shared File System Access

Mounts the user's shared home directory into the container so the app can access data from other installed apps. Maps to `appbinds` table. See [Shared File System](#shared-file-system) for full details.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | string | Yes | Absolute host path using template variables (e.g. `/cylostore/%CYLO.DISK_NAME%/%CYLO.ID%/home/apps/`) |
| `destination` | string | Yes | Mount point inside the container (e.g. `/APPBOX_DATA`) |
| `permissions` | string | Yes | `rw` (read-write) or `ro` (read-only) |
| `uid` | integer | Yes | Owner UID inside the container. Always `1000` |

```yaml
shared_data:
  - source: "/cylostore/%CYLO.DISK_NAME%/%CYLO.ID%/home/apps/"
    destination: "/APPBOX_DATA"
    permissions: "rw"
    uid: 1000
```

### env — Environment Variables

Variables injected into the container. Maps to `appenvironmentvars` table.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `key` | string | Yes | Environment variable name |
| `value` | string | Yes | Value (supports [template variables](#template-variables)) |
| `template_type` | string | Yes | How to resolve the value: `none`, `password`, `complexPassword`, `hidden`, `instance` |

The platform also auto-injects: `INSTANCE_ID`, `VIRTUAL_HOST`, `CALLBACK_TOKEN`.

> **`VIRTUAL_PORT`**: Required for web apps (`is_web_app: true`) not listening on port 80. Set this to the HTTP port your app listens on inside the container. The platform's nginx reverse proxy uses it to route traffic. Must be plain HTTP — the platform handles SSL termination. If your app listens on port 80, this is not needed.

### custom_fields — User Input

Form fields shown during installation. Maps to `customfields` table. See [Custom Field Types](#custom-field-types) and [Custom Field Validation Rules](#custom-field-validation-rules).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `label` | string | Yes | Display label |
| `type` | string | Yes | Input type (see below) |
| `width` | integer | No | Grid width 1–12 (default: 12) |
| `default_value` | string | No | Pre-filled value |
| `template_type` | string | No | Template resolution: `none`, `password`, `complexPassword`, `hidden` |
| `validate` | list | No | Validation rules (see below) |
| `params` | object | No | Type-specific parameters |

### advanced — Advanced Settings

Rarely needed container configuration.

| Section | Table | Fields per entry |
|---------|-------|-----------------|
| `devices` | `appdevices` | `host_path`, `container_path`, `cgroup_permissions` |
| `ulimits` | `appulimits` | `name`, `soft`, `hard` |
| `sysctls` | `appsysctl` | `name`, `value` |
| `chains` | `appchains` | `chained_to` (app name or ID) |

---

## Custom Field Types

| Type | Rendering | Value | Use case |
|------|-----------|-------|----------|
| `dynamicText` | Standard text input | User-entered string | Usernames, site names, general text |
| `alphaNumeric` | Text input (alphanumeric only) | Letters and numbers | Identifiers, slugs |
| `password` | Masked password input | User-entered or auto-generated (`%RAND.N%`) | Passwords |
| `complexPassword` | Masked input with complexity enforcement | Must include upper, lower, number, special char | Admin passwords |
| `number` | Numeric input | Integer or float | Port numbers, limits, sizes |
| `email` | Email input with validation | Valid email address | Admin email, notification address |
| `date` | Date input | Date string | Expiry dates, schedules |
| `switch` | Toggle switch | `"1"` (on) or `"0"` (off) | Feature toggles, boolean settings |
| `selector` | Dropdown menu | Selected option value | Theme selection, mode selection |
| `staticText` | Read-only display | Shows `default_value` | Information, URLs, generated values |
| `externalURL` | Read-only clickable link | Set by container via API callback | URLs only known after the app starts (e.g. admin panel, API endpoint) |
| `hidden` | Not rendered | Auto-generated (e.g. `%RAND.32%`) | Internal tokens, secrets |
| `spacer` | Visual spacing | No value | Layout control |

### Selector params

```yaml
params:
  menuItems:
    value1: "Display Label 1"
    value2: "Display Label 2"
```

### Switch params (custom labels)

```yaml
params:
  menuItems:
    "1": "Enabled"
    "0": "Disabled"
```

---

## Custom Field Validation Rules

### String rules

| Rule | Description |
|------|-------------|
| `required` | Field must not be empty |
| `alphanumeric` | Only letters and numbers allowed |
| `notOnlyAlpha` | Must contain at least one non-letter character |
| `complexPassword` | Must include uppercase, lowercase, number, and special character |
| `email` | Must be a valid email address |
| `date` | Must be a valid date |

### Object rules

| Rule | Example | Description |
|------|---------|-------------|
| `minLength` | `{ minLength: 3 }` | Minimum character count |
| `maxLength` | `{ maxLength: 50 }` | Maximum character count |
| `matches` | `{ matches: "^[a-z]+$" }` | Must match regex (set `params.regex` and `params.errorText` too) |

### Example with multiple rules

```yaml
validate:
  - required
  - alphanumeric
  - { minLength: 3 }
  - { maxLength: 32 }
```

---

## Template Variables

Template variables are resolved at install time by the platform's TemplateService. They can be used in `env` values, `custom_fields` default values, and `volumes` source paths.

### Syntax

| Pattern | Description | Example |
|---------|-------------|---------|
| `%TABLE.FIELD%` | Single value lookup | `%INSTANCE.ID%` |
| `%TABLE\|N.FIELD%` | Array index (0-based) | `%PORTS\|0.EXTERNAL%` |
| `%RAND.N%` | Random hex string of N chars | `%RAND.32%` |
| `%PASSWORD%` | First password field's value | `%PASSWORD%` |
| `%MATH.V1.OP.V2%` | Math: `+`, `-`, `*`, `/` | `%MATH.100.+.50%` → `150` |

### %INSTANCE.*%

Available when `template_type` is `instance`. Fields from the `appinstances` table plus derived values.

| Field | Description |
|-------|-------------|
| `ID` | Instance ID |
| `APP_ID` | App ID |
| `VERSION` | Installed version |
| `CALLBACK_TOKEN` | Auth token for callbacks |

### %CYLO.*%

The user's Cylo (account) record.

| Field | Description |
|-------|-------------|
| `ID` | Cylo ID |
| `CYLONAME` | Cylo name |
| `SERVER_IP` | Server IP address |

### %SERVER.*%

The physical server hosting this instance.

| Field | Description |
|-------|-------------|
| `ID` | Server ID |
| `DISPLAY_NAME` | Server display name |
| `IP` | Public IP address |

### %DOMAIN.*%

The domain assigned to this app instance.

| Field | Description |
|-------|-------------|
| `ID` | Domain ID |
| `DOMAIN` | Domain name |
| `INSTANCE_ID` | Linked instance ID |

### %USER.*%

The user who owns this instance.

| Field | Description |
|-------|-------------|
| `ID` | User ID |
| `FIRSTNAME` | First name |
| `LASTNAME` | Last name |
| `EMAIL` | Email address |

### %APP.*%

The app definition.

| Field | Description |
|-------|-------------|
| `ID` | App ID |
| `DISPLAY_NAME` | App name |
| `PUBLISHER` | Publisher name |
| `DESCRIPTION` | Full description |
| `SHORT_DESCRIPTION` | Short description |

### %PORTS|N.*%

Port allocations (0-indexed). Available after ports are assigned.

| Field | Description |
|-------|-------------|
| `INTERNAL` | Container port |
| `EXTERNAL` | Host port (the one users connect to) |
| `TYPE` | Protocol: `tcp`, `udp`, or `combined` |
| `QTY` | Port count (for dynamic allocations) |

---

## Available Categories

Existing categories you can use in the `app.categories` list:

- Blogs
- CMS
- Communication
- Databases
- Documentation
- File Manager
- Games
- Marketing
- Media
- Notes
- Operating System
- Privacy
- Programming
- Projects
- SEO Utilities
- Stacks
- Streaming
- Sync
- Torrent Clients
- VPS
- Webserver
- Windows

If none of these fit your app, you can suggest a new category in your submission. All apps are automatically added to "All Apps" — do not include it.

---

## Port Types Explained

> **Reminder**: Web-only apps do not need ports defined here — use `VIRTUAL_PORT` in the `env` section instead. The `ports` section is for publicly exposed non-HTTP traffic.

The platform supports four port allocation patterns:

### 1. Fixed internal, random external (most common)

Your app listens on a known port. The platform assigns a random available host port.

```
Container port 25575 ←→ Host port 14523 (randomly assigned)
```

```yaml
ports:
  tcp:
    range: "25575"
```

The user accesses the app via the external port. Use `%PORTS|0.EXTERNAL%` in env vars to pass the external port to the app if needed.

### 2. Fixed range, random external

Multiple known ports, each mapped to a random host port.

```
Container port 8000 ←→ Host port 14523
Container port 8001 ←→ Host port 14524
...
Container port 8010 ←→ Host port 14534
```

```yaml
ports:
  tcp:
    range: "8000-8010"
```

### 3. Dynamic ports (random internal = external)

The platform allocates N consecutive ports where internal and external are the same.

```
Port 14523 ←→ Port 14523 (same inside and outside)
Port 14524 ←→ Port 14524
Port 14525 ←→ Port 14525
```

```yaml
ports:
  tcp:
    dynamic: 3
```

Use when your app can be configured to listen on any port.

### 4. Mixed protocols

Different protocols can be configured independently:

```yaml
ports:
  tcp:
    range: "25575"        # RCON on TCP
    dynamic: 0
  udp:
    range: "27015"        # Game traffic on UDP
    dynamic: 0
  combined:
    range: "5060"         # SIP on both TCP and UDP
    dynamic: 0
```

### Range format

The `range` field accepts:

| Format | Example | Ports |
|--------|---------|-------|
| Single port | `"25575"` | 25575 |
| Range | `"8080-8090"` | 8080, 8081, ..., 8090 |
| Multiple | `"80,443"` | 80, 443 |
| Mixed | `"80,443,8080-8090"` | 80, 443, 8080–8090 |

---

## Volume Bind Mounts

All volume bind mounts store data under the user's app directory at `/apps/<app-domain>/<source>`. The platform handles the host-side directory creation and ownership automatically.

**File ownership inside the container**: All data directories must be owned by UID 1000:GID 1000 inside the container. If the upstream image creates data directories owned by a different user, add a `chown -R 1000:1000 /path` step in your Dockerfile or entrypoint.

Always set `uid: 1000` in your volume definitions. The platform handles host-side UID remapping via user namespaces automatically.

### Shared storage

Volumes defined in `appbox.yml` are stored in the **shared** home area:

```
/cylostore/<disk>/<cylo_id>/home/apps/<app-domain>/<source>/
```

This means other apps on the same account **can** access your app's data if they have the shared file system mounted (see [Shared File System](#shared-file-system) below). This is by design — it enables cross-app workflows like torrent clients sharing downloads with media players.

---

## Shared File System

Apps on the Appbox platform can access each other's data through a shared file system. This enables powerful cross-app workflows — for example, a torrent client downloads files that a media player (Plex, Jellyfin) can immediately access, or an FTP server exposes all app data for remote access.

### How it works

Every app's `volumes` (the `home` storage) are stored on the host at:

```
/cylostore/<disk>/<cylo_id>/home/apps/
├── plex.user-domain.com/
│   └── config/
├── rtorrent.user-domain.com/
│   └── downloads/
├── jellyfin.user-domain.com/
│   ├── config/
│   └── cache/
├── openclaw.user-domain.com/
│   └── data/
└── ...
```

When an app needs access to other apps' data, it mounts this `home/apps/` tree (or the parent `home/` directory) into the container. Inside the container, the app sees:

```
/APPBOX_DATA/
├── plex.user-domain.com/
│   └── config/
├── rtorrent.user-domain.com/
│   └── downloads/
├── jellyfin.user-domain.com/
│   ├── config/
│   └── cache/
└── ...
```

### Use cases

| App type | Why it needs shared access | Example |
|----------|---------------------------|---------|
| Media players | Read downloads/media from torrent clients | Plex, Jellyfin, Emby reading from `/APPBOX_DATA/<torrent-app>/downloads/` |
| File managers | Browse and manage all app data | File Browser, SFTPGo exposing `/APPBOX_DATA/` |
| FTP servers | Remote access to app files | Pure-FTPd serving `/APPBOX_DATA/` |
| AI assistants | Read/write user files across apps | OpenClaw accessing documents, media, configs |
| OS/VPS apps | Full access to user's app ecosystem | Ubuntu Desktop, Debian browsing all data |
| Sync tools | Sync data between apps or to external services | Nextcloud, OwnCloud syncing from `/APPBOX_DATA/` |

### Configuring shared access in appbox.yml

Use the `shared_data` section in `appbox.yml` to mount the shared file system. The `source` uses template variables that the platform resolves at install time:

```yaml
shared_data:
  - source: "/cylostore/%CYLO.DISK_NAME%/%CYLO.ID%/home/apps/"
    destination: "/APPBOX_DATA"
    permissions: "rw"
    uid: 1000
```

The source path typically points to:

| Path | Contents |
|------|----------|
| `/cylostore/%CYLO.DISK_NAME%/%CYLO.ID%/home/apps/` | All apps' shared volumes (most common) |
| `/cylostore/%CYLO.DISK_NAME%/%CYLO.ID%/home/` | The full home directory |

The `destination` is where the shared data appears inside the container. By convention, `/APPBOX_DATA` is used, but you can choose any path that suits your app (e.g. `/media`, `/storage`, `/home/user/data`).

Set `permissions` to `ro` if your app only needs to read other apps' data. Use `rw` if it also needs to write (e.g. a file manager).

---

## Multi-Service Apps (s6-overlay)

This example (Uptime Kuma) is a single-process app. For apps requiring multiple services in one container (e.g. web app + PostgreSQL + Redis), use s6-overlay as the process supervisor. If your base image is from LinuxServer.io (LSIO) or ImageGenius, s6-overlay is already included.

### Architecture

```
entrypoint.sh (one-time setup)
    └── exec /init (s6-overlay)
            ├── init-adduser (oneshot)
            ├── init-config-* (oneshot)
            ├── svc-postgres (longrun)
            ├── svc-redis (longrun)
            ├── svc-server (longrun)
            └── svc-microservices (longrun)
```

### Key differences from single-process apps

| Aspect | Single-process | Multi-service (s6-overlay) |
|--------|---------------|---------------------------|
| CMD | `["node", "server.js"]` | `["/init"]` |
| Process supervision | None (app is PID 1) | s6 supervises all services |
| Crash recovery | Container restarts | s6 restarts the crashed service |
| Graceful shutdown | Docker SIGTERM to PID 1 | s6 propagates SIGTERM to all services |
| User switching | `exec gosu 1000:1000 "$@"` | Each service `run` script uses `gosu` or `s6-setuidgid` |
| Callback timing | Before `exec` (synchronous) | Background subshell after `exec /init` (async) |

### s6 service dependency ordering

**Critical:** s6-rc starts services in parallel with init scripts unless you declare explicit dependencies. Without them, services start before init scripts create users, fix permissions, or set up directories.

Add dependency files to each service's `dependencies.d/` directory in the Dockerfile:

```dockerfile
RUN mkdir -p /etc/s6-overlay/s6-rc.d/svc-myapp/dependencies.d && \
    touch /etc/s6-overlay/s6-rc.d/svc-myapp/dependencies.d/legacy-cont-init && \
    touch /etc/s6-overlay/s6-rc.d/svc-myapp/dependencies.d/init-config-myapp
```

To inspect the live dependency graph:
```bash
# List all services in the compiled database
s6-rc-db -c /run/s6/db list all

# Check what a service depends on
s6-rc-db -c /run/s6/db dependencies svc-myapp
```

### Overriding LSIO init scripts

LSIO init scripts may run expensive operations on every boot (e.g. recursively chowning thousands of immutable image-layer files). Override them by copying a replacement script:

```dockerfile
COPY init-config-myapp /etc/s6-overlay/s6-rc.d/init-config-myapp/run
RUN chmod +x /etc/s6-overlay/s6-rc.d/init-config-myapp/run
```

### Entrypoint pattern for s6 apps

The entrypoint performs one-time setup (database initialization, directory creation) then `exec "$@"` to hand off to `/init`. Since `/init` takes over as PID 1, the Appbox lifecycle (admin creation, callback) runs in a **background subshell**:

```bash
#!/bin/bash
set -e

# ... one-time setup (initdb, migrations, etc.) ...

if [[ ! -f /etc/app_configured ]]; then
    touch /etc/app_configured
    (
        set +e   # prevent set -e from killing subshell on timeout
        wait_for_http "http://localhost:8080/api/health" 300 2
        # ... admin creation, callback ...
    ) &
fi

exec "$@"   # becomes: exec /init
```

**Warning:** `set -e` propagates into `( ... ) &` subshells. If `wait_for_http` times out (returns 1), `set -e` kills the subshell before `callback_installed` runs, leaving the app stuck in "installing" state forever. Always use `set +e` at the top of the subshell.

---

## Entrypoint Lifecycle

The entrypoint script detects three container states based on two signals:

| Signal | File | Persisted? | Survives restart? | Survives upgrade? |
|--------|------|-----------|-------------------|-------------------|
| App data | `/app/data/kuma.db` (in volume) | Yes | Yes | Yes |
| Config flag | `/etc/app_configured` (container fs) | No | Yes | No |

### State detection

```
                    ┌──────────────────────────┐
                    │    Container starts       │
                    └────────────┬─────────────┘
                                 │
                    ┌────────────▼─────────────┐
                    │  /etc/app_configured      │
                    │  exists?                  │
                    └────┬──────────────┬──────┘
                         │ No           │ Yes
                         │              │
              ┌──────────▼──────────┐   │
              │ Touch               │   │
              │ /etc/app_configured │   │
              └──────────┬──────────┘   │
                         │              │
              ┌──────────▼──────────┐   │
              │ Persisted data      │   │
              │ exists?             │   │
              └───┬────────────┬────┘   │
                  │ No         │ Yes    │
                  │            │        │
       ┌──────────▼──────┐ ┌──▼─────┐  │
       │  FRESH INSTALL  │ │UPGRADE │  │
       │  Start app      │ │Skip    │  │
       │  Create admin   │ │user    │  │
       │  Stop app       │ │setup   │  │
       └──────────┬──────┘ └──┬─────┘  │
                  │            │        │
              ┌───▼────────────▼───┐    │
              │   API Callback     │    │
              │   (retry loop)     │    │
              └────────┬───────────┘    │
                       │                │
              ┌────────▼────────────────▼──┐
              │  exec gosu 1000:1000 "$@"  │
              │  (run app as PID 1)        │
              └────────────────────────────┘
```

### Fresh install

1. Mark container as configured (`/etc/app_configured`)
2. App started in background
3. Wait for app to be ready (poll HTTP)
4. Create admin user via app's setup API
5. Stop the background app
6. Call platform API callback
7. Start app with `exec` as PID 1

### Upgrade

1. Mark container as configured
2. Skip user creation (data exists)
3. Optional: run migration steps
4. Call platform API callback
5. Start app with `exec` as PID 1

### Restart

1. Skip all setup (both signals exist)
2. Start app with `exec` as PID 1

---

## API Callback

When `behavior.expect_callback` is `true`, the platform waits for the container to signal that setup is complete before showing the app as "installed" to the user.

**Endpoint:**

```
POST https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}
```

**Headers:**

```
Accept: application/json
Content-Type: application/json
```

If `behavior.callback_requires_auth` is `true`, also include:

```
Authorization: Bearer ${CALLBACK_TOKEN}
```

**Behavior:**
- `INSTANCE_ID` is injected as an environment variable
- The script retries every 5 seconds until HTTP 200
- The callback is idempotent (safe to call multiple times)
- Without the callback, the user sees the app as "installing" indefinitely

### externalURL Fields

Fields of type `externalURL` render as clickable links on the installed app page. There are two approaches:

#### Approach 1: Template variable (preferred for predictable URLs)

If the URL follows a known pattern (e.g. `https://<domain>/`), use a template variable in `default_value`. The platform resolves it at install time — no callback payload needed.

```yaml
custom_fields:
  LOGIN_URL:
    label: "Login URL"
    type: externalURL
    width: 12
    default_value: "https://%DOMAIN.DOMAIN%/"
    template_type: instance
    validate: []
    params: {}
```

#### Approach 2: Set via callback (for runtime-dependent URLs)

If the URL depends on values only known after the app starts (dynamic ports, generated paths), set it via the API callback.

**Defining the field in appbox.yml:**

```yaml
custom_fields:
  ADMIN_PANEL:
    label: "Admin Panel"
    type: externalURL
    width: 12
    default_value: ""
    template_type: none
    validate: []
    params: {}
```

**Setting the value in entrypoint.sh:**

```bash
ADMIN_URL="https://${DOMAIN}:${ADMIN_PORT}/admin"

curl -s -o /dev/null -w "%{http_code}" \
  -X POST "https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d "{\"custom_fields\": [{\"key\": \"ADMIN_PANEL\", \"value\": \"${ADMIN_URL}\"}]}"
```

**Rules:**
- `key` must match the custom field name defined in `appbox.yml`
- Only fields with type `externalURL` can be set this way — all other types are ignored
- If the field already has a value (e.g. from a previous install), it is updated
- If you need to update other custom field types via callback, please contact us via [support ticket](https://billing.appbox.co/submitticket.php?step=2&deptid=1)

---

## Password Change Script (moduser.sh)

All Appbox apps **must** include a `/moduser.sh` script inside the container. This provides a way for users to change the default user's password if they get locked out.

**Interface:**

```bash
/moduser.sh <new_password>
```

**Requirements:**
- Located at `/moduser.sh` in the container root
- Accepts exactly 1 argument: the new password
- Overwrites the existing password unconditionally (this is a recovery tool)
- Exits non-zero on failure
- Does not need to produce output on success (but may)

**How it is run:**

```bash
docker exec <container_name> /moduser.sh "new-password"
```

**Implementation approaches** (choose what fits your app):

| Approach | When to use |
|----------|-------------|
| App CLI tool | Preferred if the app provides a password-reset command |
| Direct database update | App uses SQLite/embedded DB with a known schema |
| Config file rewrite | App reads credentials from a config file |

See `moduser.sh` in this repository for a working example using Uptime Kuma's built-in `npm run reset-password` CLI.

---

## Embedding Databases

Some apps require a real database (PostgreSQL, MySQL, etc.) rather than SQLite. Since Appbox requires single-container deployment, you must embed the database inside the same container.

### PostgreSQL

When bundling PostgreSQL:

1. **Install from the official repo** — Use the PGDG apt repository for the exact major version the app requires. The app's extensions (`.so` files) are compiled against a specific PG major version and won't work with a different one.

2. **Initialize the data directory before services start** — Run `initdb` in the entrypoint (before `exec /init`), not in an s6 service. This ensures the data directory exists and is ready when the PostgreSQL service starts:
   ```bash
   PG_DATA="/config/postgres"
   if [[ ! -f "${PG_DATA}/PG_VERSION" ]]; then
       gosu 1000:1000 /usr/lib/postgresql/14/bin/initdb -D "${PG_DATA}"
       # configure postgresql.conf, create database, etc.
   fi
   ```

3. **UID must exist in `/etc/passwd`** — PostgreSQL's `initdb` calls `getpwuid()` and fails with "could not look up effective user ID" if the UID has no entry. When using LSIO base images, the `init-adduser` script creates the user, but the entrypoint runs *before* `/init`. Bootstrap the user:
   ```bash
   if ! getent passwd 1000 >/dev/null 2>&1; then
       echo "appuser:x:1000:1000::/config:/usr/sbin/nologin" >> /etc/passwd
   fi
   if ! getent group 1000 >/dev/null 2>&1; then
       echo "appuser:x:1000:" >> /etc/group
   fi
   ```

4. **Data directory permissions** — PostgreSQL requires mode 700 on its data directory. LSIO init scripts may reset `/config` permissions to 755. Fix it in the s6 `run` script, immediately before starting PG:
   ```bash
   chmod 700 /config/postgres
   exec gosu 1000:1000 /usr/lib/postgresql/14/bin/postgres -D /config/postgres
   ```

5. **Crash recovery (stale PID files)** — After an unclean shutdown, a stale `postmaster.pid` prevents PostgreSQL from starting. Clean it up:
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

6. **Socket directory** — Create and chown `/var/run/postgresql` before starting PG (it's a tmpfs and may not exist):
   ```bash
   mkdir -p /var/run/postgresql && chown 1000:1000 /var/run/postgresql
   ```

7. **Extensions and `shared_preload_libraries`** — Some extensions (e.g. pgvecto.rs, pgvector) must be listed in `shared_preload_libraries` in `postgresql.conf` *before* PostgreSQL starts. Configure this during `initdb`, not after.

### Redis

Redis is straightforward to embed:
- Install `redis-server`
- Run it as an s6 longrun service: `exec gosu 1000:1000 redis-server --dir /config/redis`
- Redis automatically creates its data files on first start

### moduser.sh for embedded databases

When the app has no CLI password-reset command, `moduser.sh` must update the database directly. Key considerations:

- **Hash the password** using the app's expected algorithm (bcrypt, argon2, etc.). Install the hashing library during the Docker build.
- **Module resolution** — Globally installed npm packages may not be found by Node.js at runtime. Set `NODE_PATH=/usr/lib/node_modules` explicitly.
- **Schema knowledge** — You must know the exact table and column names. They may differ from what you'd expect (e.g. Immich uses a quoted `"user"` table, not `users`). Check the app's migration files or running database to confirm.
- **Reserved SQL keywords** — Table names like `user` are reserved in PostgreSQL and must be double-quoted in SQL: `UPDATE "user" SET password = '...'`

---

## Security Checklist

When creating an Appbox app, ensure:

- [ ] **UID 1000**: App process runs as UID 1000 inside the container, all data dirs owned by 1000:1000
- [ ] **User namespaces**: Never assume root inside the container has host root privileges — userns is always enabled
- [ ] **Strong passwords**: Use `complexPassword` type for admin password fields
- [ ] **No default credentials**: Either require user input or auto-generate with `%RAND.N%`
- [ ] **Bind to 0.0.0.0**: The platform handles external access through port mapping
- [ ] **Disable public registration**: Configure the app so only the admin can create accounts
- [ ] **HTTPS**: Set `networking.ssl: true` for all web apps
- [ ] **Non-root process**: Use `gosu 1000:1000` to drop from root to UID 1000 before exec
- [ ] **Minimal capabilities**: Request only the `cap_add` capabilities your app actually needs
- [ ] **Data persistence**: Ensure all important data is in a `volumes` path
- [ ] **Upgrade safety**: Test that upgrades preserve user data
- [ ] **Volume UIDs**: All volume `uid` fields set to `1000`
- [ ] **moduser.sh**: Password change script included and working at `/moduser.sh`

---

## Step-by-Step: Creating a New App

1. **Choose your base image** — Find an official Docker image for the app you want to package. Check Docker Hub or the app's GitHub for maintained images. If the app needs multiple services, look for a monolithic image (e.g. LinuxServer.io, ImageGenius) that bundles everything with s6-overlay.

2. **Create the repository** — Set up a new Git repo with these files:
   - `appbox.yml`
   - `Dockerfile`
   - `entrypoint.sh`
   - `moduser.sh`
   - `icon.png` (512x512)
   - For multi-service apps: s6 service `run` scripts and any init script overrides

3. **Write `appbox.yml`** — Start with the required sections (`app` and `image`), then add what your app needs. Copy from this example and modify. Key decisions:
   - What ports does the app listen on? → `ports` section
   - What data needs to persist? → `volumes` section
   - What does the user need to configure? → `custom_fields` section
   - Does the app need a domain? → `networking` section
   - Does the app need a database? → embed it and add its data dir to `volumes`

4. **Write the Dockerfile** — Follow this pattern:
   ```dockerfile
   FROM <upstream-image>:<tag>
   RUN <install bash, curl, gosu>
   ADD entrypoint.sh /entrypoint.sh
   ADD moduser.sh /moduser.sh
   RUN chmod +x /moduser.sh
   ENTRYPOINT ["/entrypoint.sh"]
   CMD [<app's default command>]       # or CMD ["/init"] for s6 apps
   EXPOSE <internal port>
   ```
   For multi-service apps, also define s6 longrun services and explicit dependency ordering. See [Multi-Service Apps](#multi-service-apps-s6-overlay).

5. **Write `moduser.sh`** — Password change script that accepts one argument (the new password) and overwrites the default user's password. See [Password Change Script](#password-change-script-modusersh). For apps with embedded databases and no CLI reset command, see [Embedding Databases → moduser.sh](#modusersh-for-embedded-databases).

6. **Write `entrypoint.sh`** — Follow the lifecycle pattern:
   - State detection (check for persisted data via `/etc/app_configured`)
   - Fresh install: start app, configure, stop app
   - API callback
   - `exec gosu 1000:1000 "$@"` (always UID 1000, never another UID)
   - For s6 apps: one-time setup before `/init`, lifecycle in background subshell (with `set +e`), then `exec "$@"`

7. **Test locally** — Build and run the container:
   ```bash
   docker build -t my-app .
   docker run -e USERNAME=admin -e PASSWORD='TestPass123!' \
     -e INSTANCE_ID=test -e SKIP_APPBOX_CALLBACK=1 \
     -p 3001:3001 my-app
   ```

8. **Test the three states**:
   - Fresh install: run with empty volume
   - Upgrade: stop, rebuild image, start with same volume
   - Restart: stop and start without rebuilding

9. **Run the test suite** — Complete all applicable tests in `TESTING.md` and confirm they pass.

10. **Submit** — Push your image to the Appbox private registry (`repo.cylo.io`) and submit a support ticket for review. See [Submitting Your App](#submitting-your-app) below.

---

## Submitting Your App

Once your app is tested and ready, submit it for review by opening a ticket at:

**https://billing.appbox.co/submitticket.php?step=2&deptid=1**

Use the following template for your submission:

```
Subject: App Submission: <App Name>

App Name: <display name as it should appear in the store>
Publisher: <developer or organization name>
Repository: <URL to your Git repo containing appbox.yml, Dockerfile, entrypoint.sh, icon.png>
Docker Image: <image name on repo.cylo.io, e.g. repo.cylo.io/your-org/your-app>
Version: <version string, e.g. 1.0.0>
Docker Tag: <tag to pull, e.g. latest, 1, 1.0.0>

Short Description:
<One-line description for store cards>

Categories:
<Comma-separated list, e.g. Communication, Media>

Notes:
<Any additional context for the reviewer — special requirements,
capabilities needed (cap_add), resource recommendations, etc.>
```

The review team will verify your `appbox.yml`, test the container, and enable the app in the store.
