# Launch Control API — оптимизированный образ
#
# Multi-stage: builder ставит зависимости из uv.lock в изолированный venv,
# runtime забирает только интерпретатор, venv и код приложения.
# Сборка: docker build -f Dockerfile.optimized -t launch-control:optimized .
#
# Обоснование выбора базовых образов: docs/base-image-decision.md

ARG PYTHON_IMAGE=python:3.12.14-slim@sha256:2c941e860699f878900b0edc2403613c234d4b32eda3cc9fa7036991a2a63c4a

# ---------------------------------------------------------------- builder ----
FROM ${PYTHON_IMAGE} AS builder

ARG UV_VERSION=0.12.5
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /build

# Сначала только манифесты зависимостей: слой кэшируется, правка кода
# не переустанавливает пакеты.
COPY pyproject.toml uv.lock ./

# Всё в одном слое: установка uv, экспорт зависимостей из лока, сборка venv
# и удаление инструментов сборки — иначе uv/pip остались бы в рантайме,
# а удаление отдельным слоем создало бы «мусор» для dive.
RUN pip install --no-cache-dir "uv==${UV_VERSION}" \
 && uv export --frozen --no-dev --no-emit-project -o requirements.txt \
 && uv venv /opt/venv \
 && VIRTUAL_ENV=/opt/venv uv pip install --no-cache -r requirements.txt \
 && rm requirements.txt \
 && pip uninstall --yes uv \
 && { pip uninstall --yes pip setuptools wheel 2>/dev/null || true; }

# ---------------------------------------------------------------- runtime ----
# Рантайм собирается на чистом debian-slim (у официального python:slim внутри
# слоёв остаётся мусор от apt/dpkg, что портит dive-efficiency). Интерпретатор
# переносится из builder одним слоем /usr/local.
FROM debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258 AS runtime

LABEL maintainer="platform-team@example.com"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    PORT=8000 \
    APP_ENV=production

# Не-root пользователь. Никаких apt в рантайме: базовый debian-slim уже
# содержит всё нужное CPython из builder-стадии (ssl/zlib/expat в базе,
# libffi не требуется кодом приложения — проверено smoke и тестами).
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --no-create-home app

WORKDIR /app

COPY --from=builder /usr/local /usr/local
COPY --from=builder /opt/venv /opt/venv
COPY app ./app

USER 10001:10001

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/health' % os.environ.get('PORT', '8000'), timeout=3)"]

# Exec-форма; sh нужен только для подстановки $PORT, exec заменяет sh
# процессом uvicorn, поэтому сигналы доходят до приложения без посредников.
CMD ["sh", "-c", "exec python -m uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
