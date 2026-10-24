#!/usr/bin/env bash
# Read-only survey for Renovate/CI onboarding.
#
#   scripts/survey-repo.sh /path/to/app
#
# Prints repository shape, manifests, image references, build/test commands,
# system installs, CI files, and test files. It never writes to the repo and
# skips common secret/runtime files. It is a starting point, not a complete
# dependency audit: read the flagged files yourself.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <repo-path>" >&2
    exit 2
fi

repo="$1"
if [ ! -d "$repo" ]; then
    echo "Error: not a directory: $repo" >&2
    exit 1
fi
repo="$(cd "$repo" && pwd)"
if [ ! -d "$repo/.git" ]; then
    echo "Error: not a git repository: $repo" >&2
    exit 1
fi
cd "$repo"

grep_excludes=(
    --exclude-dir=.git
    --exclude-dir=node_modules
    --exclude-dir=vendor
    --exclude-dir=dist
    --exclude-dir=build
    --exclude-dir=coverage
    --exclude-dir=.next
    --exclude-dir=.venv
    --exclude-dir=venv
    --exclude-dir=target
    --exclude-dir=__pycache__
    --exclude='.env'
    --exclude='.env.*'
    --exclude='secrets*'
    --exclude='*.pem'
    --exclude='*.key'
)

grep_src() {
    grep -rIn -I "${grep_excludes[@]}" "$@" . || true
}

echo "== Renovate/CI survey (read-only) =="
echo "path: $repo"
echo

echo "== git =="
git remote -v || true
printf 'current branch: '
git branch --show-current || true
printf 'default branch: '
git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo "(unknown)"
echo "worktree:"
git status --short | sed -n '1,25p'
echo

echo "== top level =="
find . -maxdepth 1 -mindepth 1 -not -name .git -print \
    | sed 's|^\./||' | sort
echo

echo "== manifests and version files =="
find . -maxdepth 4 \( \
    -iname 'Dockerfile*' -o -iname 'Containerfile*' -o \
    -iname '*compose*.yml' -o -iname '*compose*.yaml' -o \
    -iname 'package.json' -o -iname 'package-lock.json' -o \
    -iname 'pnpm-lock.yaml' -o -iname 'yarn.lock' -o -iname 'bun.lockb' -o \
    -iname 'requirements*.txt' -o -iname 'pyproject.toml' -o \
    -iname 'Pipfile' -o -iname 'poetry.lock' -o \
    -iname 'go.mod' -o -iname 'go.sum' -o \
    -iname 'Cargo.toml' -o -iname 'Cargo.lock' -o \
    -iname 'pom.xml' -o -iname 'build.gradle*' -o -iname 'settings.gradle*' -o \
    -iname 'Makefile' -o -iname '.nvmrc' -o -iname '.python-version' -o \
    -iname '.tool-versions' -o -iname 'mise.toml' -o \
    -iname '.pre-commit-config.yaml' \
\) -not -path '*/.git/*' -not -path '*/node_modules/*' \
  -not -path '*/vendor/*' -not -path '*/dist/*' -not -path '*/build/*' \
  -not -path '*/target/*' \
    | sort | sed -n '1,140p'
echo

echo "== CI files =="
find .github -maxdepth 3 -type f 2>/dev/null | sort || true
echo

echo "== test files =="
find . -maxdepth 4 \( -iname '*test*' -o -iname '*spec*' \) \
    -not -path '*/.git/*' -not -path '*/node_modules/*' \
    -not -path '*/vendor/*' -not -path '*/dist/*' -not -path '*/build/*' \
    -not -path '*/target/*' -not -path '*/coverage/*' \
    | sort | sed -n '1,80p'
echo

echo "== package scripts =="
if [ -f package.json ]; then
    grep -n -A 40 '"scripts"' package.json | sed -n '1,45p' || true
fi
if [ -f pyproject.toml ]; then
    grep -nE '\[tool\.(pytest|poetry|hatch|setuptools)|pytest|scripts' pyproject.toml \
        | sed -n '1,40p' || true
fi
if [ -f Makefile ]; then
    grep -nE '^[A-Za-z0-9_.-]+:|test|build|install' Makefile \
        | sed -n '1,40p' || true
fi
echo

echo "== Dockerfile base images =="
find . -maxdepth 4 \( -iname 'Dockerfile*' -o -iname 'Containerfile*' \) \
    -not -path '*/.git/*' -not -path '*/node_modules/*' \
    -not -path '*/vendor/*' -not -path '*/dist/*' -not -path '*/build/*' \
    -print0 \
    | xargs -0 -r grep -nH '^[[:space:]]*FROM' || true
echo

echo "== image references =="
grep_src -E 'image:[[:space:]]|ghcr\.io/|docker\.io/|docker\.com/' \
    | sed -n '1,120p'
echo

echo "== registry/build commands and version variables =="
grep_src -E 'docker[[:space:]]+(build|push|tag)|podman[[:space:]]+(build|push|tag)|hub\.docker\.com|ghcr\.io|LATEST_TAG|VERSION=' \
    | sed -n '1,120p'
echo

echo "== system installs and build-time downloads =="
grep_src -E 'apt(-get)?[[:space:]]+install|apk[[:space:]]+add|dnf[[:space:]]+install|yum[[:space:]]+install|curl[[:space:]].*https?://|wget[[:space:]].*https?://|get\.docker\.com' \
    | sed -n '1,100p'
echo

echo "== done =="
echo "Review the flagged files and the checklist; this output is intentionally"
echo "a starting point, not a complete audit."
