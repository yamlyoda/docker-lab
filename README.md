# Вариант B — Launch Control: оптимизация Docker-образа

Отчёт о работе. Задача: маленький FastAPI-сервис работал, но был упакован так,
что образ весил 615 MB, пересобирался минутами и тащил в прод компилятор, vim,
тесты и секрет. Приложение (`app/`, `tests/`) не менялось ни разу — правила
закреплены в `AGENTS.md`. Все цифры взяты из `artifacts/` и `bench-results.md`.

---

## 1. Какой вариант выбран

**Multi-stage сборка на slim-семействе образов:**

- **builder**: `python:3.12.14-slim@sha256:2c941e86…` — официальный CPython;
  ставит зависимости из `uv.lock` (`--no-dev`) в изолированный `/opt/venv`;
  инструменты сборки (uv/pip/setuptools) удаляются **в том же слое**, где
  ставились;
- **runtime**: `debian:trixie-slim@sha256:3a39a059…` — чистая Debian-база;
  интерпретатор переносится одним слоем `/usr/local`, рядом venv и пакет `app/`;
- non-root `uid 10001`, HEALTHCHECK средствами python-urllib, CMD в exec-форме,
  секретов в ENV нет;
- pandas/numpy/pandas-stubs выведены в optional-группу `analytics`
  (потребитель только офлайн-скрипт `tools/analyze_launches.py`).

Стратегия: кумулятивные одноприёмные шаги, каждый подтверждён замером
(см. §5, таблицу приёмов); падение любого критерия = остановка и починка,
а не «и так сойдёт».

Почему выбран этот вариант: у официального `python:slim` внутри собственных
слоёв остаётся мусор от apt/dpkg (dive показал 97.80–97.92 % эффективности),
а чистая `debian:trixie-slim` даёт 99.998 % при том же размере. Подробное
сравнение с измерениями — [docs/base-image-decision.md](docs/base-image-decision.md).

Отклонённые альтернативы базового образа:

| Вариант | Вердикт | Основание |
| --- | --- | --- |
| `python:slim` как runtime | ❌ замером | dive 97.80 % (bookworm 97.92 %) < baseline 99.09 %: внутренние перезаписи dpkg/debconf в слоях базы |
| alpine | ❌ аналитически | musl-риски для колёс uvloop/httptools/pydantic-core; другой пакетный менеджер; профиль dive/trivy не измерялся — а без замера не принимаем |
| distroless | ❌ проверкой | доступные варианты дают Python **3.11.2** (debian12) и **3.13.5** (debian13) — оба вне зафиксированного `requires-python >=3.12,<3.13`; плюс нет shell для аварийной отладки |

## 2. Что было не так изначально

Baseline (сохранён как `Dockerfile.baseline`, размер зафиксирован в
[artifacts/baseline-size.txt](artifacts/baseline-size.txt)):
**645 278 055 байт ≈ 615 MB, 13 слоёв**; тёплая пересборка 46.3 s; root;
HEALTHCHECK отсутствует.

Проблемы:

1. плавающий тег `FROM python:3.12` без патч-версии и digest;
2. `COPY . .` **до** установки зависимостей — правка кода сбрасывала кэш
   пакетного слоя; в контекст ехали `.git`, локальный `.venv`, тесты;
3. `build-essential`, `curl`, `git`, `vim`, `procps`, `net-tools` в проде;
4. `pip install ".[dev]"` — pytest/httpx/ruff/mypy/pandas-stubs в рантайме;
5. pandas+numpy в обязательных зависимостях, хотя сервис их не импортирует;
6. секрет `ADMIN_TOKEN=launch-control-dev-token` в ENV (код его не читает);
7. работа от root; shell-form CMD; нет `.dockerignore`.

Выводы инструментов по baseline сохранены:

- [artifacts/hadolint-baseline.txt](artifacts/hadolint-baseline.txt) — 0 error, 7 warning, 4 info;
- [artifacts/trivy-baseline.txt](artifacts/trivy-baseline.txt) — 571 HIGH/CRITICAL;
- [artifacts/dive-baseline.txt](artifacts/dive-baseline.txt) — efficiency 99.09 %, wasted 23 MB;
- [artifacts/history-baseline.txt](artifacts/history-baseline.txt) — раскладка слоёв
  (pip ".[dev]" 390 MB, COPY . . 198 MB, apt-инструменты 76 MB).

## 3. Как работали с агентом

Процесс: человек ставит задачу и принимает решения, агент предлагает изменения
и обязан доказывать каждое замером. Полнота — в
[docs/agent-dialogues.md](docs/agent-dialogues.md) (записи 1–7). Ниже три
реальных фрагмента.

