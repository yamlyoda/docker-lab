# Вариант B — Launch Control: оптимизация Docker-образа

Отчёт о работе. Лаба: маленький FastAPI-сервис «управление запусками ракет»,
который работал, но был упакован так, что образ весил больше полугигабайта,
пересобирался минутами и тащил в прод компилятор, vim, тесты и секрет.
Приложение (`app/`, `tests/`) не менялось ни разу — оптимизировалась только упаковка.

## Какой вариант выбран

**Multi-stage сборка на slim-семействе образов:**

- **builder** — `python:3.12.14-slim@sha256:2c941e86…`: ставит зависимости из
  `uv.lock` в изолированный venv; инструменты сборки (uv, pip, setuptools)
  удаляются в том же слое, где устанавливались;
- **runtime** — `debian:trixie-slim@sha256:3a39a059…`: чистая Debian-база;
  интерпретатор переносится из builder одним слоем `/usr/local`, рядом venv
  и пакет `app/`;
- non-root `uid 10001`, HEALTHCHECK средствами python-urllib (curl в образ
  не ставится), CMD в exec-форме, секретов в ENV нет;
- pandas/numpy/pandas-stubs переехали в optional-группу `analytics`
  (нужны только офлайн-инструменту `tools/analyze_launches.py`).

Полное обоснование выбора базового образа (slim vs alpine vs distroless):
[docs/base-image-decision.md](docs/base-image-decision.md).

## Что было не так изначально

Baseline `Dockerfile` (сохранился в корне репозитория как эталон «до»):

1. `FROM python:3.12` — плавающий тег без версии патча и digest;
2. `COPY . .` **до** установки зависимостей — любая правка кода сбрасывала
   кэш слоя с пакетами; в контекст попадали `.git`, `.venv`, тесты;
3. `build-essential`, `curl`, `git`, `vim`, `procps`, `net-tools` в проде;
4. `pip install ".[dev]"` — pytest/httpx/ruff/mypy/pandas-stubs в рантайме;
5. `pandas`+`numpy` в обязательных зависимостях, хотя сервис их не импортирует
   (единственный потребитель — офлайн-скрипт `tools/analyze_launches.py`);
6. секрет `ADMIN_TOKEN=launch-control-dev-token` прямо в ENV (код его даже
   не читает — grep по `app/` пуст);
7. работа от root, отсутствие HEALTHCHECK, shell-form CMD;
8. никакого `.dockerignore`.

Итог baseline по замерам: **615 MB**, тёплая пересборка **46.3 s**
(зависимости переустанавливались после правки одной строки).

## Цифры до и после

### Главные метрики (scripts/bench.sh)

| Метрика | baseline | optimized | Δ |
| --- | --- | --- | --- |
| Размер | 615 MB | **48 MB** | ×12.8 меньше |
| Слоёв | 13 | 6 | −7 |
| Холодная сборка | 97.1 s | 11.3 s | ×8.6 быстрее |
| **Тёплая пересборка** | 46.3 s | **0.675 s** | ×68 быстрее |
| Пользователь | root | app (uid 10001) | non-root |
| HEALTHCHECK | нет | есть | + |
| Контекст сборки | 182.33 MB / 5961 файлов | 116 KB / 8 файлов | ×1600 меньше |
| score.sh (BASELINE_MB=615) | 0/9 | **9/9** | — |

### Приёмы по промежуточным сборкам (размер → dive-efficiency)

Каждый шаг подтверждён замером; проваленные варианты не «исправлялись на глаз»,
а отбрасывались:

| Вариант | Размер | dive | Вердикт |
| --- | --- | --- | --- |
| baseline | 615 MB | 99.09 % | отправная точка |
| v1: multi-stage, runtime = python:slim | 50 MB | 97.80 % | ✗ отклонён (ниже baseline) |
| v2: то же на bookworm-slim | ~50 MB | 97.92 % | ✗ та же болезнь слоёв |
| v3: runtime = debian-slim + `/usr/local` + apt(libffi8) | 74 MB | 99.22 % | ⚠ trivy нашёл протёкший uv |
| v4: v3 − uv/pip (удалены в том же слое) | 49.5 MB | 98.95 % | ⚠ apt-мусор держит dive ниже цели |
| v5 = финал: − apt-слой (libffi не нужен) | **48.3 MB** | **99.9979 %** | ✓ принят |

