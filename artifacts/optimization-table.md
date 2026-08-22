# Таблица «приём → размер → Δ» по промежуточным сборкам

Дата: 2026-08-22. Метрика размера: `docker image inspect .Size` (сжатые блобы,
containerd store — та же метрика, что в bench.sh/score.sh). Каждый вариант
собран через `./scripts/bench.sh <tag> -f Dockerfile.<variant>` и проверен
`./scripts/smoke.sh` (все рабочие варианты проходят).

## Основная таблица

| Приём | Образ | Dockerfile | Размер после | Δ к пред. шагу | Δ к baseline | Комментарий |
| --- | --- | --- | --- | --- | --- | --- |
| baseline (как было) | `launch-control:baseline` | `Dockerfile` | 615 MB | — | — | COPY . . тянет .venv/.git/tests; fat-база; build-инструменты и dev-зависимости в проде; слои не под кэш |
| + `.dockerignore` | `launch-control:step1-dockerignore` | `Dockerfile.step1-dockerignore` | 502 MB | **−113 MB** | −113 MB (−18 %) | Контекст потерял локальное окружение (~200 MB несжатых), .git, тесты, кэши — слой `COPY . .` съёжился. Вынужденная правка: строка `RUN pytest` удалена из сборки — тесты больше не в контексте (это часть приёма). Кэш зависимостей всё ещё ломается: pip стоит ПОСЛЕ `COPY . .`, тёплая пересборка 30.6 s |
| + slim-база | `launch-control:step2-slim` | `Dockerfile.step2-slim` | 290 MB | **−212 MB** | −325 MB (−53 %) | Полный `python:3.12` (buildpack-deps ~1.1 GB несжатых) заменён на официальный slim того же мажора с digest. Работает без компилятора, т.к. pydantic-core/pandas/numpy ставятся manylinux-колёсами. Холодная сборка выросла (68 s против 33 s): на slim apt заново качает пакеты, которые fat-база уже содержала |
| + multi-stage (без build-tools в runtime) | `launch-control:step3-multistage` | `Dockerfile.step3-multistage` | 87 MB | **−203 MB** | −528 MB (−86 %) | builder ставит зависимости, runtime забирает только site-packages + bin. Системные build-essential/curl/git/vim/procps/net-tools и apt-списки исчезли из рантайма. Dev-Python-пакеты (pytest/ruff/mypy/stubs) ещё едут — намеренно, их чистка следующий шаг |
| + без dev/лишних зависимостей | `launch-control:step4-nodev` | `Dockerfile.step4-nodev` | 50 MB | **−37 MB** | −565 MB (−92 %) | Ставится только рантайм: `uv export --frozen --no-dev --no-emit-project` (без pytest/httpx/ruff/mypy/pandas-stubs и без pandas/numpy → analytics-extra). Зависимости в /opt/venv, uv/pip/setuptools удаляются в том же слое. Побочный выигрыш: установка идёт ДО копирования кода → тёплая пересборка падает до 0.58 s |
| финал (security-полировка) | `launch-control:optimized` | `Dockerfile.optimized` | 48 MB | **−2 MB** | −567 MB (−92 %) | non-root uid 10001, HEALTHCHECK python-urllib, exec-CMD, секрет убран из ENV, runtime перенесён на чистую debian-slim (dive 99.998 % против 98–99 % на python-slim) |

## Дополнительные метрики (из bench-results.md)

| Вариант | Слоёв | Холодная сборка | Тёплая пересборка | smoke |
| --- | --- | --- | --- | --- |
| baseline | 13 | 97.1 s | 46.3 s | ✓ |
| step1-dockerignore | 12 | 32.7 s | 30.6 s | ✓ |
| step2-slim | 9 | 68.3 s | 66.0 s | ✓ |
| step3-multistage | 8 | 21.2 s | 20.3 s | ✓ |
| step4-nodev | 7 | 10.1 s | 0.583 s | ✓ |
| optimized (финал) | 6 | 11.3 s | 0.675 s | ✓ |

## Наблюдения

1. Наибольший разовый вклад дала multi-stage сборка (−203 MB): она выносит
   наружу весь набор системных сборочных инструментов, который в одноэтапной
   схеме обязан жить рядом с приложением.
2. `.dockerignore` и slim-база сопоставимы по эффекту (−113 и −212 MB), но
   решают разные проблемы: первый отсекает локальный мусор разработчика,
   вторая — неиспользуемые компоненты базового образа.
3. Тёплая пересборка починилась не размером, а порядком слоёв: пока установка
   зависимостей идёт после `COPY app`, правка одной строки перевыполняет pip.
   Именно поэтому step4 (манифесты → установка → код) даёт 0.58 s, а step3 —
   20.3 s при почти равном размере.
4. Финальные security-атрибуты (non-root, HEALTHCHECK, чистая debian-база)
   стоят всего −2 MB и одного слоя.

## Методические оговорки

- Строка `RUN python -m pytest -q` присутствовала в baseline и отсутствует во
  всех шагах: `.dockerignore` исключает `tests/` из контекста, запуск тестов
  при сборке без исходников тестов невозможен. Это осознанная часть приёма
  «тесты не едут в образ», а не скрытая оптимизация размера (слой от pytest в
  baseline весил ~2 MB).
- Промежуточные варианты сознательно сохраняют антипаттерны baseline (секрет в
  ENV, root, shell-CMD), чтобы каждый шаг изолировал ровно один приём.
