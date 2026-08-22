from __future__ import annotations

import json
from pathlib import Path

from app.models import Launch

DATA_FILE = Path(__file__).parent / "data" / "launches.json"


class LaunchStore:
    """In-memory хранилище миссий, засеваемое из JSON при старте процесса."""

    def __init__(self, data_file: Path = DATA_FILE) -> None:
        self._data_file = data_file
        self._launches: dict[str, Launch] = {}
        self.reload()

    def reload(self) -> None:
        raw = json.loads(self._data_file.read_text(encoding="utf-8"))
        self._launches = {item["id"]: Launch(**item) for item in raw["launches"]}

    @property
    def ready(self) -> bool:
        return bool(self._launches)

    def list(self) -> list[Launch]:
        return sorted(self._launches.values(), key=lambda item: item.window_utc)

    def get(self, launch_id: str) -> Launch | None:
        return self._launches.get(launch_id)


store = LaunchStore()
