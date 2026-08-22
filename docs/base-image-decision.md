# Выбор базового образа для launch-control:optimized

Дата: 2026-08-22. Все цифры — замеры на этой машине (docker 29.6.1, containerd
snapshotter, arm64), а не теория. Метрика размера — `docker image inspect
.Size` (сжатые блобы; та же метрика используется bench.sh/score.sh).

## Выбранный вариант: multi-stage гибрид на slim-семействе

- **builder**: `python:3.12.14-slim@sha256:2c941e86…` — официальный CPython,
  нужен для `uv venv`/`uv pip install`; из него же в runtime переносится
  `/usr/local` (сам интерпретатор).
- **runtime**: `debian:trixie-slim@sha256:3a39a059…` — чистая Debian-база
  без следов сборки python-образа.

Digest получен и зафиксирован:
`docker buildx imagetools inspect python:3.12-slim | tee artifacts/base-image-digest.txt`
(манифест-лист digest совпадает с указанным в FROM).

### Итоговые замеры выбранного варианта

| Проверка | Значение |
| --- | --- |
| Размер | 48 MB (лимит score.sh: ≤153 MB) |
| dive efficiency | **99.9979 %** (wasted 6.9 KB) |
| trivy HIGH/CRITICAL | 3 CRITICAL + 48 HIGH (у baseline: 56 + 515) |
| smoke.sh / pytest 17 тестов | зелёные |
| hadolint Dockerfile.optimized | 0 замечаний |
| score.sh (BASELINE_MB=615) | 9/9 |

## Почему не чистый `python:slim` как runtime (отклонено ЗАМЕРОМ)

Первый вариант оптимизации использовал `python:3.12-slim` в обеих стадиях.
Замер dive показал **efficiency 97.80 %** (wasted 5.6 MB): внутренние слои
официального образа перезаписывают служебные файлы dpkg/debconf, и это
остаётся «мусором» в любом производном образе. Проверка bookworm-варианта
(`python:3.12.14-slim-bookworm`) дала те же **97.92 %** — проблема не в
релизе Debian, а в способе сборки официального образа. Критерий «dive не хуже
baseline (99.09 %)» не выполнялся → вариант отклонён по данным замера, а не по
вкусу.

Перенос `/usr/local` одним слоем из builder на чистую debian-slim дал
99.9979 % при том же размере.

## Alpine (`python:3.12-alpine` / `alpine:3.22` + apk) — отклонён аналитически

1. **musl vs glibc**: у pydantic-core/uvloop/httptools есть musllinux-колёса,
   но любая транзитивная зависимость без musl-колеса требует компиляции в
   builder и несёт риск ABI-сюрпризов в runtime. Для glibc-варианта таких
   рисков нет — все колёса manylinux.
2. Другая экосистема пакетов/синтаксис (`apk`, busybox `adduser`) — отдельные
   ветки в Dockerfile без выигрыша: размер уже 48 MB, экономия от alpine была
   бы десятки MB ценой перечисленных рисков.
3. Профиль dive/trivy для alpine-варианта не измерялся — а по правилам работы
   изменение принимается только после замера; проводить цикл экспериментов
   ради варианта с известными рисками сочтено нецелесообразным.

Пробная alpine-сборка использовалась только как нейтральный инструмент замера
контекста (artifacts/context-size-comparison.txt), не как кандидат рантайма.

## Distroless (`gcr.io/distroless/python3`) — отклонён аналитически

1. **Версия Python**: теги distroless следуют за релизами Debian
   (python3-debian12 → 3.11); жёсткая фиксация именно 3.12 с предсказуемым
   обновлением патчей — слабая сторона. Требование проекта
   `requires-python >=3.12,<3.13` исключает соседние мажоры.
2. **Нет shell** → HEALTHCHECK возможен только внешним бинарником или
   exec-вызовом самого python; отладка упавшего контейнера (`kubectl exec`,
   `docker run … sh`) невозможна даже аварийно.
3. Наша схема установки (venv + копирование) потребовала бы переписать layout,
   а выигрыш против debian-slim — единицы MB при уже 48 MB.

## Как выбор подтверждён проверками

- сборка проходит, контейнер стартует: smoke.sh — все эндпоинты отвечают;
- поведение идентично baseline: 17/17 pytest, зеркальный smoke-набор;
- hadolint Dockerfile.optimized: пустой вывод;
- dive CI: PASS, efficiency 99.9979 % ≥ baseline 99.0851 %;
- trivy: HIGH+CRITICAL сокращены с 571 до 51, остаток объяснён (README);
- score.sh optimized: 9/9.
