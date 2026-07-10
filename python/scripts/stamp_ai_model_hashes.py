"""Add or verify checkpoint SHA-256 identities in Deep AI sidecars."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


PYTHON_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODEL_DIR = PYTHON_ROOT / "data" / "ai_models"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stamp(model_dir: Path, *, check: bool) -> list[str]:
    stale: list[str] = []
    for model_path in sorted(model_dir.glob("*.pt")):
        if model_path.name.startswith("resume_"):
            continue
        sidecar_path = model_path.with_suffix(".json")
        if not sidecar_path.is_file():
            stale.append(sidecar_path.name)
            continue
        payload = json.loads(sidecar_path.read_text(encoding="utf-8"))
        actual = sha256(model_path)
        if str(payload.get("checkpoint_sha256") or "").lower() == actual:
            continue
        stale.append(sidecar_path.name)
        if not check:
            payload["checkpoint_sha256"] = actual
            sidecar_path.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
    return stale


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL_DIR)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    stale = stamp(args.model_dir.resolve(), check=args.check)
    if args.check and stale:
        print("Stale AI sidecar hashes: " + ", ".join(stale))
        return 1
    print(f"AI_MODEL_HASHES_OK updated={0 if args.check else len(stale)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