## Сравнение hadolint / trivy / dive до и после

| Инструмент | baseline | optimized |
| --- | --- | --- |
| hadolint | 0 error, 7 warning, 4 info (DL3008/3013×2/3042×2/3064/3025…) | **пустой вывод** (`hadolint Dockerfile.optimized`) |
| dive efficiency | 99.085 %, wasted 23 MB, PASS | **99.998 %, wasted 6.9 KB**, PASS |
| trivy HIGH+CRITICAL | **571** (CRIT 56 / HIGH 513 debian + 2 py) | **51** (CRIT 3 / HIGH 48), Python-пакеты: 0 |

Артефакты: `artifacts/*baseline.txt`, `artifacts/*optimized*.txt`,
`artifacts/history-{baseline,optimized}.txt`, `artifacts/bench-optimized.txt`,
`artifacts/base-image-digest.txt`, `artifacts/context-size-comparison.txt`.

### Объяснение оставшихся 51 HIGH/CRITICAL в trivy

Ноль уязвимостей недостижим честно; остаток раскладывается так:

| Группа | Находок | Статус и объяснение |
| --- | --- | --- |
| util-linux стек (4 CVE × 9 пакетов) | 36 | фикс уже опубликован (`2.41.5-0+deb13u1`) — исчезнет при следующей пересборке от свежего digest базы. Точечный `apt upgrade` проверен и **отвергнут замером** (см. ниже): он снимает эти 36 находок, но роняет dive до 94.28 %. |
| perl-base (3 CRITICAL + 5 HIGH) | 8 | Essential-пакет Debian, фиксов апстрим ещё нет (`affected`/`fix_deferred`). Сервис perl не исполняет; через HTTP-поверхность недоступен. |
| libssl3t64 CVE-2026-14456 | 2 | `fix_deferred` у Debian security team. TLS-терминация в контейнере не выполняется (plain HTTP за балансировщиком), исходящих TLS-вызовов нет. |
| ncurses / gzip / libacl1 | 5 | фиксы не выпущены на момент сканирования; интерактивные поверхности в контейнере отсутствуют. |

## Каким слоем проверки пойман каждый дефект

| Дефект | Слой проверки, который его поймал |
| --- | --- |
| Тяжёлый образ (pandas/numpy, dev-пакеты, build-tools) | `bench.sh` размер + `docker history` + grep импортов по `app/` |
| Тёплая пересборка 46 s (COPY до зависимостей) | `bench.sh` [3/4]: grep `installing/downloading` в логе пересборки |
| Работа от root | `score.sh` №2 (`id -un`) |
| Нет HEALTHCHECK | `score.sh` №3 |
| Компилятор в рантайме | `score.sh` №4 (`command -v gcc/cc`) |
| dev-инструменты git/vim/pytest | `score.sh` №5 |
| Тесты в образе | `score.sh` №6 (`ls /app/tests`) |
| Секрет в ENV | `score.sh` №7 + hadolint DL3064 (+grep: код токен не читает) |
| Нет .dockerignore | `score.sh` №8 |
| Плавающие версии pip/apt | hadolint DL3008/DL3013/DL3042 (warning-и baseline) |
| Shell-form CMD | hadolint DL3025 |
| Утечка uv в runtime | trivy: отдельный target `usr/local/bin/uv` (24 MB) |
| Мусор dpkg/debconf в слоях базы | dive: Inefficient Files (Count×2 записи) |
| Регрессия паттернов `.dockerignore` (потеря `**/`) | пробный замер контекста: 13 файлов вместо 8 |
| Поломка импортов при переносе `/usr/local` (нет libffi.so.8) | запуск контейнера упал `ImportError`; smoke повторно подтвердил, что без apt-слоя всё работает |

## Как работали с агентом

Процесс: человек формулирует задачу и принимает решения, агент предлагает
изменения и **обязан доказать каждое замером**. Правила закреплены в
`AGENTS.md`: `app/` и `tests/` запрещено менять; любое улучшение принимается
только после прохождения полной батареи (сборка → smoke → pytest → hadolint →
trivy → dive → score 9/9); падение любой проверки = остановка, показ ошибки,
исправление, повторный прогон.

