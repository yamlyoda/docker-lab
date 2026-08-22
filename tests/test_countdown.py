from __future__ import annotations

import pytest

from app.countdown import (
    HEAVY_PAYLOAD_KG,
    NOMINAL_COUNTDOWN_SECONDS,
    CountdownError,
    blockers_for,
    countdown_length,
    start_countdown,
)
from app.models import Launch, LaunchStatus

ALL_GO = {"weather": True, "range_safety": True, "fuel": True, "telemetry": True}


def make_launch(**overrides: object) -> Launch:
    base = {
        "id": "LC-999",
        "name": "Test Article",
        "vehicle": "Falcon-9",
        "pad": "LC-39A",
        "window_utc": "2026-08-02T04:15:00Z",
        "status": LaunchStatus.SCHEDULED,
        "payload_kg": 1000,
        "checks": dict(ALL_GO),
    }
    base.update(overrides)
    return Launch(**base)  # type: ignore[arg-type]


def test_all_criteria_green_means_no_blockers() -> None:
    assert blockers_for(make_launch()) == []


def test_blockers_preserve_declared_order() -> None:
    launch = make_launch(checks={**ALL_GO, "telemetry": False, "weather": False})
    assert blockers_for(launch) == ["weather", "telemetry"]


def test_missing_criterion_counts_as_no_go() -> None:
    launch = make_launch(checks={"weather": True})
    assert blockers_for(launch) == ["range_safety", "fuel", "telemetry"]


def test_countdown_starts_and_changes_status() -> None:
    launch = make_launch()
    assert start_countdown(launch) == NOMINAL_COUNTDOWN_SECONDS
    assert launch.status is LaunchStatus.COUNTDOWN


def test_heavy_payload_gets_longer_countdown() -> None:
    launch = make_launch(payload_kg=HEAVY_PAYLOAD_KG)
    assert countdown_length(launch) == NOMINAL_COUNTDOWN_SECONDS * 2


def test_countdown_rejected_when_no_go() -> None:
    launch = make_launch(checks={**ALL_GO, "fuel": False})
    with pytest.raises(CountdownError, match="fuel"):
        start_countdown(launch)
    assert launch.status is LaunchStatus.SCHEDULED


def test_countdown_rejected_after_flight() -> None:
    launch = make_launch(status=LaunchStatus.LAUNCHED)
    with pytest.raises(CountdownError, match="already flown"):
        start_countdown(launch)
