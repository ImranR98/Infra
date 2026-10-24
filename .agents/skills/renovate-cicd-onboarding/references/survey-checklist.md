# Survey checklist

Read-only inventory. Use it as a prompt, not a questionnaire: not every item
applies, and the app's own conventions win. The goal is to find every dependency
surface, every test signal, and every place the image is referenced before
changing anything.

## Repository

- Remote, default branch (`main`, `master`, other), current branch, WIP status.
- Visibility (public/private), archived/frozen status, license.
- Top-level layout and entry points.
- Existing CI, release workflows, registry workflows, and pre-commit hooks.
- Existing Renovate/Dependabot config, branch protection, auto-merge settings.

## App shape

Classify before choosing a template:

- static site / SSG,
- SSR or full-stack web app,
- HTTP API/service,
- worker/daemon,
- CLI,
- batch/media pipeline,
- shell service,
- thin wrapper around an upstream binary,
- desktop/GUI,
- library/package,
- monorepo or multi-image repo.

Record the ports, health endpoints, config/env inputs, persistent directories,
and external services. These determine the test and image-smoke shape.

## Runtime and packages

- Runtime declarations: `.nvmrc`, `engines`, `packageManager`, `.python-version`,
  `.tool-versions`, `mise.toml`, `go.mod`, `rust-toolchain.toml`, Dockerfile
  base tag, CI setup version.
- Package manifests and lockfiles at every level, including nested client,
  server, scripts, or desktop subprojects.
- Package-manager scripts: install, build, test, start, lint, typecheck.
- Native modules (e.g. database drivers) and their build prerequisites.
- Python `requirements*.txt` / `pyproject.toml` / `Pipfile`, Go modules, Cargo,
  Maven/Gradle, etc., anywhere in the repo.
- Pre-commit hooks, asdf/mise tools, generated version files.

## Images and build

- Every Dockerfile/Containerfile. Which one is the production image? Auxiliary
  images (desktop UI, test tools, dev containers) are not automatically
  published.
- Base images, tags, digests, `ARG` versions, build stages.
- `npm install` / `npm i` vs `npm ci`; lockfiles; `--omit=dev`/prune; build
  dependencies in the runtime stage.
- Build-time downloads (`curl`/`wget`/GitHub releases/`get.docker.com`), and
  whether versions are pinned, scraped as "latest", or passed as build args.
- System package installs (`apt`, `apk`, PPA), unpinned tools, kernel/OS
  assumptions, Docker socket/Kubernetes mounts.
- Image tags actually used by deployments: `latest`, a version tag, a
  commit/tag scheme, or a per-environment tag.
- Architecture (`linux/amd64`, arm64, multi-arch) and whether native binaries
  are downloaded for a specific architecture.

## Dependency automation surfaces

| Surface | Usually handled by | Watch for |
|---|---|---|
| npm/pnpm/yarn | npm manager | multiple lockfiles, workspaces, nested projects |
| Python | pip/poetry/pip-compile | unpinned requirements, subprojects |
| Go/Rust/Java | gomod/cargo/gradle/maven | toolchain versions |
| Docker bases | dockerfile/docker | floating tags, no digest |
| Build args/downloads | custom regex | "latest" scraping, version strings in scripts |
| GitHub Actions | github-actions | token needs `workflow` scope |
| Pre-commit | pre-commit | hook revisions |
| Helm/K8s/Compose | helm/kubernetes/docker-compose | values content, tag+digest forms |
| Runtime versions | nvm/asdf/mise/engines | drift between files and image |

## Tests

- Exact test command, framework, and config.
- Do the tests run? How long? Any skipped tests, conditional skips, or
  environment prerequisites?
- Is the `test` script real, or a placeholder that exits non-zero?
- Do tests require a browser, database, Docker, ffmpeg/exiftool, network, or
  credentials?
- What is untested: startup, HTTP routes, auth, migrations, file processing,
  scheduler, notifications, UI flows, backup/restore?
- Can a production image run a smoke test (HTTP, CLI, fixture) without secrets?
- Are tests already run in CI, or only locally?

## Registry and deployment

- Current registry and namespace.
- Actual image name(s); do not infer them from the repository name.
- Every reference: Dockerfiles, comments, READMEs, package scripts, Compose,
  Helm, K8s templates, deployment repo, docs.
- Tag scheme used by each deployment.
- Whether the repo is public (GHCR package public) or private (package private;
  deployment auth or make it public).
- Multiple deployment references for the same image (e.g. Compose + K8s).
- Whether the image is built in the deployment repo, has no repo, is archived,
  or is frozen/disabled.

## Risk flags

- Archived/frozen repo with a live image.
- Production image built from a deployment repo, not an app repo.
- No image repo or no Dockerfile.
- Multiple plausible production images.
- System tools/base OS that cannot move to a slim/Node image.
- Build-time "latest" downloads.
- Non-`latest` deployment tag.
- Private repo/image.
- Tests absent, flaky, or impossible without external services.
- Runtime major bump with native modules.
- Existing CI or registry behavior that must be preserved.
- Secrets or runtime state in the repo (stop; do not print).

## Output

Report a short table:

```text
App/repo:
Default branch:
Shape:
Production image(s) / tag(s):
Registry / visibility:
Runtime(s):
Package roots / lockfiles:
Dependency surfaces not covered by standard managers:
Test command / state:
Deployment refs:
Risk flags:
Proposed default plan:
Deviations to ask about:
```