### Фрагмент 1 — первый вариант оптимизации провален dive'ом (запись 3)

> **Промпт:** «ок» — утверждение плана (smoke.sh, multi-stage Dockerfile,
> слои под кэш, non-root/HEALTHCHECK/CMD, pandas→analytics, .dockerignore).
>
> **Агент:** собрал optimized (runtime = python:slim): 50 MB, score 9/9,
> smoke зелёный — но dive efficiency **97.80 % < baseline 99.09 %**.
> Критерий провален, остановка по правилу №9. Эксперимент с bookworm дал
> 97.92 % — та же болезнь слоёв. Решение: runtime на чистом debian-slim
> с переносом интерпретатора одним слоем.
>
> **Решение человека:** принято (наблюдение за ходом работы). Финал — 48.3 MB,
> dive 99.9979 %.

### Фрагмент 2 — промежуточные сборки: почему починилась тёплая пересборка (запись 5)

> **Промпт:** создать промежуточные Dockerfile'ы step1–step4, прогнать через
> bench.sh и smoke, собрать таблицу «приём → размер → Δ».
>
> **Агент:** все четыре шага собрались и прошли smoke; неожиданное наблюдение:
> холодная сборка на slim дольше (68 s против 33 s у fat-шага) — apt заново
> качает пакеты, уже входившие в fat-базу; тёплая пересборка починилась
> порядком слоёв, а не размером: step3 при 87 MB всё ещё гонял pip 20.3 s.
>
> **Решение человека:** принято; таблица легла в README и артефакты.

### Фрагмент 3 — ложный зелёный тест при удалении pydantic (запись 7)

> **Промпт:** явно проверить агрессивные советы агента, минимум 2 отклонить
> с доказательствами, ничего не выдумывая.
>
> **Агент:** кандидат A «удалить pydantic»: первая попытка дала ложный вывод —
> после `uv pip uninstall` команда `uv run pytest` показала «17 passed», потому
> что uv молча пересинхронизировал окружение и вернул пакет из лока.
> Корректный замер: `.venv/bin/pytest` сразу после удаления →
> `ModuleNotFoundError: No module named 'pydantic'`, 2 errors during collection.
>
> **Решение человека:** принято; кандидат отклонён, окружение восстановлено.

## 4. Что агент предложил неверно и почему я это отклонил

Полная таблица — [docs/rejected-agent-advice.md](docs/rejected-agent-advice.md).
Минимум перекрыт с запасом: ниже четыре случая, все — реальные.

### Случай 1: runtime на `python:slim`

- **Что предложил:** обычный multi-stage с python-slim в обеих стадиях.
- **Почему привлекательно:** стандартная рекомендация всех гайдов; образ сразу
  вышел 50 MB и 9/9.
- **Проверка:** `CI=true dive`.
- **Вывод:** efficiency **97.80 %** против baseline 99.09 % — критерий «не хуже
  baseline» нарушен; bookworm-вариант подтвердил (97.92 %).
- **Почему отклонено:** мусор от dpkg/debconf запечён в слоях самой базы.
  Заменено на debian-slim + перенос `/usr/local`: 99.9979 %.

### Случай 2: точечный `apt upgrade util-linux` ради −36 CVE

- **Что предложил:** обновить пакеты с опубликованными фиксами прямо в runtime.
- **Почему привлекательно:** минус 36 находок trivy одной строкой.
- **Проверка:** сборка варианта с upgrade + dive + smoke.
- **Вывод:** waste вырос до **20 MB**, dive упал до **94.28 %**.
- **Почему отклонено:** обменивает объяснимые находки на реальное ухудшение
  качества слоёв; фиксы придут сами при следующем digest базы.

### Случай 3: удаление `pydantic`

- **Что предложил:** убрать «лишнюю» зависимость.
- **Почему привлекательно:** казалось, что FastAPI валидирует сам.
- **Проверка:** grep + живой pytest после удаления пакета.
- **Вывод:** `ModuleNotFoundError: No module named 'pydantic'`, коллекция тестов
  падает (2 errors).
- **Почему отклонено:** прямое нарушение правила «не удалять зависимости без
  доказательств неиспользования»; приложение импортирует pydantic напрямую.

### Случай 4: `curl` в рантайме ради HEALTHCHECK

- **Что предложил:** привычный curl-based healthcheck.
- **Почему привлекательно:** функционально работает, smoke зелёный.
- **Проверка:** сборка кандидата, замер размера и dive.
- **Вывод:** **+5.9 MB** и dive **99.0028 %** (< baseline).
- **Почему отклонено:** python-urllib healthcheck уже работает без единой
  дополнительной зависимости; curl — мёртвый груз и лишний surface.

## 5. Цифры и результаты до и после

### Основные метрики

