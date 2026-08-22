from __future__ import annotations

import time

from fastapi import FastAPI, HTTPException, Request

from app.countdown import CountdownError, blockers_for, start_countdown
from app.models import CountdownResult, HoldRequest, Launch, LaunchStatus
from app.storage import store

app = FastAPI(title="Launch Control", version="1.4.0")

_started_at = time.monotonic()
_counters: dict[str, int] = {"requests": 0, "countdowns": 0, "holds": 0, "no_go": 0}


@app.middleware("http")
async def count_requests(request: Request, call_next):  # type: ignore[no-untyped-def]
    _counters["requests"] += 1
    return await call_next(request)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "service": "launch-control"}


@app.get("/ready")
def ready() -> dict[str, bool]:
    if not store.ready:
        raise HTTPException(status_code=503, detail="launch manifest is not loaded")
    return {"ready": True}


@app.get("/api/v1/launches", response_model=list[Launch])
def list_launches(status: LaunchStatus | None = None) -> list[Launch]:
    launches = store.list()
    if status is not None:
        launches = [item for item in launches if item.status is status]
    return launches


@app.get("/api/v1/launches/{launch_id}", response_model=Launch)
def get_launch(launch_id: str) -> Launch:
    launch = store.get(launch_id)
    if launch is None:
        raise HTTPException(status_code=404, detail=f"launch {launch_id} not found")
    return launch


@app.post("/api/v1/launches/{launch_id}/countdown", response_model=CountdownResult)
def begin_countdown(launch_id: str) -> CountdownResult:
    launch = store.get(launch_id)
    if launch is None:
        raise HTTPException(status_code=404, detail=f"launch {launch_id} not found")

    try:
        t_minus = start_countdown(launch)
    except CountdownError as exc:
        _counters["no_go"] += 1
        raise HTTPException(status_code=409, detail=str(exc)) from exc

    _counters["countdowns"] += 1
    return CountdownResult(
        launch_id=launch.id,
        status=launch.status,
        t_minus_seconds=t_minus,
        go_for_launch=True,
    )


@app.post("/api/v1/launches/{launch_id}/hold", response_model=CountdownResult)
def hold_launch(launch_id: str, body: HoldRequest) -> CountdownResult:
    launch = store.get(launch_id)
    if launch is None:
        raise HTTPException(status_code=404, detail=f"launch {launch_id} not found")

    launch.status = LaunchStatus.HOLD
    _counters["holds"] += 1
    return CountdownResult(
        launch_id=launch.id,
        status=launch.status,
        t_minus_seconds=0,
        go_for_launch=False,
        blockers=blockers_for(launch) or [body.reason],
    )


@app.get("/internal/metrics")
def metrics() -> dict[str, float | int]:
    return {
        "uptime_seconds": round(time.monotonic() - _started_at, 1),
        "launches_total": len(store.list()),
        **_counters,
    }
