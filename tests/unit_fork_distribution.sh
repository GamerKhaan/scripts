#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

panel="$ROOT/pasarguard.sh"
node="$ROOT/pg-node.sh"

grep -q 'DISTRIBUTION_SCRIPTS_REPO="GamerKhaan/scripts"' "$panel" || fail "panel scripts repo is not fork-owned"
grep -q 'DISTRIBUTION_PANEL_REPO="GamerKhaan/panel"' "$panel" || fail "panel release repo is not fork-owned"
grep -q 'DISTRIBUTION_PANEL_IMAGE="ghcr.io/gamerkhaan/panel"' "$panel" || fail "panel image is not fork-owned"
grep -q 'DISTRIBUTION_SCRIPTS_REPO="GamerKhaan/scripts"' "$node" || fail "node scripts repo is not fork-owned"
grep -q 'DISTRIBUTION_NODE_REPO="GamerKhaan/node"' "$node" || fail "node release repo is not fork-owned"
grep -q 'DISTRIBUTION_NODE_SERVICE_REPO="GamerKhaan/node-serviced"' "$node" || fail "node-serviced repo is not fork-owned"
grep -q 'DISTRIBUTION_NODE_IMAGE="ghcr.io/gamerkhaan/node"' "$node" || fail "node image is not fork-owned"
grep -Fq "semver_regex=" "$node" || fail "node version parser has no reusable semver contract"
grep -Fq '(-[0-9A-Za-z.-]+)?' "$node" || fail "node version parser does not admit AWG release suffixes"
grep -Fq '"$node_version" =~ $semver_regex' "$node" || fail "node install path does not use the owned semver contract"

for file in "$ROOT"/docker-compose/*.yml; do
  if grep -Eq 'image:[[:space:]]+pasarguard/(panel|node)(:|$)' "$file"; then
    fail "upstream Docker image remains in $file"
  fi
done

for file in "$panel" "$node"; do
  if grep -Eq 'https://(raw\.)?githubusercontent\.com/(PasarGuard|pasarguard)/(panel|node|scripts)|github\.com/(PasarGuard|pasarguard)/scripts/raw|api\.github\.com/repos/(PasarGuard|pasarguard)/(panel|node)/releases' "$file"; then
    fail "operational upstream GitHub URL remains in $file"
  fi
done

while IFS= read -r -d '' file; do
  if grep -Eq 'raw\.githubusercontent\.com/(PasarGuard|pasarguard)/(panel|node)|github\.com/(PasarGuard|pasarguard)/scripts/(raw|releases)|api\.github\.com/repos/(PasarGuard|pasarguard)/(panel|node|node-serviced)/releases|image:[[:space:]]+pasarguard/(panel|node)(:|$)|ghcr\.io/pasarguard/(panel|node)' "$file"; then
    fail "secondary distribution path still references upstream: $file"
  fi
done < <(find "$ROOT/.github/workflows" "$ROOT/iran-sanction" -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.sh' \) -print0)

grep -q 'ghcr.io/gamerkhaan/panel' "$ROOT/docker-compose/pasarguard-timescaledb.yml" || fail "panel compose is not fork-owned"
grep -q 'ghcr.io/gamerkhaan/node' "$ROOT/docker-compose/node.yml" || fail "node compose is not fork-owned"

printf 'PASS: fork distribution references are fully owned\n'
