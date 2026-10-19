# Custom Tables, Buttons, and Typed Operations

This guide is for Appbox app authors who need structured per-installation data
or actions that update a running app.

Use:

- a **Custom Table** for a list of user-managed records, such as repositories,
  accounts, mounts, or access rules;
- a **row action** for an explicit operation on one table row;
- a **Custom Button** for an explicit app-wide operation;
- a **typed operation** to connect a row action or Custom Button to a fixed
  manager program included in the app image.

These features are optional. Ordinary apps with installation fields and a web
interface do not need them.

## Design principles

1. Keep stable IDs stable across compatible app versions. Change labels for
   display changes.
2. Put a fixed manager executable in the image. Never construct shell commands
   from user input.
3. Pass operation input as schema-validated JSON over standard input.
4. Mark passwords, tokens, and private keys as sensitive.
5. Make operations idempotent where practical. A repeated request should
   reconcile the requested state instead of duplicating it.
6. Treat actions as explicit user operations. Adding, editing, or deleting a
   table row does not automatically run a typed operation.
7. Publish the app image immutably. Typed operations require the released image
   to have a verified immutable digest.

## Complete manifest example

The following example manages named remote accounts. Adapt the names and schema
to your app. The manager path must exist in the released image.

```yaml
custom_fields:
  INITIAL_ACCOUNT:
    label: "Initial account name"
    type: alphaNumeric
    width: 6
    default_value: "primary"
    validate:
      - required
      - alphanumeric

  INITIAL_ACCOUNT_PASSWORD:
    label: "Initial account password"
    type: generatedPassword
    width: 6
    sensitive: true
    params:
      generatedPasswordLength: 32
    validate:
      - required

custom_tables:
  - id: accounts
    label: "Accounts"
    description: "Manage accounts available to this app."
    type_of: account
    max_rows: 25
    admin_only: false
    enable_adding: true
    enable_editing: true
    enable_deleting: true
    enable_filters: true

    fields:
      name:
        label: "Name"
        type: alphaNumeric
        width: 6
        required: true
        editable: false
        validate:
          - required
          - alphanumeric

      password:
        label: "Password"
        type: password
        width: 6
        required: true
        sensitive: true
        validate:
          - required

      enabled:
        label: "Enabled"
        type: switch
        width: 6
        default_value: "1"
        required: true

    initial_rows:
      - name: install.INITIAL_ACCOUNT
        password: install.INITIAL_ACCOUNT_PASSWORD
        enabled: "1"

    initial_rows_operation:
      operation: account-reconcile
      input:
        name: row.name
        password: row.password
        enabled: row.enabled

    row_actions:
      - id: apply
        label: "Apply account"
        operation: account-reconcile
        input:
          name: row.name
          password: row.password
          enabled: row.enabled

      - id: remove-from-app
        label: "Remove account from app"
        operation: account-remove
        input:
          name: row.name
        strong_confirmation:
          phrase: "REMOVE ACCOUNT"
          field: confirmation

custom_buttons:
  - id: rotate-service-token
    label: "Rotate service token"
    icon: refresh-cw
    icon_color: primary
    dialog_text: "Existing clients will need the new token."
    admin_only: true
    operation: service-token-rotate

    input_form:
      confirmation:
        label: "Type ROTATE TOKEN to continue"
        type: dynamicText
        width: 12
        validate:
          - required

    input:
      confirmation: payload.confirmation

    strong_confirmation:
      phrase: "ROTATE TOKEN"
      field: confirmation

typed_operations:
  account-reconcile:
    manager_operation: account.reconcile
    executor: container_exec
    executable: /usr/local/bin/cylo-account-manager
    arguments: [typed-json]
    stdin_mode: json
    timeout_seconds: 300
    redact_output: true
    max_stdin_bytes: 65536
    input_schema:
      type: object
      additionalProperties: false
      required: [name, password, enabled]
      properties:
        name:
          type: string
          pattern: "/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/D"
          maxLength: 64
        password:
          type: string
          format: password
          minLength: 1
          maxLength: 8192
        enabled:
          type: string
          enum: ["0", "1"]
    sensitive_input_paths: [password]
    lock_policy:
      scope: instance_resource
      input_paths: [name]
    target_policy:
      type: instance_container
    image_policy:
      mode: installed_app_version

  account-remove:
    manager_operation: account.remove
    executor: container_exec
    executable: /usr/local/bin/cylo-account-manager
    arguments: [typed-json]
    stdin_mode: json
    timeout_seconds: 300
    redact_output: true
    max_stdin_bytes: 65536
    input_schema:
      type: object
      additionalProperties: false
      required: [name]
      properties:
        name:
          type: string
          pattern: "/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/D"
          maxLength: 64
    sensitive_input_paths: []
    lock_policy:
      scope: instance_resource
      input_paths: [name]
    target_policy:
      type: instance_container
    image_policy:
      mode: installed_app_version

  service-token-rotate:
    manager_operation: service-token.rotate
    executor: container_exec
    executable: /usr/local/bin/cylo-account-manager
    arguments: [typed-json]
    stdin_mode: json
    timeout_seconds: 300
    redact_output: true
    max_stdin_bytes: 65536
    input_schema:
      type: object
      additionalProperties: false
      required: [confirmation]
      properties:
        confirmation:
          type: string
          enum: ["ROTATE TOKEN"]
    sensitive_input_paths: []
    lock_policy:
      scope: instance_operation
    target_policy:
      type: instance_container
    image_policy:
      mode: installed_app_version
```

