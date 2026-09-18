#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="pg-node-adoption-test"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR/certs"

curl() { echo ''; return 0; }
export -f curl
export PG_NODE_SOURCE_ONLY="true"
source "$ROOT_DIR/pg-node.sh"

PASS=0
FAIL=0
pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }
assert_eq() { local a="$1" e="$2" l="$3"; if [ "$a" = "$e" ]; then pass "$l"; else fail "$l (expected=$e got=$a)"; fi; }
assert_true() { local l="$1"; shift; if "$@"; then pass "$l"; else fail "$l"; fi; }

echo "=== unit_fork_node_adoption.sh ==="

if declare -F owned_node_image_for_version >/dev/null 2>&1; then
  assert_eq "$(owned_node_image_for_version latest)" "ghcr.io/gamerkhaan/node:latest" "latest resolves owned Node image"
  assert_eq "$(owned_node_image_for_version v1.0.0)" "ghcr.io/gamerkhaan/node:v1.0.0" "v1 distribution release resolves owned Node image"
else
  fail "owned_node_image_for_version exists"
fi

if declare -F detect_existing_node_distribution >/dev/null 2>&1; then
  C="$WORK_DIR/compose.yml"
  printf '%s\n' 'services:' '  node:' '    image: pasarguard/node:latest' >"$C"
  assert_eq "$(detect_existing_node_distribution "$C")" "upstream" "detect Docker Hub upstream Node"
  printf '%s\n' 'services:' '  node:' '    image: ghcr.io/pasarguard/node:v0.5.4' >"$C"
  assert_eq "$(detect_existing_node_distribution "$C")" "upstream" "detect GHCR upstream Node"
  printf '%s\n' 'services:' '  node:' '    image: ghcr.io/gamerkhaan/node:latest' >"$C"
  assert_eq "$(detect_existing_node_distribution "$C")" "owned" "detect owned Node image"
  printf '%s\n' 'services:' '  node:' '    image: example.invalid/node:latest' >"$C"
  assert_eq "$(detect_existing_node_distribution "$C")" "unknown" "unknown Node image fails closed"
else
  fail "detect_existing_node_distribution exists"
fi

if declare -F adopt_existing_node >/dev/null 2>&1; then
  APP_DIR="$WORK_DIR/migrate-app"; DATA_DIR="$WORK_DIR/migrate-data"
  mkdir -p "$APP_DIR" "$DATA_DIR/certs"
  COMPOSE_FILE="$APP_DIR/docker-compose.yml"; ENV_FILE="$APP_DIR/.env"
  printf '%s\n' 'services:' '  node:' '    image: pasarguard/node:latest' >"$COMPOSE_FILE"
  printf '%s\n' 'API_KEY=11111111-2222-4333-8444-555555555555' 'SERVICE_PORT=16953' 'SERVICE_PROTOCOL=grpc' 'SSL_CERT_FILE=/var/lib/pg-node/certs/ssl_cert.pem' 'SSL_KEY_FILE=/var/lib/pg-node/certs/ssl_key.pem' >"$ENV_FILE"
  printf "cert-fixture\n" >"$DATA_DIR/certs/ssl_cert.pem"
  printf "key-fixture\n" >"$DATA_DIR/certs/ssl_key.pem"
  chmod 600 "$ENV_FILE" "$DATA_DIR/certs/ssl_key.pem"
  ENV_SHA="$(sha256sum "$ENV_FILE" | awk '{print $1}')"
  CERT_SHA="$(sha256sum "$DATA_DIR/certs/ssl_cert.pem" | awk '{print $1}')"
  KEY_SHA="$(sha256sum "$DATA_DIR/certs/ssl_key.pem" | awk '{print $1}')"

  docker() { [ "${1:-}" = "pull" ] && [[ "${2:-}" == ghcr.io/gamerkhaan/node:* ]]; }
  set_owned_node_image() { sed -i "s#image: .*#image: $1#" "$COMPOSE_FILE"; }
  compose_mock() { return 0; }
  wait_for_node_health() { return 0; }
  COMPOSE="compose_mock"

  if adopt_existing_node latest; then pass "stock Node adoption succeeds"; else fail "stock Node adoption succeeds"; fi
  assert_eq "$(sha256sum "$ENV_FILE" | awk '{print $1}')" "$ENV_SHA" "Node .env remains byte-identical"
  assert_eq "$(sha256sum "$DATA_DIR/certs/ssl_cert.pem" | awk '{print $1}')" "$CERT_SHA" "Node cert remains byte-identical"
  assert_eq "$(sha256sum "$DATA_DIR/certs/ssl_key.pem" | awk '{print $1}')" "$KEY_SHA" "Node key remains byte-identical"
  assert_true "Node compose points to owned image" grep -Fq "image: ghcr.io/gamerkhaan/node:latest" "$COMPOSE_FILE"
  assert_true "Node compose migration backup exists" sh -c 'find "$1/migration-backups" -type f -name docker-compose.yml -print -quit | grep -q .' _ "$APP_DIR"
  assert_true "Node env migration backup exists" sh -c 'find "$1/migration-backups" -type f -name .env -print -quit | grep -q .' _ "$APP_DIR"
  assert_true "Node cert migration backup exists" sh -c 'find "$1/migration-backups" -type f -path "*/certs/ssl_cert.pem" -print -quit | grep -q .' _ "$APP_DIR"

  printf '%s\n' 'services:' '  node:' '    image: pasarguard/node:latest' >"$COMPOSE_FILE"
  COMPOSE_SHA="$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
  UP_CALLS=0
  compose_mock() {
    if [[ " $* " == *" up -d node "* ]]; then
      UP_CALLS=$((UP_CALLS + 1))
      [ "$UP_CALLS" -gt 1 ]
      return
    fi
    return 0
  }
  if adopt_existing_node latest; then fail "failed Node activation returns non-zero"; else pass "failed Node activation returns non-zero"; fi
  assert_eq "$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')" "$COMPOSE_SHA" "failed Node activation restores compose"
  assert_eq "$(sha256sum "$ENV_FILE" | awk '{print $1}')" "$ENV_SHA" "failed Node activation preserves .env"
