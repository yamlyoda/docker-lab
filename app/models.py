from __future__ import annotations

from enum import StrEnum

from pydantic import BaseModel, Field


class LaunchStatus(StrEnum):
    SCHEDULED = "scheduled"
    COUNTDOWN = "countdown"
    HOLD = "hold"
    LAUNCHED = "launched"
    SCRUBBED = "scrubbed"


class Launch(BaseModel):
    id: str
    name: str
    vehicle: str
    pad: str
    window_utc: str
    status: LaunchStatus = LaunchStatus.SCHEDULED
    payload_kg: int = Field(ge=0)
    checks: dict[str, bool] = Field(default_factory=dict)


class CountdownResult(BaseModel):
    launch_id: str
    status: LaunchStatus
    t_minus_seconds: int
    go_for_launch: bool
    blockers: list[str] = Field(default_factory=list)


class HoldRequest(BaseModel):
    reason: str = Field(min_length=3, max_length=200)
