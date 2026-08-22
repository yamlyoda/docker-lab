"""Логика go/no-go перед стартом обратного отсчёта.

Вынесена отдельно от HTTP-слоя намеренно: это единственное место с настоящими
правилами, и оно должно тестироваться без поднятия приложения.
"""

from __future__ import annotations

from app.models import Launch, LaunchStatus

#: Критерии, каждый из которых должен быть True, чтобы уйти в отсчёт.
GO_CRITERIA: tuple[str, ...] = ("weather", "range_safety", "fuel", "telemetry")

#: Длительность штатного отсчёта, секунды.
NOMINAL_COUNTDOWN_SECONDS = 600

#: Масса, выше которой отсчёт удлиняется (тяжёлые миссии — больше проверок).
HEAVY_PAYLOAD_KG = 15_000


class CountdownError(RuntimeError):
    """Отсчёт запустить нельзя."""


def blockers_for(launch: Launch) -> list[str]:
    """Вернуть список невыполненных критериев в порядке из GO_CRITERIA."""
    return [name for name in GO_CRITERIA if not launch.checks.get(name, False)]


def countdown_length(launch: Launch) -> int:
    """Длительность отсчёта для конкретной миссии."""
    if launch.payload_kg >= HEAVY_PAYLOAD_KG:
        return NOMINAL_COUNTDOWN_SECONDS * 2
    return NOMINAL_COUNTDOWN_SECONDS


def start_countdown(launch: Launch) -> int:
    """Перевести миссию в отсчёт и вернуть T-minus в секундах.

    Бросает CountdownError, если статус не позволяет стартовать или
    есть невыполненные критерии.
    """
    if launch.status is LaunchStatus.LAUNCHED:
        raise CountdownError(f"Launch {launch.id} has already flown")
    if launch.status is LaunchStatus.SCRUBBED:
        raise CountdownError(f"Launch {launch.id} is scrubbed")

    blockers = blockers_for(launch)
    if blockers:
        raise CountdownError("no-go: " + ", ".join(blockers))

    launch.status = LaunchStatus.COUNTDOWN
    return countdown_length(launch)
