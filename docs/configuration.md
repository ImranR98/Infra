# Configuration and secrets

The repo is self-contained except for `config/`, which is gitignored and holds every
real value.

## Layout

```text
targets/<t>/config_template/     committed templates + comments
config/<t>/                      gitignored, filled values
config/VARS.env                  gitignored, local Renovate credentials
targets/<t>/compose/.env         generated machine facts (gitignored)
```

`scripts/init-config.sh <target> [--detect]` copies the template tree without
overwriting existing files. On `srv0`, `--detect` sets `MY_UID`; accelerator/HA
hardware is fixed in the charts.

## Per-target config

| Target | Files | Consumed by |
|---|---|---|
| `srv0` | `values.yaml`, `compose.env`, `public-exposure/`, `remote-access/` | both Helm releases; public-exposure Compose sidecar; preboot |
| `vps0` | `compose.env`, `authelia/`, `public-exposure/`, `d4ta-agent/agent.json` | Compose; rendered Authelia config; vps0 apps |
| `bigpc` | `compose.env`, `d4ta-agent/agent.json` | Compose |
| `pc`, `rpi` | none | machine-fact `.env` only |

`srv0`'s `values.yaml` is passed to both `srv0-base` and `srv0-apps`
(`-f targets/.../values.yaml -f config/srv0/values.yaml`). `compose.env` is passed to
the srv0 Compose sidecar with `--env-file`.

## Machine facts

`scripts/prereqs.sh` / `scripts/common.sh` write `targets/<t>/compose/.env` (mode
0600) with:

- `MY_UID`, `DOCKER_GID`, `MY_USERNAME`
- `INFRA_STATE_DIR`, `STATE_ROOT`, `COMPOSE_STATE_DIR`, `K3S_STATE_DIR`

Compose always needs this file. Passing any `--env-file` disables Compose's automatic
`.env` discovery, so pass it explicitly. `COMPOSE_PROFILES` also lives here.

## VARS.env

`config/VARS.env` is only for local Renovate runs (`scripts/renovate.sh`): GitHub
token and Docker Hub credentials. The in-cluster CronJob uses the matching values in
`config/srv0/values.yaml`. It is not used by deploy commands.

## Secret rules

- `config/`, `targets/*/compose/compose.private.yaml`, and
  `targets/*/compose/.env` are gitignored.
- No encryption step: values are final YAML/dotenv. Use block scalars for multiline
  PEM/JWKS values.
- Keep secrets out of chart templates and command lines. The validator prints key
  names, never values.
- The public-exposure keys and configs are real files under
  `config/<t>/public-exposure/`; never commit them.

## Validation

`bash scripts/validate.sh <target>` checks:

- every template has a filled counterpart with no placeholders;
- key completeness for `values.yaml` and `compose.env`;
- Helm lint/render, `<no value>` rejection, chart repo allowlist;
- Gateway certificate refs, route/SAN drift, rendered PV paths;
- image pinning and the resource-tier rule;
- on the target machine: machine-fact `.env`, runtime state tree, and cluster access.

Run it before every deploy. `scripts/check-images.sh` is also run standalone in CI.

## Adding a target

Create `targets/<name>/` with a `compose/` directory and, if it has secrets, a
`config_template/`. Add the machine to the target table in `docs/README.md` and
`docs/architecture.md`, run `init-config.sh <name>`, fill `config/<name>/`, then run
`validate.sh <name>`.
