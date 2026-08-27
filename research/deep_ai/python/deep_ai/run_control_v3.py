"""Cooperative, recoverable run controls shared by v3 actors and learner."""
from __future__ import annotations

import time
from pathlib import Path
from typing import Callable


class TrainingCancelled(RuntimeError):
    pass


class RunControlV3:
    def __init__(
        self,
        run_dir: str | Path,
        *,
        status_callback: Callable[[str], None] | None = None,
    ) -> None:
        self.run_dir = Path(run_dir).resolve()
        self.pause_path = self.run_dir / "pause.request"
        self.cancel_path = self.run_dir / "cancel.request"
        self.status_callback = status_callback
        self._reported_paused = False

    def checkpoint(self) -> None:
        if self.cancel_path.exists():
            raise TrainingCancelled("deep_ai_v3_cancelled")
        while self.pause_path.exists():
            if not self._reported_paused:
                self._status("paused")
                self._reported_paused = True
            if self.cancel_path.exists():
                raise TrainingCancelled("deep_ai_v3_cancelled")
            time.sleep(0.25)
        if self._reported_paused:
            self._status("running")
            self._reported_paused = False

    def status(self, value: str) -> None:
        """Publish a control-visible state without exposing callback details."""
        self._status(value)

    def _status(self, value: str) -> None:
        if self.status_callback is not None:
            self.status_callback(str(value))
