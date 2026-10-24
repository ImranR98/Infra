# Docker Hub → GHCR

GHCR is the default target for this pipeline because it integrates with
GitHub Actions and Renovate. The migration is more than changing one push
command: the image can be referenced in several places, and the deployment may
pin a tag that CI does not currently publish.

## Visibility rule

- **Public app repo** → GHCR package is public by default. No pull secret or
  registry auth is needed. Do not add unnecessary registry-auth work.
- **Private app repo** → GHCR package is private. The deployment needs registry
  auth or the package must be made public; ask and document. Never commit
  credentials.

This is the only significant registry-access difference. Public repos are the
common case in this environment.

## Discover the actual images

Do not infer image names from repository names. Names can be abbreviated,
renamed, or absent from the repo entirely.

Sources, in order:

1. Deployment refs (Compose, Kubernetes/Helm, deployment docs) — what is
   actually running.
2. Docker Hub namespace listing — public images and descriptions.
3. Dockerfile/build-script comments and README commands.
4. Package scripts (`dockerize`, `build`, release scripts).
5. CI workflows.

Record a mapping:

```text
repo:
current registry/namespace:
image name(s):
tags used by each deployment:
public/private repo:
production Dockerfile(s):
```

If no image can be confirmed, stop and ask.

## Find every reference

Search the app repo and the deployment repo for the old registry, namespace, and
image names. Common places:

- `Dockerfile`/`Containerfile` comments and labels;
- `README`/docs run commands;
- `package.json` scripts (`dockerize`, `build`, release);
- `build.sh`/`Makefile`/wrapper scripts;
- Compose files;
- Kubernetes/Helm templates and values;
- CI login/push steps;
- deployment docs/runbooks.

Update all of them. A repo can be clean while the deployment still pulls the old
image.

## Preserve names and tags

- Preserve the image name unless a rename was explicitly approved.
- Read the deployment's tag. Publish that tag; do not only publish `latest`.
- Wrapper images may use `latest` plus an upstream version tag. Preserve the
  version tag or the deployment cannot update.
- Some deployments pin a release tag rather than `latest`; publish it.
- Do not move an immutable tag to a new build. Ask if the scheme is unusual.

## Update the build/publish path

- Add GHCR login with `GITHUB_TOKEN` and `packages: write`.
- Remove Docker Hub login and push steps.
- Remove or rewrite Docker Hub-only scripts (`dockerize`, Docker Hub automated
  build notes).
- Build/push `ghcr.io/<owner>/<image>`; use `github.repository_owner`, lowercased
  for Docker references.
- Add `org.opencontainers.image.source`/`revision` labels.
- If the app previously relied on Docker Hub automated builds, GitHub Actions is
  now the builder.
- If the image is built in the deployment repo, do not migrate it here; use that
  repo's build process.

## Build-time upstream downloads

Some images download upstream binaries at build time, sometimes by scraping the
latest GitHub release. That is not reproducible and Renovate cannot track it.

- Replace `curl/wget` “latest” lookups with pinned `ARG`/version variables.
- Add a custom Renovate manager for the pin (see `renovate-config.md`).
- Preserve the output/tag scheme used by the deployment.
- If a wrapper has no meaningful tests, the version bump gate is build + binary
  version/help + config validation; keep majors manual unless stronger coverage
  exists.
- If a system tool must be installed from a PPA/vendor repo, keep the base OS and
  pin it; do not force a slim image that lacks the tool.

## Update the deployment

- Replace old image refs with the GHCR ref in every deployment file.
- For public repos, no pull auth is needed.
- For private repos, add the deployment's registry auth/imagePullSecret or make
  the package public; ask.
- If the deployment also references the old tag, update it to the tag CI will
  publish.
- Verify there are no remaining old refs in the deployment repo.
- Do not update frozen/disabled images as part of another app's migration.

## Deprecate Docker Hub

- Stop Docker Hub automated builds/webhooks.
- Add a deprecation note/README description pointing at GHCR.
- Do not delete the old repository without consent; it may still be pinned by an
  old deployment.
- After the migration is verified, ask whether to remove old tags/repos.

## Stale images from a prior migration

If the app already moved to GHCR but Docker Hub still has old tags:

- do not re-onboard or create a duplicate pipeline;
- treat the Docker Hub repo as deprecated;
- update any lingering deployment/docs refs;
- leave deletion to the user.

## Cases that are not migrations

- **Archived/frozen app:** ask whether it is still used. Do not create a new
  pipeline just because an old image exists.
- **Image built in the deployment repo:** use the deployment repo's build and
  Renovate process.
- **No app repo / no matching GitHub repo:** cannot migrate app-side; ask if the
  image is still used, and update only the deployment/docs if appropriate.
- **User wants to stay on Docker Hub:** acceptable if Renovate can track it;
  document the exception and keep digest pinning.

## Verification

- `docker pull ghcr.io/<owner>/<image>:<tag>` (or `podman`) succeeds.
- For public repos, the pull works anonymously.
- For private repos, the deployment's auth works and was not committed.
- The digest/tag in the deployment matches the new publish.
- `git grep` in the app and deployment repos finds no unintended old refs.
- The app's docs/examples no longer instruct Docker Hub pushes unless they are
  intentionally historical.
- Renovate sees the new image and opens/updates digest PRs in the deployment
  repo.

## Common pitfalls

- Changing CI but not the deployment refs.
- Changing the image name but not the deployment/README/scripts.
- Publishing only `latest` while the deployment pins a version tag.
- Leaving a `dockerize` script that still pushes to Docker Hub.
- Forgetting a Dockerfile comment or docs snippet.
- Assuming a public GHCR package for a private repo.
- Deleting the Docker Hub repo before all consumers moved.
- Re-onboarding a stale Docker Hub image after a completed GHCR migration.
