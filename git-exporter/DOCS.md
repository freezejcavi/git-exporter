# Configuration

```yaml
repository:
  url: <path to your repository>
  username: user
  password: pass
  pull_before_push: true
  commit_message: 'Home Assistant Git Exporter'
  branch_name: 'main'
export:
  lovelace: true
  addons: true
  esphome: true
  node_red: true
include: []
check:
  enabled: true
  check_for_secrets: true
  check_for_ips: true
exclude:
  - '*.db'
  - '*.log'
  - __pycache__
  - deps/
  - known_devices.yaml
  - tts/
  - '*.db-shm'
  - '*.db-wal'
  - '*.gz'
secrets: []
allowed_secrets: []
dry_run: false
```

### `repository.url`

Any https url to your git repository. (For now _no_ SSH)

### `repository.email` (Optional)

The email address the commits author is using.

### `repository.username`

Your username for https authentication.

### `repository.password`

Your password or [__access token__](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) for your repository.

### `repository.pull_before_push`

Should the repository be pulled first and commit the new state on top?

### `repository.commit_message`

The commit message for the next commit.

### `repository.branch_name`

The working branch for the repository.

### `repository.ssl_verification` (Optional, default: true)

Use this to disable the ssl verification. Can be used for self-signed certificates. __Use this only when you know what you are doing__

### `export.lovelace`

Enable / Disable the export for the lovelace config.

### `export.addons`

Enable / Disable export of installed Home Assistant App configuration.

For each installed App, the exporter reads the Supervisor App info endpoint and writes a sanitized file to:

```text
addons/<app-slug>.yaml
```

The exported file contains useful metadata and the App `options` shown in the Home Assistant App configuration UI. Password-schema fields and common credential/token/secret fields are replaced with `<redacted>` before they are written to the Git repository.

`addons/repositories.yaml` is exported as before.

### `export.esphome`

Enable / Disable the export for the esphome config.

### `export.node_red`

Enable / Disable the export for the Node-RED flows.
Secure your credentials with [node-red-contrib-credentials](https://flows.nodered.org/node/node-red-contrib-credentials).

### `include`

Optional list of additional files or directories to export. This is useful for data that is intentionally excluded from the normal Home Assistant config export, or for selected App configuration under `/addon_configs`.

Allowed source roots are:

* `/config`
* `/addon_configs`

Shell glob patterns are supported. Paths must be absolute and start with one of the allowed roots.

Included files keep the same topology as the Home Assistant filesystem:

```text
/config/.storage/core.entity_registry
→ config/.storage/core.entity_registry

/addon_configs/a0d7b954_nodered/flows.json
→ addon_configs/a0d7b954_nodered/flows.json
```

Example:

```yaml
include:
  - /config/.storage/core.entity_registry
  - /config/.storage/core.device_registry
  - /config/.storage/core.area_registry
  - /config/.storage/core.floor_registry
  - /config/.storage/core.label_registry
  - /addon_configs/*_nodered/flows.json
  - /addon_configs/*_nodered/settings.js
```

A useful selective Codex example is:

```yaml
exclude:
  - codex_tasks/

include:
  - /config/codex_tasks/*/task.json
```

This keeps the large Codex task directory excluded from the normal config mirror while explicitly restoring only each `task.json` into:

```text
config/codex_tasks/<task-id>/task.json
```

#### Include / exclude precedence

Rules are applied in this order:

1. hard security blocks
2. normal export with user `exclude` rules
3. explicit `include` rules

Therefore an explicit `include` overrides a normal user `exclude`. Hard security blocks always win and cannot be overridden.

For safety, known sensitive files are always blocked from `include`, including `secrets.yaml`, Node-RED `flows_cred.json`, Home Assistant authentication data, `core.config_entries`, application credentials, private keys and similar credential files. Parent-directory traversal and source paths outside the two allowed roots are rejected.

All selectively included files are added to the secret scan when checks are enabled, including files without a `.yaml` or `.json` extension such as Home Assistant registries.

> **Security note:** `include` is intentionally an advanced, opt-in feature. Prefer explicit reviewed files over broad directory patterns, especially when exporting to a public repository. App configuration directories may contain credentials even when the file name does not make that obvious.

### `check.enabled`

Enable / Disable the checks in the exported files.

### `check.check_for_secrets`

Add your secret values to the check.

### `check.check_for_ips`

Add pattern for ip and mac addresses to the search.

### `exclude`

The files / folders which should be excluded from the normal Home Assistant config export.

Following folders and files are excluded from the sync per default:

* `secrets.yaml` (secrets are cleared)
* `.cloud`
* `.storage`

An explicit `include` may restore a normally excluded file, unless that file is covered by a hard security block.

### `secrets`

Additional secrets which will be checked for.

### `allowed_secrets`

Additional allowed secrets which will not make the secret check fail.

### `dry_run`

Only show the changes and don't commit or push.

## Known limitations

`check_for_secrets` uses a git plugin that does pattern matching using regexes.
A limitation of this plugin is that using brackets (like `[`, `]`, `{`, `}` `(` and `)`) in secrets can result in unexpected behaviour and crashes.

If the app fails during secrets checking with errors originating from grep (I.E. `grep: Unmatched [, [^, [:, [., or [=`),
change the passwords that contain brackets or set `check_for_secrets` to `false`.
