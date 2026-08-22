# Финальный отчёт приёмки задания — launch-control

Дата: 2026-08-22. Статус: **ЗАДАНИЕ ГОТОВО** (FAIL нет; 2 пункта — PASS_WITH_NOTE
с объяснением).

| № | Пункт | Статус | Подтверждение |
| --- | --- | --- | --- |
| 1a | artifacts/baseline-size.txt | ✅ PASS | файл существует: 645 278 055 B ≈ 615 MB, 13 слоёв |
| 1b | artifacts/hadolint-baseline.txt | ✅ PASS | 0 error / 7 warning / 4 info |
| 1c | artifacts/trivy-baseline.txt | ✅ PASS | CRITICAL 56 + HIGH 513 (debian) + HIGH 2 (Python) = 571 |
| 1d | artifacts/dive-baseline.txt | ✅ PASS | efficiency 99.085 %, wasted 23 MB, PASS |
| 1e | bench baseline | ✅ PASS | `bench-results.md` запись от 2026-08-22T15:15:57Z: 615 MB / 13 слоёв / cold 97.1 s / warm 46.3 s / root / HC нет |
| 1f | score baseline | ⚠️ PASS_WITH_NOTE | `artifacts/score-baseline.txt`: **2/9**. Оговорка: score.sh проверяет hadolint у текущего `Dockerfile` (теперь это оптимизированный файл) и наличие `.dockerignore` в репозитории — эти два пункта зелёные и для baseline-образа. Остальные 7 красные ровно так, как ожидалось «до»: размер, root, HC, компилятор, dev-tools, тесты, секрет |
| 2 | smoke.sh | ✅ PASS | `-rwxr-xr-x`; позитив: `./scripts/smoke.sh launch-control:optimized` → exit=0, все эндпоинты отвечают; негатив: несуществующий тег → **exit=1** |
| 3 | pytest | ✅ PASS | `uv run --extra dev pytest -q` → **17 passed** (норма зафиксирована: 17 тестов) |
| 4a | Dockerfile многоступенчатый | ✅ PASS | `FROM … AS builder` (стр. 12) + `FROM debian:trixie-slim@sha256:3a39… AS runtime` (стр. 39) |
| 4b | сборочные зависимости не в runtime | ✅ PASS | `docker run … command -v gcc cc` → отсутствуют; uv/pip удалены в builder-слое установки |
| 4c | зависимости до исходников | ✅ PASS | порядок в Dockerfile: COPY pyproject+lock (22) → RUN установка (27) → COPY app (59, последним); warm-log: слой установки CACHED при пересборке кода |
| 4d | нет dev-зависимостей | ✅ PASS | `pip list` в образе: pytest/ruff/mypy/httpx = **0 пакетов** |
| 4e | нет кэшей | ✅ PASS | `/root/.cache`, apt-lists в образе отсутствуют (листинг пуст); pip/uv всегда с `--no-cache(-dir)` |
| 4f | нет .git | ✅ PASS | `ls /app/.git` → отсутствует (+ `.dockerignore`) |
| 4g | нет тестов | ✅ PASS | `ls /app/tests` → отсутствует; score №6 ✓ |
| 4h | non-root | ✅ PASS | `id` в контейнере: uid=10001(app) |
| 4i | HEALTHCHECK | ✅ PASS | inspect: exec-form python-urllib на `${PORT:-8000}` |
| 4j | CMD корректный | ✅ PASS | exec-форма `["sh","-c","exec python -m uvicorn …"]` — сигналы проходят к uvicorn через exec; PORT конфигурируем |
| 4k | база зафиксирована | ✅ PASS | оба FROM с тегом патч-версии + digest; digest задокументирован (`artifacts/base-image-digest.txt`) |
| 5a | hadolint Dockerfile | ✅ PASS | пустой вывод (`artifacts/hadolint-optimized.txt`) |
| 5b | trivy HIGH/CRITICAL | ⚠️ PASS_WITH_NOTE | **51** (CRIT 3 / HIGH 48), все объяснены в README §5: util-linux ×36 (фикс опубликован, придёт с новым digest базы), perl-base ×8 и ncurses/gzip/libacl ×5 (фиксов апстрим нет), libssl3t64 ×2 (fix_deferred). Артефакт: `artifacts/trivy-optimized.txt` |
| 5c | dive выше baseline | ✅ PASS | **99.9979 %** vs 99.0851 %; wasted 6.9 KB vs 23 MB (`artifacts/dive-optimized.txt`, JSON рядом) |
| 5d | bench optimized | ✅ PASS | финальный прогон: 48 MB / 6 слоёв / cold 9.3 s / warm 0.613 s / app / HC есть (`artifacts/bench-optimized.txt`, `bench-results.md`) |
| 5e | score optimized 9/9 | ✅ PASS | `BASELINE_MB=615 ./scripts/score.sh optimized` → **9/9**, лимит размера 153 MB, факт 48 MB (`artifacts/score-optimized.txt`) |
| 6 | кэш зависимостей | ✅ PASS | ручной тест: правка одной строки app/main.py → **CACHED ×7**, installing/downloading = **0**, пересобрался только `COPY app`, итого **0.786 s** (`artifacts/warm-rebuild.txt`); правка откачена, git чист |
| 7 | .dockerignore | ✅ PASS | 46 активных правил (.git/.venv/**/__pycache__/tests/docs/artifacts…); влияние измерено: контекст **182.33 MB / 5961 файлов → 116 KB / 8 файлов** (`artifacts/context-size-comparison.txt`) |
| 8 | таблица оптимизаций | ✅ PASS | `artifacts/optimization-table.md`: baseline 615 → +ignore 502 (−113) → +slim 290 (−212) → +multi-stage 87 (−203) → +nodev 50 (−37) → финал 48 MB (−92 % к baseline); каждый шаг собран bench.sh и прошёл smoke |
| 9 | диалоги агента | ✅ PASS | `docs/agent-dialogues.md`: 7 реальных записей; отклонённых советов — 8 суммарно (5 из красного цикла + 3 ранних замерённых); фрагменты для README использованы (§3 README) |
| 10 | README | ✅ PASS | все 9 обязательных разделов присутствуют (заголовки §1–§9 проверены grep'ом); версии инструментов; до/после; матрица «дефект → слой проверки»; техдолг (7 пунктов) |

## Итоговые цифры

| Метрика | До | После |
| --- | --- | --- |
| Размер | 615 MB | **48 MB** (×12.8) |
| Слоёв | 13 | 6 |
| Холодная сборка | 97.1 s | 9.3 s |
| Тёплая пересборка | 46.3 s | **0.61–0.79 s** |
| Пользователь | root | app (uid 10001) |
| HEALTHCHECK | нет | есть |
| score.sh | 2/9* | **9/9** |
| trivy HIGH/CRIT | 571 | 51 (объяснены) |
| dive efficiency | 99.085 % | 99.998 % |

\* см. оговорку 1f.

## Вывод

Все обязательные пункты чек-листа выполнены: FAIL отсутствует,
два PASS_WITH_NOTE объяснены (состав проверок score для старого образа;
остаток trivy-находок как осознанный техдолг с планом закрытия).
Задание готово.