## Custom Tables

### Table properties

| Property | Required | Default | Purpose |
| --- | --- | --- | --- |
| `id` | Yes | — | Stable manifest identifier. |
| `label` | No | `id` | User-visible heading. |
| `description` | No | — | User-visible help text. |
| `type_of` | No | `id` | Stable table identity used across app versions. |
| `max_rows` | No | `100` | Maximum records for one installation. |
| `admin_only` | No | `false` | Restrict viewing and management to administrators. |
| `enable_adding` | No | `false` | Allow row creation. |
| `enable_editing` | No | `false` | Allow row editing. |
| `enable_deleting` | No | `false` | Allow normal row deletion. |
| `enable_filters` | No | `true` | Enable table filtering in the UI. |
| `fields` | Yes | — | Non-empty map of stable field IDs. |
| `initial_rows` | No | `[]` | Rows seeded on first installation. |
| `initial_rows_operation` | No | — | Internal typed operation dispatched for each seeded row after platform/container readiness. |
| `row_actions` | No | `[]` | Explicit operations shown for each row. |

Keep both `id` and `type_of` unchanged for compatible upgrades. In particular,
`type_of` connects corresponding table definitions across app versions.

### Fields

Common field properties are:

- `label`, `description`, and `width` for presentation;
- `type` and `params` for the control;
- `default_value`;
- `required` and `validate`;
- `editable: false` for immutable identities;
- `sensitive: true` for credentials.

Use stable field keys. Renaming a field key can prevent existing values from
mapping to the new version.

Custom Table forms currently support the common text, password, number,
selector, and switch controls. Keep validation straightforward and always
repeat security-critical validation inside the manager.

