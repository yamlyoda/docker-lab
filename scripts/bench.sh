#!/usr/bin/env bash
# Замер образа по четырём метрикам. Запускайте до правок (baseline) и после.
#
#   ./scripts/bench.sh                 # тег по умолчанию: launch-control:baseline
#   ./scripts/bench.sh optimized       # свой тег
#   ./scripts/bench.sh optimized -f Dockerfile.optimized
#
# Результат печатается в терминал и дописывается в bench-results.md.

set -uo pipefail

TAG="${1:-baseline}"
shift || true
IMAGE="launch-control:${TAG}"
BUILD_ARGS=("$@")
build_args() { [ ${#BUILD_ARGS[@]} -eq 0 ] || printf '%s\n' "${BUILD_ARGS[@]}"; }
RESULTS_FILE="bench-results.md"

cd "$(dirname "$0")/.." || exit 1

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
dim() { printf '\033[2m%s\033[0m\n' "$1"; }

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

human_time() {
  local ms=$1
  if [ "$ms" -lt 1000 ]; then echo "${ms} ms"; else
    python3 -c "print(f'{$ms/1000:.1f} s')"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker не найден — установите Docker и повторите" >&2
  exit 1
fi

echo
bold "Launch Control — замер образа ${IMAGE}"
dim  "флаги сборки: $(build_args | tr '\n' ' ')"
echo

# ---------------------------------------------------------------- 1. холодная
bold "[1/4] Холодная сборка (--no-cache)"
start=$(now_ms)
if ! docker build --no-cache -t "$IMAGE" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} . >/tmp/lc-build-cold.log 2>&1; then
  echo "СБОРКА УПАЛА. Последние строки лога:" >&2
  tail -n 25 /tmp/lc-build-cold.log >&2
  exit 1
fi
cold_ms=$(( $(now_ms) - start ))
echo "      $(human_time $cold_ms)"

# ---------------------------------------------------------------- 2. размер
bold "[2/4] Размер и слои"
size=$(docker image inspect "$IMAGE" --format '{{.Size}}')
size_mb=$(python3 -c "print(f'{$size/1024/1024:.0f}')")
layers=$(docker image inspect "$IMAGE" --format '{{len .RootFS.Layers}}')
echo "      ${size_mb} MB, слоёв: ${layers}"

# ---------------------------------------------------------------- 3. тёплая
bold "[3/4] Тёплая пересборка (правка одной строки кода)"
touch_file="app/main.py"
cp "$touch_file" /tmp/lc-touched-backup
printf '\n# bench: touched at %s\n' "$(date -u +%FT%TZ)" >>"$touch_file"
start=$(now_ms)
docker build -t "${IMAGE}-warm" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} . >/tmp/lc-build-warm.log 2>&1
warm_ms=$(( $(now_ms) - start ))
cp /tmp/lc-touched-backup "$touch_file"
docker image rm -f "${IMAGE}-warm" >/dev/null 2>&1
echo "      $(human_time $warm_ms)"
if grep -qiE 'installing|downloading|collecting' /tmp/lc-build-warm.log; then
  dim  "      зависимости переустанавливались — слои разложены неверно"
fi

# ---------------------------------------------------------------- 4. запуск
bold "[4/4] Запуск контейнера"
user=$(docker run --rm --entrypoint sh "$IMAGE" -c 'id -un' 2>/dev/null || echo '?')
echo "      пользователь: ${user}"
if docker image inspect "$IMAGE" --format '{{.Config.Healthcheck}}' | grep -q '<nil>'; then
  healthcheck="нет"
else
  healthcheck="есть"
fi
echo "      HEALTHCHECK:  ${healthcheck}"

# ---------------------------------------------------------------- итог
echo
bold "Итог"
row() { printf '  %s\033[2m%s\033[0m %s\n' "$1" "$(printf '%*s' $((22 - $(printf '%s' "$1" | wc -m))) '' | tr ' ' '.')" "$2"; }
row "Размер"            "${size_mb} MB"
row "Слоёв"             "${layers}"
row "Холодная сборка"   "$(human_time $cold_ms)"
row "Тёплая пересборка" "$(human_time $warm_ms)"
row "Пользователь"      "${user}"
row "HEALTHCHECK"       "${healthcheck}"
echo

{
  echo "## ${IMAGE} — $(date -u +%FT%TZ)"
  echo
  echo "| Метрика | Значение |"
  echo "| --- | --- |"
  echo "| Размер | ${size_mb} MB |"
  echo "| Слоёв | ${layers} |"
  echo "| Холодная сборка | $(human_time $cold_ms) |"
  echo "| Тёплая пересборка | $(human_time $warm_ms) |"
  echo "| Пользователь | ${user} |"
  echo "| HEALTHCHECK | ${healthcheck} |"
  echo
} >>"$RESULTS_FILE"

dim "Результат дописан в ${RESULTS_FILE}"
dim "Цели: размер <= 25% baseline, тёплая пересборка — секунды, пользователь не root."