- полный журнал диалогов с командами, результатами и решениями:
  [docs/agent-dialogues.md](docs/agent-dialogues.md) (записи 1–4);
- все сырые выводы инструментов: каталог `artifacts/`;
- версии инструментов: `artifacts/tool-versions.txt`
  (docker 29.6.1 containerd store, uv 0.12.5, hadolint 2.15.1, trivy 0.74.0, dive 0.13.1).

## Что агент предложил неверно и почему отклонено

Минимум два случая требовались — реальных четыре, каждый закрыт замером,
а не мнением:

1. **Runtime на `python:slim` («стандартный путь»).** Образ вышел 50 MB и
   9/9, но dive показал **97.80 %** против baseline 99.09 % — критерий
   «эффективность не хуже baseline» нарушен. Эксперимент с bookworm-вариантом
   дал те же 97.92 %. Причина установлена по Inefficient Files: внутренние
   слои официального python-образа перезаписывают dpkg/debconf-файлы.
   Решение: чистая `debian:trixie-slim` + перенос `/usr/local` одним слоем
   → 99.998 %.
2. **Точечный `apt-get upgrade --only-upgrade` util-linux** ради минус 36
   CVE-находок. Замер: waste вырос с 6.9 KB до **20 MB**, dive упал до
   **94.28 %**. Отвергнуто; трейд-офф задокументирован в комментарии
   `Dockerfile.optimized`, фиксы придут со следующим digest базы.
3. **Apt-слой с `ca-certificates`+`libffi8` «на всякий случай».** После
   переноса `/usr/local` первый запуск упал на `libffi.so.8`, агент добавил
   apt-слой — dive осел на 98.95 % (dpkg-переписывания). Проверка показала,
   что приложению libffi не нужен вовсе (pydantic-core не использует ctypes),
   а исходящих HTTPS нет → слой удалён полностью: 99.998 %.
4. **Первая версия расширенного `.dockerignore`.** Потеряла префиксы `**/`
   у `__pycache__`/`*.pyc` — вложенные кэши снова поехали в контекст.
   Поймано пробной сборкой (13 файлов вместо 8), исправлено на
   `**/__pycache__`, `**/*.pyc`, `**/*.pyo`.

## Как воспроизвести

```bash
./scripts/tools.sh                       # проверить инструменты
uv lock && uv run --extra dev pytest -q  # локальные тесты приложения
./scripts/smoke.sh launch-control:baseline          # smoke baseline'а
BASELINE_MB=615 ./scripts/score.sh baseline         # табло «до»

docker build -f Dockerfile.optimized -t launch-control:optimized .
./scripts/smoke.sh launch-control:optimized         # smoke «после»
./scripts/bench.sh optimized -f Dockerfile.optimized
BASELINE_MB=615 ./scripts/score.sh optimized        # ожидается 9/9
```

## Что осталось незакрытым

1. **51 HIGH/CRITICAL в trivy** (объяснение выше): perl-base и ssl ждут
   фиксов Debian; util-linux закроется пересборкой от нового digest — нужен
   процесс регулярного обновления (Renovate/Dependabot не настроен).
2. **alpine и distroless** оценены аналитически ([docs/base-image-decision.md](docs/base-image-decision.md)),
   экспериментальные циклы с ними не гонялись — решение зафиксировано явно,
   но это единственное нефальсифицированное замерами сравнение в отчёте.
3. **ca-certificates в рантайме отсутствуют**: исходящих вызовов у сервиса
   нет (доказано), но если появятся HTTPS-интеграции — CA-бандл придётся
   вернуть, желательно без apt-churn (копированием из builder).
4. **`tools/analyze_launches.py`** теперь требует `uv run --extra analytics`
   (pandas/numpy выведены из дефолтных зависимостей) — поведение офлайн-
   инструмента сохранено, но команда запуска изменилась.
5. **CI-пайплайн** со всей батареей проверок не настроен — проверки
   выполнялись локально, команды воспроизведения в этом README.
