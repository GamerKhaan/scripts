#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="pasarguard-adoption-test"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR"

curl() { echo ''; return 0; }
export -f curl
export PASARGUARD_SOURCE_ONLY="true"
source "$ROOT_DIR/pasarguard.sh"

PASS=0
FAIL=0
pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }
assert_eq() { local a="$1" e="$2" l="$3"; if [ "$a" = "$e" ]; then pass "$l"; else fail "$l (expected=$e got=$a)"; fi; }
assert_true() { local l="$1"; shift; if "$@"; then pass "$l"; else fail "$l"; fi; }

echo "=== unit_fork_adoption.sh ==="

if declare -F owned_panel_image_for_version >/dev/null 2>&1; then
  assert_eq "$(owned_panel_image_for_version latest)" "ghcr.io/gamerkhaan/panel:latest" "latest resolves owned image"
  assert_eq "$(owned_panel_image_for_version v1.0.0)" "ghcr.io/gamerkhaan/panel:v1.0.0" "v1 distribution release resolves owned image"
else
  fail "owned_panel_image_for_version exists"
fi

if declare -F detect_existing_panel_distribution >/dev/null 2>&1; then
  C="$WORK_DIR/compose.yml"
  printf '%s\n' 'services:' '  pasarguard:' '    image: pasarguard/panel:latest' >"$C"
  assert_eq "$(detect_existing_panel_distribution "$C")" "upstream" "detect Docker Hub upstream"
  printf '%s\n' 'services:' '  pasarguard:' '    image: ghcr.io/pasarguard/panel:v5.4.1' >"$C"
  assert_eq "$(detect_existing_panel_distribution "$C")" "upstream" "detect GHCR upstream"
  printf '%s\n' 'services:' '  pasarguard:' '    image: ghcr.io/gamerkhaan/panel:latest' >"$C"
  assert_eq "$(detect_existing_panel_distribution "$C")" "owned" "detect owned image"
  printf '%s\n' 'services:' '  pasarguard:' '    image: example.invalid/panel:latest' >"$C"
  assert_eq "$(detect_existing_panel_distribution "$C")" "unknown" "unknown image fails closed"
else
  fail "detect_existing_panel_distribution exists"
fi

if declare -F confirm_existing_pasarguard_adoption >/dev/null 2>&1; then
  APP_DIR="$WORK_DIR/existing-panel"
  mkdir -p "$APP_DIR"
  if printf 'n\n' | confirm_existing_pasarguard_adoption >/dev/null 2>&1; then
    fail "existing Panel install can be declined"
  else
    pass "existing Panel install can be declined"
  fi
  if printf 'y\n' | confirm_existing_pasarguard_adoption >/dev/null 2>&1; then
    pass "existing Panel install confirmation continues to safe adoption"
  else
    fail "existing Panel install confirmation continues to safe adoption"
  fi
else
  fail "confirm_existing_pasarguard_adoption exists"
fi
assert_true "Panel keeps original existing-install question" grep -Fq 'Do you want to override the previous installation? (y/n)' "$ROOT_DIR/pasarguard.sh"
assert_true "Panel install gates adoption behind confirmation" grep -Fq 'confirm_existing_pasarguard_adoption' "$ROOT_DIR/pasarguard.sh"

