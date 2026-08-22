# Launch Control API
#
# Собирается, работает, прошёл code review три релиза назад.
# С тех пор никто его не трогал.

FROM python:3.12

LABEL maintainer="platform-team@example.com"

WORKDIR /app

COPY . .

RUN apt-get update && apt-get install -y \
      build-essential \
      curl \
      git \
      vim \
      procps \
      net-tools

RUN pip install --upgrade pip
RUN pip install ".[dev]"

RUN python -m pytest -q

ENV PORT=8000
ENV APP_ENV=production
ENV ADMIN_TOKEN=launch-control-dev-token

EXPOSE 8000

CMD python -m uvicorn app.main:app --host 0.0.0.0 --port $PORT