Conditional installation fields are documented in the main
[README](README.md#conditional-custom-fields). Custom Table field conditions
are separate and should not currently be relied on for user-visible behavior or
security decisions.

### Sensitive values

Sensitive values are masked in normal table responses and may be explicitly
revealed only to an authorized user. When an edit form leaves a masked value
unchanged, the existing value is preserved.

`sensitive` controls platform presentation and API handling. Do not assume it
is application-level encryption. Your manager must also avoid logging secrets,
returning them, or placing them in process arguments.

### Initial rows

`initial_rows` is useful when installation fields should become the first table
record. A value such as `install.INITIAL_ACCOUNT` resolves from the named
installation field. Other values are literals.

Initial rows:

- are seeded on first installation only;
- are skipped when the table already contains values;
- never run user-facing `row_actions`;
- can run the internal typed operation declared by `initial_rows_operation`;
- are not automatically added during an upgrade.

Use `initial_rows_operation` when the running app must create each seeded
resource before installation completes. It accepts an `operation` stable ID and
an `input` map using the same `row.*`, `instance.*`, `table.*`, and literal
sources as other typed mappings. Request `payload.*` is unavailable because
this lifecycle operation is not initiated by a user request.

The operation is part of install completion: it runs after platform/container
readiness and before installation is marked complete. That readiness permits
dispatch only; it does not prove the specific operation can run or has
succeeded. A failure keeps the installation retryable. Retries reuse the same
execution identity and may follow partial work, so the manager must be
idempotent and convergent. Sensitive row fields may map only to typed-operation
inputs declared sensitive.

## Row actions

Row actions appear beside every table row. They reference a typed operation by
stable ID and map trusted values into its input.

Supported mapping sources are:

| Source | Value |
| --- | --- |
| `row.FIELD_ID` | Value stored in the current row. |
| `payload.FIELD` | Value submitted with the action request. |
| `instance.id` | Current installation ID. |
| `table.id` | Current table ID. |
| Any other string | Literal string. |

Use `strong_confirmation` for destructive actions. The phrase comparison is
exact and case-sensitive. Confirmation expresses user intent; the manager must
still validate the resource name and operation safely.

Row actions are explicit. `enable_adding`, `enable_editing`, and
`enable_deleting` only control row storage. They do not invoke the manager.

## Custom Buttons

Custom Buttons appear with the installed app's actions. They are suitable for
app-wide operations that are not tied to one table row.

`input_form` defines fields shown in the confirmation dialog. Map submitted
values with `payload.FIELD`. Other mapping strings are literals.

Use familiar field types such as:

- `dynamicText` and `textArea`;
- `password`, `complexPassword`, and `passwordAlphaNumeric`;
- `number`, `email`, and `date`;
- `selector` and `switch`.

Set `admin_only: true` when only administrators should see and execute the
button. Authorization is enforced by the platform; the manager must still
validate all input.

Use `visibility_conditions` to show and authorize a button only when
installation fields match. All conditions must match:

```yaml
visibility_conditions:
  - field: FEATURE_ENABLED
    operator: equals
    value: "1"
  - field: AUTH_MODE
    operator: equals
    value: key
```

Supported operators are `equals`, `not_equals`, `in`, and `not_in`. Conditions
are enforced by the API as well as the frontend; hiding a button is not an
authorization boundary. `in` and `not_in` require `value` to be a YAML list:

```yaml
visibility_conditions:
  - field: AUTH_MODE
    operator: in
    value: [key, certificate]
```

Referenced fields must be non-sensitive installation fields declared by the
same app. The importer rejects unknown and sensitive field references. A
missing field never satisfies a condition, including `not_equals` and `not_in`;
this fail-closed behavior prevents a removed or unavailable field from exposing
an action.

Buttons without `visibility_conditions` remain visible and executable subject
to their normal authorization. For matching buttons, the API emits normalized
metadata as `visibilityConditions`. The frontend uses it for presentation, and
the API reevaluates the persisted conditions immediately before execution.
Never treat frontend visibility as authorization.

Every Custom Button opens a confirmation dialog. `strong_confirmation` adds an
exact phrase requirement for consequential operations.

Do not rely on post-submit navigation or manager output being displayed. Typed
operations report success or failure; they do not return command output to the
browser.

## Typed operations

A typed operation is a reviewed contract, not an arbitrary command launcher.
The app author controls:

- a stable operation ID;
- a fixed manager operation name;
- a fixed absolute executable path;
- fixed arguments;
- input schema and sensitive paths;
- timeout and lock scope.

Only `container_exec` is currently supported. Use `stdin_mode: json` for
structured input and set `additionalProperties: false` so unexpected fields are
rejected.

The manager must be included in the same immutable app image as the app version
that declares it. The release process must publish and record an immutable
image digest; a mutable tag alone is insufficient.

### Readiness and completion

Platform/container readiness only permits dispatch. A Docker `HEALTHCHECK` is
not required, and a healthy container is not proof that a typed operation is
ready or successful.

Each manager must perform a bounded, operation-specific readiness check, such
as waiting for the exact API, database, socket, or resource that operation
needs. After acting, it must verify authoritative postconditions rather than
assuming a command exit or accepted request means success. It must return
non-zero if readiness, execution, or postcondition verification cannot be
established within its bound.

### Manager input

For `arguments: [typed-json]`, the manager receives one JSON document on
standard input. The example below shows the fields a manager normally needs;
the `definition` object also contains the complete approved operation
definition.

```json
{
  "version": 1,
  "definition": {
    "id": "account-reconcile",
    "manager_operation": "account.reconcile"
  },
  "input": {
    "name": "primary",
    "password": "secret",
    "enabled": "1"
  }
}
```

The manager should:

1. require the expected protocol version;
2. switch only on the fixed `definition.manager_operation`;
3. reject unknown input fields and invalid types;
4. validate identifiers, paths, bounds, and containment again;
5. use direct process arguments or native APIs, never interpolated shell text;
6. serialize conflicting work when needed;
7. perform a bounded operation-specific readiness check;
8. verify authoritative postconditions;
9. return exit code `0` only after verified success and non-zero otherwise;
10. avoid writing sensitive data to stdout or stderr.

Operations do not return manager output to the UI. Put user-facing status in
the app itself or expose it through normal Custom Table data.

### Lock scopes

- `instance_operation` serializes the operation for one app installation.
- `instance_resource` serializes work for the values selected by
  `input_paths`, such as one account name.

Choose resource locks when unrelated records can safely run independently.
Never include a password or token in `input_paths`.

## Versioning and upgrades

- Publish a new version-scoped definition when the manager contract changes.
- Preserve table `type_of`, table IDs, field IDs, button IDs, and operation IDs
  for compatible changes.
- Do not remove or rename fields casually. Existing values must remain
  meaningful in the new version.
- New `initial_rows` are not seeded during an upgrade.
- Typed operations are available only when declared for the installed app
  version.
- Test upgrades using existing rows and credentials, not only a clean install.

If a field changes meaning or format, implement and test a deliberate migration
rather than reusing its old stable ID for incompatible data.

## Testing checklist

- Import rejects malformed IDs, schemas, mappings, and duplicate definitions.
- Initial rows resolve installation fields and are not duplicated.
- Table row limits and add/edit/delete flags are enforced.
- Non-editable identity fields cannot be changed.
- Non-admin users cannot access administrator-only tables or buttons.
- Sensitive values are masked, reveal requires authorization, and an unchanged
  masked value survives editing.
- Row actions map the intended row and payload values.
- Confirmation phrases must match exactly.
- The manager rejects malformed JSON, unknown operations, unknown fields,
  invalid identifiers, and oversized values.
- Secrets do not appear in logs, process arguments, output, or error messages.
- Managers bound operation-specific readiness checks and fail when the required
  dependency does not become ready.
- Success requires verified authoritative postconditions, not container health
  or command dispatch alone.
- Repeating an operation reconciles state safely.
- Retrying `initial_rows_operation` after partial work converges to the intended
  state before installation completes.
- Conflicting operations are serialized while unrelated resources can proceed.
- Timeouts and non-zero manager exits are handled as failures.
- Upgrade tests preserve table rows and use definitions from the new version.
- The released image is immutable and contains the exact manager executable
  declared by the manifest.

