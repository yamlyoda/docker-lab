from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.storage import store


@pytest.fixture(autouse=True)
def fresh_store() -> None:
    """Каждый тест видит исходный манифест: состояние живёт в памяти процесса."""
    store.reload()


@pytest.fixture
def client() -> TestClient:
    return TestClient(app)


def test_health(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_ready(client: TestClient) -> None:
    assert client.get("/ready").status_code == 200


def test_list_launches(client: TestClient) -> None:
    response = client.get("/api/v1/launches")
    assert response.status_code == 200
    body = response.json()
    assert len(body) == 5
    # отсортировано по окну запуска
    assert body[0]["id"] == "LC-105"


def test_filter_by_status(client: TestClient) -> None:
    response = client.get("/api/v1/launches", params={"status": "hold"})
    assert [item["id"] for item in response.json()] == ["LC-104"]


def test_get_unknown_launch(client: TestClient) -> None:
    assert client.get("/api/v1/launches/LC-000").status_code == 404


def test_countdown_happy_path(client: TestClient) -> None:
    response = client.post("/api/v1/launches/LC-101/countdown")
    assert response.status_code == 200
    body = response.json()
    assert body["go_for_launch"] is True
    assert body["t_minus_seconds"] == 600
    assert body["status"] == "countdown"


def test_countdown_blocked_by_weather(client: TestClient) -> None:
    response = client.post("/api/v1/launches/LC-102/countdown")
    assert response.status_code == 409
    assert "weather" in response.json()["detail"]


def test_countdown_rejected_for_flown_mission(client: TestClient) -> None:
    response = client.post("/api/v1/launches/LC-105/countdown")
    assert response.status_code == 409


def test_hold_sets_status_and_reason(client: TestClient) -> None:
    response = client.post(
        "/api/v1/launches/LC-101/hold", json={"reason": "upper stage telemetry dropout"}
    )
    assert response.status_code == 200
    assert response.json()["status"] == "hold"


def test_metrics_expose_counters(client: TestClient) -> None:
    client.get("/health")
    body = client.get("/internal/metrics").json()
    assert body["launches_total"] == 5
    assert body["requests"] >= 1
