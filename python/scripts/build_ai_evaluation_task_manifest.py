"""Build the canonical schema-v7 AI-evaluation task manifest."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

try:
    from scripts.ai_evaluation_v7 import PROTOCOL_ID, SCHEMA_VERSION, task_manifest_id
except ModuleNotFoundError:  # Direct ``python python/scripts/...`` execution.
    from ai_evaluation_v7 import (  # type: ignore[no-redef]
        PROTOCOL_ID,
        SCHEMA_VERSION,
        task_manifest_id,
    )


def build_manifest(config: dict[str, Any]) -> dict[str, Any]:
    deck_keys = [str(value) for value in config.get("deck_keys") or []]
    return {
        "schema_version": SCHEMA_VERSION,
        "protocol_id": PROTOCOL_ID,
        "artifact_kind": "ai_evaluation_task_manifest",
        "task_manifest_id": task_manifest_id(deck_keys, config),
        "deck_keys": deck_keys,
        "schedule": config,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    config = json.loads(args.config.read_text(encoding="utf-8-sig"))
    if not isinstance(config, dict):
        raise ValueError("task manifest config must be an object")
    manifest = build_manifest(config)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(
        json.dumps(
            {
                "task_manifest": str(args.output),
                "task_manifest_id": manifest["task_manifest_id"],
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
