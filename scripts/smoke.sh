#!/usr/bin/env bash
# Smoke-тест образа launch-control.
#
#   ./scripts/smoke.sh                          # по умолчанию launch-control:optimized
#   ./scripts/smoke.sh launch-control:baseline  # любой тег
#
# Поднимает контейнер, дергает эндпоинты и ПАДАЕТ С НЕнулевой кодом,
# если что-то не отвечает или отвечает не то, что ожидается.

set -uo pipefail

IMAGE="${1:-launch-control:optimized}"
PORT="${SMOKE_PORT:-8099}"
CONTAINER="lc-smoke-$$"
BASE_URL="http://localhost:${PORT}"

fail() {
  echo "  ✗ $1" >&2
  docker logs "$CONTAINER" 2>/dev/null | tail -n 20 >&2
  exit 1
}

pass_line() { printf '  \033[32m✓\033[0m %s\n' "$1"; }

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

command -v curl >/dev/null 2>&1 || fail "curl не найден на хосте"
command -v python3 >/dev/null 2>&1 || fail "python3 не найден на хосте"
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "образ $IMAGE не найден"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
bold "Launch Control — smoke $IMAGE"

docker run -d --rm --name "$CONTAINER" -p "${PORT}:8000" "$IMAGE" >/dev/null \
  || fail "контейнер не стартовал"

# --- ожидание старта -------------------------------------------------------
up=""
for _ in $(seq 1 30); do
  code=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/health" 2>/dev/null || true)
  [ "$code" = "200" ] && up=1 && break
  sleep 1
done
[ -n "$up" ] || fail "/health не ответил 200 за 30 секунд"
pass_line "контейнер поднялся, /health → 200"

# --- проверки контракта (зеркало tests/test_api.py) -------------------------
code_of() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }
expect() { # expect <описание> <ожидание> <факт>
  if [ "$3" = "$2" ]; then pass_line "$1"; else
    echo "  ожидалось: $2, получено: $3" >&2
    fail "$1"
  fi
}

json_field() { python3 -c "import sys, json; print(json.load(sys.stdin)$1)"; }

expect "/ready → 200 (манифест загружен)" "200" "$(code_of "$BASE_URL/ready")"

body=$(curl -fsS "$BASE_URL/api/v1/launches") || fail "GET /api/v1/launches упал"
count=$(printf '%s' "$body" | python3 -c 'import sys, json; print(len(json.load(sys.stdin)))')
expect "GET /api/v1/launches → 5 записей" "5" "$count"

first=$(printf '%s' "$body" | python3 -c 'import sys, json; print(json.load(sys.stdin)[0]["id"])')
expect "первая запись отсортирована (LC-105)" "LC-105" "$first"

expect "GET несуществующего id → 404" "404" "$(code_of "$BASE_URL/api/v1/launches/LC-000")"

cd=$(curl -fsS -X POST "$BASE_URL/api/v1/launches/LC-101/countdown") || fail "POST countdown LC-101 упал"
go=$(printf '%s' "$cd" | python3 -c 'import sys, json; print(json.load(sys.stdin)["go_for_launch"])')
expect "POST countdown LC-101 → go_for_launch=True" "True" "$go"

expect "POST countdown LC-102 (weather) → 409" "409" \
  "$(code_of -X POST "$BASE_URL/api/v1/launches/LC-102/countdown")"

hold=$(curl -fsS -X POST -H 'Content-Type: application/json' \
  -d '{"reason":"smoke test"}' "$BASE_URL/api/v1/launches/LC-101/hold") \
  || fail "POST hold LC-101 упал"
status=$(printf '%s' "$hold" | python3 -c 'import sys, json; print(json.load(sys.stdin)["status"])')
expect "POST hold LC-101 → status=hold" "hold" "$status"

metrics=$(curl -fsS "$BASE_URL/internal/metrics") || fail "GET /internal/metrics упал"
total=$(printf '%s' "$metrics" | python3 -c 'import sys, json; print(json.load(sys.stdin)["launches_total"])')
expect "GET /internal/metrics → launches_total=5" "5" "$total"

printf '\n\033[1mSmoke пройден: %s работает.\033[0m\n' "$IMAGE"