if declare -F adopt_existing_pasarguard >/dev/null 2>&1; then
  APP_DIR="$WORK_DIR/migrate-app"; DATA_DIR="$WORK_DIR/migrate-data"
  mkdir -p "$APP_DIR" "$DATA_DIR/certs"
  COMPOSE_FILE="$APP_DIR/docker-compose.yml"; ENV_FILE="$APP_DIR/.env"
  printf '%s\n' 'services:' '  pasarguard:' '    image: pasarguard/panel:latest' >"$COMPOSE_FILE"
  printf '%s\n' 'UVICORN_PORT=5051' 'KEEP_ME=unchanged' >"$ENV_FILE"
  printf 'sqlite-user-node-admin-marker\n' >"$DATA_DIR/db.sqlite3"
  printf 'existing-panel-cert\n' >"$DATA_DIR/certs/fullchain.pem"
  printf 'existing-panel-key\n' >"$DATA_DIR/certs/privkey.pem"
  chmod 600 "$ENV_FILE" "$DATA_DIR/certs/privkey.pem"
  ENV_SHA="$(sha256sum "$ENV_FILE" | awk '{print $1}')"
  DB_SHA="$(sha256sum "$DATA_DIR/db.sqlite3" | awk '{print $1}')"
  CERT_SHA="$(sha256sum "$DATA_DIR/certs/fullchain.pem" | awk '{print $1}')"
  KEY_SHA="$(sha256sum "$DATA_DIR/certs/privkey.pem" | awk '{print $1}')"

  BACKUPS=0
  backup_command() { BACKUPS=$((BACKUPS + 1)); return 0; }
  docker() { [ "${1:-}" = "pull" ] && [[ "${2:-}" == ghcr.io/gamerkhaan/panel:* ]]; }
  set_pasarguard_panel_image() { sed -i "s#image: .*#image: $1#" "$COMPOSE_FILE"; }
  compose_mock() { return 0; }
  wait_for_pasarguard_health() { return 0; }
  COMPOSE="compose_mock"

  if adopt_existing_pasarguard latest; then pass "stock adoption succeeds"; else fail "stock adoption succeeds"; fi
  assert_eq "$BACKUPS" "1" "backup runs before migration"
  assert_eq "$(sha256sum "$ENV_FILE" | awk '{print $1}')" "$ENV_SHA" ".env remains byte-identical"
  assert_eq "$(sha256sum "$DATA_DIR/db.sqlite3" | awk '{print $1}')" "$DB_SHA" "Panel data/DB marker remains byte-identical"
  assert_eq "$(sha256sum "$DATA_DIR/certs/fullchain.pem" | awk '{print $1}')" "$CERT_SHA" "Panel TLS certificate remains byte-identical"
  assert_eq "$(sha256sum "$DATA_DIR/certs/privkey.pem" | awk '{print $1}')" "$KEY_SHA" "Panel TLS private key remains byte-identical"
  assert_true "compose points to owned image" grep -Fq "image: ghcr.io/gamerkhaan/panel:latest" "$COMPOSE_FILE"
  assert_true "compose migration backup exists" sh -c 'find "$1/migration-backups" -type f -name docker-compose.yml -print -quit | grep -q .' _ "$APP_DIR"
  assert_true "env migration backup exists" sh -c 'find "$1/migration-backups" -type f -name .env -print -quit | grep -q .' _ "$APP_DIR"

  printf '%s\n' 'services:' '  pasarguard:' '    image: pasarguard/panel:latest' >"$COMPOSE_FILE"
  COMPOSE_SHA="$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
  UP_CALLS=0
  compose_mock() {
    if [[ " $* " == *" up -d "* ]]; then
      UP_CALLS=$((UP_CALLS + 1))
      [ "$UP_CALLS" -gt 1 ]
      return
    fi
    return 0
  }
  if adopt_existing_pasarguard latest; then fail "failed activation returns non-zero"; else pass "failed activation returns non-zero"; fi
  assert_eq "$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')" "$COMPOSE_SHA" "failed activation restores compose"
  assert_eq "$(sha256sum "$ENV_FILE" | awk '{print $1}')" "$ENV_SHA" "failed activation preserves .env"
  assert_eq "$(sha256sum "$DATA_DIR/db.sqlite3" | awk '{print $1}')" "$DB_SHA" "failed activation preserves Panel data/DB marker"
  assert_eq "$(sha256sum "$DATA_DIR/certs/privkey.pem" | awk '{print $1}')" "$KEY_SHA" "failed activation preserves Panel TLS key"
else
  fail "adopt_existing_pasarguard exists"
fi

assert_true "install command resolves latest to immutable owned Panel tag" grep -Fq 'pasarguard_version=$(resolve_latest_owned_panel_release)' "$ROOT_DIR/pasarguard.sh"
assert_true "install command dispatches existing installs to adoption"   grep -Fq 'adopt_existing_pasarguard "$pasarguard_version"' "$ROOT_DIR/pasarguard.sh"
assert_true "install command tracks existing installation mode"   grep -Fq 'existing_install="true"' "$ROOT_DIR/pasarguard.sh"

