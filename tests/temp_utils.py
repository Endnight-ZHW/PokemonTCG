"""Shared temporary-file helpers for unittest modules."""
from __future__ import annotations

import os
import tempfile
import uuid
from contextlib import contextmanager
from typing import Iterator

_CAN_DELETE_FILES: bool | None = None


def _temp_root() -> str:
    root = os.path.join(os.path.dirname(__file__), ".tmp")
    os.makedirs(root, exist_ok=True)
    return root


@contextmanager
def temp_dir() -> Iterator[str]:
    if supports_file_delete():
        with tempfile.TemporaryDirectory(dir=_temp_root()) as path:
            yield path
        return

    path = os.path.join(_temp_root(), f"tmp-{uuid.uuid4().hex}")
    os.makedirs(path, exist_ok=False)
    yield path


def temp_file_path(prefix: str = "tmp", suffix: str = "") -> str:
    return os.path.join(_temp_root(), f"{prefix}-{uuid.uuid4().hex}{suffix}")


def best_effort_unlink(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def supports_file_delete() -> bool:
    global _CAN_DELETE_FILES
    if _CAN_DELETE_FILES is not None:
        return _CAN_DELETE_FILES
    path = temp_file_path(prefix="delete-probe", suffix=".tmp")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("probe")
    try:
        os.unlink(path)
    except OSError:
        _CAN_DELETE_FILES = False
    else:
        _CAN_DELETE_FILES = True
    return _CAN_DELETE_FILES