| Метрика | baseline | optimized |
| --- | --- | --- |
| Размер образа | 615 MB | **48 MB** (×12.8) |
| score.sh | 0/9 | **9/9** |
| hadolint | 0 error / 7 warning / 4 info | **пустой вывод** |
| trivy HIGH+CRITICAL | **571** (CRIT 56, HIGH 513 + 2 py) | **51** (CRIT 3, HIGH 48) |
| dive efficiency | 99.085 % (wasted 23 MB) | **99.998 %** (wasted 6.9 KB) |
| Тёплая пересборка | 46.3 s | **0.61–0.79 s** (bench / ручной прогон) |
| Холодная сборка | 97.1 s | 9.3 s |
| Build context | 182.33 MB / 5961 файлов | **116 KB / 8 файлов** |

Объяснение оставшихся 51 HIGH/CRITICAL (осознанный долг):

| Группа | Находок | Почему остались |
| --- | --- | --- |
| util-linux стек | 36 | фикс опубликован (`2.41.5-0+deb13u1`), исчезнет при пересборке от свежего digest; точечный upgrade отвергнут замером (§4.2) |
| perl-base (Essential Debian) | 8 (из них 3 CRITICAL) | фиксов апстрим ещё нет; сервис perl не исполняет, HTTP-поверхность недоступна |
| libssl3t64 | 2 | `fix_deferred` у Debian; TLS-терминация и исходящие TLS в контейнере не используются |
| ncurses/gzip/libacl1 | 5 | фиксы не выпущены на момент сканирования |

### Таблица «приём → размер → Δ»

(полная версия с комментариями —
[artifacts/optimization-table.md](artifacts/optimization-table.md))

| Приём | Образ | Размер | Δ к пред. | Δ к baseline |
| --- | --- | --- | --- | --- |
| baseline | `launch-control:baseline` | 615 MB | — | — |
| + `.dockerignore` | `launch-control:step1-dockerignore` | 502 MB | −113 MB | −18 % |
| + slim-база | `launch-control:step2-slim` | 290 MB | −212 MB | −53 % |
| + multi-stage (−build-tools) | `launch-control:step3-multistage` | 87 MB | −203 MB | −86 % |
| + без dev/лишних пакетов | `launch-control:step4-nodev` | 50 MB | −37 MB | −92 % |
| финал: security-полировка | `launch-control:optimized` | 48 MB | −2 MB | **−92 %** |

Ключевое наблюдение таблицы: тёплая пересборка починилась **порядком слоёв**,
а не размером — step3 при 87 MB всё ещё переустанавливал pip 20.3 s, step4
(манифесты → установка → код) — 0.583 s.

## 6. Чем именно пойман каждый дефект

| Дефект | Слой проверки, который его поймал |
| --- | --- |
| Тяжёлый образ: pandas/numpy, dev-пакеты, build-tools, `.venv` в контексте | `bench.sh` (размер) + `docker history` + grep импортов + trivy (лишние пакеты) |
| Сломанный кэш: `COPY . .` до зависимостей | **warm rebuild** (`bench.sh` [3/4]): 46.3 s baseline; позже тот же инструмент различил step3 (20.3 s) и step4 (0.583 s) при почти равном размере |
| Работа от root | `score.sh` №2 (`id -un`) |
| Нет HEALTHCHECK | `score.sh` №3 |
| Компилятор gcc/cc в проде | `score.sh` №4 |
| git/vim/pytest в проде | `score.sh` №5 |
| Тесты в образе | `score.sh` №6 (`ls /app/tests`) |
| Секрет в ENV | `score.sh` №7 + hadolint DL3064 (+grep: код токен не читает) |
| Нет `.dockerignore` | `score.sh` №8 |
| Плавающие версии pip/apt, shell-CMD | hadolint: DL3008/DL3013/DL3042, DL3025 |
| Уязвимости пакетов (571) | trivy |
| Протёкший uv в runtime (24 MB) | trivy: отдельный target `usr/local/bin/uv` |
| Мусор dpkg/debconf в слоях базы | dive: Inefficient Files (97.80 % → отказ от python-slim runtime) |
| Поломка импортов при переносе `/usr/local` (нет libffi.so.8) | запуск контейнера упал `ImportError`; smoke повторно подтвердил рабочесть после отказа от apt-слоя |
| Ложный вывод «pydantic не нужен» | живой pytest: ModuleNotFoundError (см. §4.3) |

Честные оговорки по слоям без пойманных дефектов:

- **pytest** не нашёл дефектов в финальном образе — приложение не менялось;
  его роль здесь регрессионный щит (17 passed на каждом шаге) и источник
  контракта для smoke-набора;