ENV_FILE="$WORK_DIR/no-backup-service.env"
printf '%s\n' 'SQLALCHEMY_DATABASE_URL=sqlite+aiosqlite:///db.sqlite3' >"$ENV_FILE"
if (
  unset BACKUP_SERVICE_ENABLED BACKUP_TELEGRAM_BOT_KEY BACKUP_TELEGRAM_CHAT_ID
  send_backup_to_telegram 20260101000000 >/dev/null 2>&1
); then
  pass "backup upload safely skips when backup service variables are absent"
else
  fail "backup upload safely skips when backup service variables are absent"
fi

if declare -F resolve_latest_owned_panel_release >/dev/null 2>&1; then
  curl() { printf '%s\n' '{"tag_name":"v5.4.1-awg31.9"}'; }
  assert_eq "$(resolve_latest_owned_panel_release)" "v5.4.1-awg31.9" "panel update resolves latest owned release"
else
  fail "resolve_latest_owned_panel_release exists"
fi

UPDATE_DIR="$WORK_DIR/update-panel"
mkdir -p "$UPDATE_DIR"
COMPOSE_FILE="$UPDATE_DIR/docker-compose.yml"
printf '%s\n' 'services:' '  pasarguard:' '    image: ghcr.io/gamerkhaan/panel:v5.4.1-awg31.1' >"$COMPOSE_FILE"
APP_NAME="update-panel"
docker() { [ "${1:-}" = "pull" ] && [ "${2:-}" = "ghcr.io/gamerkhaan/panel:v5.4.1-awg31.9" ]; }
set_pasarguard_panel_image() { sed -i "s#image: .*#image: $1#" "$COMPOSE_FILE"; }
compose_mock() { return 0; }
COMPOSE="compose_mock"
wait_for_pasarguard_health() { return 0; }
if update_pasarguard; then pass "panel update switches to latest owned release"; else fail "panel update switches to latest owned release"; fi
assert_true "panel update writes latest owned image" grep -Fq 'image: ghcr.io/gamerkhaan/panel:v5.4.1-awg31.9' "$COMPOSE_FILE"

if declare -F reexec_updated_pasarguard_cli >/dev/null 2>&1; then
  check_running_as_root() { return 0; }
  is_pasarguard_installed() { return 0; }
  detect_compose() { COMPOSE=compose_mock; }
  UPDATE_SCRIPT_CALLS=0; REEXEC_CALLS=0; RUNTIME_UPDATE_CALLS=0
  update_pasarguard_script() { UPDATE_SCRIPT_CALLS=$((UPDATE_SCRIPT_CALLS + 1)); }
  reexec_updated_pasarguard_cli() { REEXEC_CALLS=$((REEXEC_CALLS + 1)); return 0; }
  uninstall_completion() { return 0; }
  install_completion() { return 0; }
  update_pasarguard() { RUNTIME_UPDATE_CALLS=$((RUNTIME_UPDATE_CALLS + 1)); return 0; }
  unset PASARGUARD_UPDATE_REEXEC
  update_command
  assert_eq "$UPDATE_SCRIPT_CALLS" "1" "Panel update refreshes CLI before runtime update"
  assert_eq "$REEXEC_CALLS" "1" "Panel update re-execs refreshed CLI"
  assert_eq "$RUNTIME_UPDATE_CALLS" "0" "Panel stale process does not continue runtime update"
  UPDATE_SCRIPT_CALLS=0; REEXEC_CALLS=0; RUNTIME_UPDATE_CALLS=0
  PASARGUARD_UPDATE_REEXEC=1 update_command
  assert_eq "$UPDATE_SCRIPT_CALLS" "0" "Panel fresh re-exec skips second self-update"
  assert_eq "$REEXEC_CALLS" "0" "Panel fresh re-exec does not recurse"
  assert_eq "$RUNTIME_UPDATE_CALLS" "1" "Panel fresh re-exec performs runtime update"
else
  fail "reexec_updated_pasarguard_cli exists"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