else
  fail "adopt_existing_node exists"
fi

assert_true "Node install dispatches existing installs to adoption" grep -Fq 'adopt_existing_node "$node_version"' "$ROOT_DIR/pg-node.sh"
assert_true "Node install tracks existing installation mode" grep -Fq 'existing_install="true"' "$ROOT_DIR/pg-node.sh"

APP_NAME="custom-existing-node"
DATA_DIR="$WORK_DIR/custom-existing-data"
mkdir -p "$DATA_DIR/certs"
ENV_FILE="$WORK_DIR/custom-existing.env"
printf '%s\n'   'SSL_CERT_FILE=/var/lib/pg-node/certs/ssl_cert.pem'   'SSL_KEY_FILE=/var/lib/pg-node/certs/ssl_key.pem'   'API_KEY=11111111-2222-4333-8444-555555555555' >"$ENV_FILE"
PRE_DISPATCH_SHA="$(sha256sum "$ENV_FILE" | awk '{print $1}')"
install_command() { return 0; }
pg_node_main install
assert_eq "$(sha256sum "$ENV_FILE" | awk '{print $1}')" "$PRE_DISPATCH_SHA" "install dispatch does not rewrite existing SSL paths before adoption backup"

if declare -F resolve_latest_owned_node_release >/dev/null 2>&1; then
  curl() { printf '%s\n' '{"tag_name":"v0.5.4-awg31.9"}'; }
  assert_eq "$(resolve_latest_owned_node_release)" "v0.5.4-awg31.9" "node update resolves latest owned release"
else
  fail "resolve_latest_owned_node_release exists"
fi

UPDATE_DIR="$WORK_DIR/update-node"
mkdir -p "$UPDATE_DIR"
COMPOSE_FILE="$UPDATE_DIR/docker-compose.yml"
printf '%s\n' 'services:' '  node:' '    image: ghcr.io/gamerkhaan/node:v0.5.4-awg31.1' >"$COMPOSE_FILE"
APP_NAME="update-node"
docker() { [ "${1:-}" = "pull" ] && [ "${2:-}" = "ghcr.io/gamerkhaan/node:v0.5.4-awg31.9" ]; }
set_owned_node_image() { sed -i "s#image: .*#image: $1#" "$COMPOSE_FILE"; }
compose_mock() { return 0; }
COMPOSE="compose_mock"
wait_for_node_health() { return 0; }
if update_node; then pass "node update switches to latest owned release"; else fail "node update switches to latest owned release"; fi
assert_true "node update writes latest owned image" grep -Fq 'image: ghcr.io/gamerkhaan/node:v0.5.4-awg31.9' "$COMPOSE_FILE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