- **helm/kubeconform/kustomize/terraform** не применялись — Kubernetes-часть
  в задании отсутствует.

## 7. Что осталось незакрытым и почему

1. **51 HIGH/CRITICAL в trivy** — см. §5: util-linux ждёт digest-апдейта базы,
   perl-base/ssl/ncurses/gzip/acl ждут фиксов апстрима. Безопасно убрать нельзя.
2. **Нет автоматического обновления digest** базовых образов (Renovate/
   Dependabot не настроен) — обновление сейчас ручное: новый digest + пересборка.
3. **Нет SBOM** (`trivy image --format cyclonedx` не включён в пайплайн) и
   **нет подписи образа** (cosign) — за пределами текущего задания.
4. **Все проверки выполнялись локально**, не в CI; часть метрик зависит от
   версии Docker (`.Size` в containerd store — сжатый размер; на классическом
   overlay-драйвере числа будут другими, сравнение «до/после» остаётся честным,
   абсолюты — нет).
5. **alpine/distroless оценены аналитически** ([docs/base-image-decision.md](docs/base-image-decision.md));
   экспериментальные циклы для них не гонялись — единственное нефальсифицированное
   замерами сравнение в отчёте (distroless дополнительно отсечён проверкой версий
   Python — §1).
6. **ca-certificates в рантайме отсутствуют**: исходящих HTTPS нет (доказано),
   но при появлении интеграций CA-бандл придётся вернуть без apt-churn
   (копированием из builder).
7. **hadolint warning'и в baseline** остались намеренно — `Dockerfile.baseline`
   это эталон «как было»; финальный `Dockerfile` чист полностью.

## 8. Версии инструментов

Из [artifacts/tool-versions.txt](artifacts/tool-versions.txt):

| Инструмент | Версия |
| --- | --- |
| Docker | 29.6.1 (containerd snapshotter — `.Size` = сжатые блобы) |
| uv | 0.12.5 |
| hadolint | 2.15.1 |
| Trivy | 0.74.0 |
| Dive | 0.13.1 |
| jq | 1.7.1 |
| Helm | не использовался в этом задании |
| kubeconform | не использовался в этом задании |
| Kustomize | не использовался в этом задании |
| Terraform | не использовался в этом задании |
| Kubernetes | целевая версия не задана — задание ограничено локальным Docker |

Системный `python3` хоста (3.9.6) использовался только скриптами bench/smoke;
в проекте Python 3.12 через uv.

## 9. Артефакты

Все результаты проверяемы по файлам каталога `artifacts/`:

| Файл | Содержимое |
| --- | --- |
| `baseline-size.txt` | точный размер baseline (645 278 055 B, 13 слоёв) |
| `git-status-before.txt` | состояние репозитория до начала работы |
| `tool-versions.txt` | версии инструментов |
| `hadolint-baseline.txt` / `hadolint-optimized.txt` | hadolint до/после |
| `trivy-baseline.txt` / `trivy-optimized.txt` / `trivy-optimized-first.txt` | trivy до/после + первая сборка optimized |
| `dive-baseline.txt` / `dive-optimized.txt` / `dive-optimized.json` | dive до/после + JSON-экспорт |
| `history-baseline.txt` / `history-optimized.txt` | раскладка слоёв |
| `runtime-deps.txt` | состав рантайм-зависимостей (pandas/numpy отсутствуют) |
| `pytest-before.txt` | тесты до правок (17 passed) |
| `context-before-ignore.txt` / `context-after-ignore.txt` / `context-size-comparison.txt` | влияние .dockerignore на контекст |
| `score-optimized.txt` | табло score.sh (9/9) |
| `bench-optimized.txt` | финальный bench |
| `step-sizes.txt` / `optimization-table.md` | промежуточные сборки и таблица приёмов |
| `warm-rebuild.txt` | лог тёплой пересборки (CACHED-слои, 0.786 s) |
| `base-image-digest.txt` | digest базового образа через imagetools inspect |

Дополнительные документы: [docs/base-image-decision.md](docs/base-image-decision.md),
[docs/rejected-agent-advice.md](docs/rejected-agent-advice.md),
[docs/agent-dialogues.md](docs/agent-dialogues.md).

## Воспроизведение

```bash
./scripts/tools.sh                                   # проверить инструменты
uv lock && uv run --extra dev pytest -q              # тесты приложения
./scripts/smoke.sh launch-control:baseline           # smoke «до»
BASELINE_MB=615 ./scripts/score.sh baseline          # табло «до»

docker build -f Dockerfile -t launch-control:optimized .
./scripts/bench.sh optimized                         # замер «после»
./scripts/smoke.sh launch-control:optimized
BASELINE_MB=615 ./scripts/score.sh optimized         # ожидается 9/9
```
