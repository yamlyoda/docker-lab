#!/usr/bin/env python3
"""Офлайн-аналитика по манифесту запусков.

Запускается вручную аналитиком, в рантайме сервиса не используется:

    uv run python tools/analyze_launches.py

Считает распределение массы полезной нагрузки по носителям и долю миссий,
готовых к отсчёту.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

DATA_FILE = Path(__file__).resolve().parent.parent / "app" / "data" / "launches.json"


def load_frame(path: Path = DATA_FILE) -> pd.DataFrame:
    raw = json.loads(path.read_text(encoding="utf-8"))
    frame = pd.DataFrame(raw["launches"])
    frame["go"] = frame["checks"].apply(lambda checks: all(checks.values()))
    return frame


def main() -> int:
    frame = load_frame()

    print("Полезная нагрузка по носителям (кг):")
    by_vehicle = frame.groupby("vehicle")["payload_kg"].agg(["count", "mean", "max"])
    print(by_vehicle.round(1).to_string())

    print()
    print(f"Всего миссий:       {len(frame)}")
    print(f"Готовы к отсчёту:   {int(frame['go'].sum())}")
    print(f"Медианная масса:    {np.median(frame['payload_kg']):.0f} кг")
    return 0


if __name__ == "__main__":
    sys.exit(main())
