#!/usr/bin/env bash
# Табло прогресса: девять проверок, которые должны позеленеть к сдаче.
#
#   ./scripts/score.sh                # проверяет launch-control:optimized
#   ./scripts/score.sh baseline       # можно натравить на любой тег
#
# Скрипт ничего не чинит и не подсказывает, ЧТО именно не так — только
# показывает, какие проверки пока красные.

set -uo pipefail

TAG="${1:-optimized}"
IMAGE="launch-control:${TAG}"
BASELINE_MB="${BASELINE_MB:-0}"

cd "$(dirname "$0")/.." || exit 1

pass=0
total=0

check() {
  local name="$1" status="$2" detail="${3:-}"
  [ -n "$detail" ] && detail="  — ${detail}"
  total=$((total + 1))
  case "$status" in
    ok)   pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\033[2m%s\033[0m\n' "$name" "$detail" ;;
    skip) printf '  \033[2m– %s%s\033[0m\n' "$name" "$detail" ;;
    *)    printf '  \033[31m✗\033[0m %s\033[2m%s\033[0m\n' "$name" "$detail" ;;
  esac
}

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Образ ${IMAGE} не найден. Соберите его: docker build -t ${IMAGE} ." >&2
  exit 1
fi

printf '\n\033[1mLaunch Control — табло %s\033[0m\n\n' "$IMAGE"

# 1. размер
size_mb=$(docker image inspect "$IMAGE" --format '{{.Size}}' |
  xargs -I{} python3 -c "print(int({}/1024/1024))")
if [ "$BASELINE_MB" -gt 0 ]; then
  limit=$((BASELINE_MB / 4))
  [ "$size_mb" -le "$limit" ] && s=ok || s=fail
  check "Размер <= 25% baseline" "$s" "${size_mb} MB (лимит ${limit} MB)"
else
  [ "$size_mb" -le 400 ] && s=ok || s=fail
  check "Размер <= 400 MB" "$s" "${size_mb} MB"
fi

# 2. non-root
user=$(docker run --rm --entrypoint sh "$IMAGE" -c 'id -un' 2>/dev/null || echo root)
[ "$user" != "root" ] && s=ok || s=fail
check "Работает не от root" "$s" "$user"

# 3. healthcheck
docker image inspect "$IMAGE" --format '{{.Config.Healthcheck}}' | grep -q '<nil>' && s=fail || s=ok
check "Есть HEALTHCHECK" "$s"

# 4. нет компилятора в финальном образе
if docker run --rm --entrypoint sh "$IMAGE" -c 'command -v gcc || command -v cc' >/dev/null 2>&1; then
  check "Нет компилятора в runtime" fail "найден gcc/cc"
else
  check "Нет компилятора в runtime" ok
fi

# 5. нет dev-инструментов
found=""
for tool in git vim pytest; do
  docker run --rm --entrypoint sh "$IMAGE" -c "command -v $tool" >/dev/null 2>&1 && found="$found $tool"
done
[ -z "$found" ] && check "Нет dev-инструментов" ok || check "Нет dev-инструментов" fail "найдено:$found"

# 6. нет исходников тестов
if docker run --rm --entrypoint sh "$IMAGE" -c 'ls /app/tests' >/dev/null 2>&1; then
  check "Тесты не едут в образ" fail "/app/tests существует"
else
  check "Тесты не едут в образ" ok
fi

# 7. секрет в ENV
if docker image inspect "$IMAGE" --format '{{json .Config.Env}}' | grep -qi 'token\|password\|secret'; then
  check "Нет секретов в ENV" fail "проверьте docker image inspect"
else
  check "Нет секретов в ENV" ok
fi

# 8. .dockerignore
if [ -f .dockerignore ]; then
  check "Есть .dockerignore" ok "$(grep -cvE '^\s*(#|$)' .dockerignore) правил"
else
  check "Есть .dockerignore" fail "файла нет"
fi

# 9. hadolint
if command -v hadolint >/dev/null 2>&1; then
  errors=$(hadolint --format json Dockerfile 2>/dev/null | grep -o '"level":"error"' | wc -l | tr -d ' ')
  [ "$errors" = "0" ] && check "hadolint без ошибок" ok || check "hadolint без ошибок" fail "${errors} error"
else
  check "hadolint без ошибок" skip "hadolint не установлен"
fi

printf '\n  \033[1mГотово: %s/%s\033[0m\n\n' "$pass" "$total"
[ "$pass" -eq "$total" ] || exit 1
