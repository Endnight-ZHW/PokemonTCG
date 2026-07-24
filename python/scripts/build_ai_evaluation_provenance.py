"""Build deterministic provenance for a schema-v6 Godot AI evaluation run."""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
import time
from pathlib import Path

try:
    from scripts.ai_evaluation_v6 import SCHEMA_VERSION, source_fingerprint
except ModuleNotFoundError:  # Direct script execution.
    from ai_evaluation_v6 import SCHEMA_VERSION, source_fingerprint


def _git(repo_root: Path, *args: str) -> str:
    try:
        completed = subprocess.run(
            ["git", *args],
            cwd=repo_root,
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    except (OSError, subprocess.CalledProcessError):
        return ""
    return completed.stdout.strip()


def _source_paths(repo_root: Path) -> list[Path]:
    paths: set[Path] = set()
    fixed = (
        repo_root / "release_manifest.json",
        repo_root / "tools" / "toolchain.lock.json",
        repo_root / "tools" / "evaluate_godot_ai.ps1",
        repo_root / "godot" / "project.godot",
        repo_root / "godot" / "tools" / "ai_evaluation_runner.gd",
        repo_root / "python" / "scripts" / "ai_evaluation_v6.py",
        repo_root / "python" / "scripts" / "merge_ai_evaluation_shards.py",
        repo_root / "python" / "scripts" / "validate_ai_evaluation.py",
        repo_root / "python" / "scripts" / "render_ai_evaluation_report.py",
        repo_root / "python" / "scripts" / "build_ai_evaluation_provenance.py",
    )
    paths.update(path for path in fixed if path.is_file())
    for relative in (
        "godot/ai",
        "godot/core",
        "godot/rules",
        "godot/tools/ai_baseline",
    ):
        root = repo_root / relative
        if root.is_dir():
            paths.update(path for path in root.rglob("*.gd") if path.is_file())
    data_root = repo_root / "godot" / "data"
    if data_root.is_dir():
        paths.update(path for path in data_root.glob("*.json") if path.is_file())
    return sorted(paths, key=lambda path: path.relative_to(repo_root).as_posix())


def _json_object(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def _executable_version(path: Path | None) -> str:
    if path is None or not path.is_file():
        return ""
    try:
        completed = subprocess.run(
            [str(path), "--version"],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    except (OSError, subprocess.CalledProcessError):
        return ""
    return (completed.stdout or completed.stderr).strip().splitlines()[0]


def build_provenance(
    repo_root: Path,
    strategy_paths: list[Path],
    *,
    godot_executable: Path | None = None,
    target_platform: str = "",
) -> dict[str, object]:
    entries: list[tuple[str, bytes]] = []
    component_entries: dict[str, list[tuple[str, bytes]]] = {
        "rules": [],
        "ai": [],
        "card_data": [],
        "evaluation_tool": [],
    }
    source_files: list[str] = []
    for path in _source_paths(repo_root):
        relative = path.relative_to(repo_root).as_posix()
        content = path.read_bytes()
        entries.append((relative, content))
        if relative.startswith(("godot/core/", "godot/rules/")):
            component = "rules"
        elif relative.startswith("godot/ai/"):
            component = "ai"
        elif relative.startswith("godot/data/"):
            component = "card_data"
        else:
            component = "evaluation_tool"
        component_entries[component].append((relative, content))
        source_files.append(relative)
    strategy_hashes: dict[str, str] = {}
    for index, path in enumerate(strategy_paths):
        resolved = path.resolve()
        content = resolved.read_bytes()
        key = f"strategy-{index}:{resolved.name}"
        entries.append((key, content))
        component_entries["ai"].append((key, content))
        strategy_hashes[str(index)] = hashlib.sha256(content).hexdigest()

    source_hash = source_fingerprint(entries)
    component_hashes = {
        key: source_fingerprint(values) if values else ""
        for key, values in component_entries.items()
    }
    commit = _git(repo_root, "rev-parse", "HEAD")
    status = _git(repo_root, "status", "--porcelain", "--untracked-files=no")
    release_path = repo_root / "release_manifest.json"
    toolchain_path = repo_root / "tools" / "toolchain.lock.json"
    release = _json_object(release_path)
    toolchain = _json_object(toolchain_path)
    godot_version = _executable_version(godot_executable)
    stable = {
        "schema_version": SCHEMA_VERSION,
        "source_hash": source_hash,
        "component_hashes": component_hashes,
        "release_manifest_sha256": (
            hashlib.sha256(release_path.read_bytes()).hexdigest()
            if release_path.is_file()
            else ""
        ),
        "toolchain_lock_sha256": (
            hashlib.sha256(toolchain_path.read_bytes()).hexdigest()
            if toolchain_path.is_file()
            else ""
        ),
        "strategy_file_sha256": strategy_hashes,
        "product_version": str(release.get("version") or ""),
        "release_ai_evaluation_schema": int(
            (release.get("schemas") or {}).get("ai_evaluation", 0)
            if isinstance(release.get("schemas"), dict)
            else 0
        ),
        "release_godot_version": str(release.get("godot_version") or ""),
        "toolchain_godot_version": str(
            (toolchain.get("godot") or {}).get("full_config")
            if isinstance(toolchain.get("godot"), dict)
            else ""
        ),
        "godot_runtime_version": godot_version,
        "target_platform": target_platform or platform.system().lower(),
        "git_commit": commit,
        "git_dirty": bool(status),
    }
    fingerprint = hashlib.sha256(
        json.dumps(stable, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return {
        **stable,
        "fingerprint": fingerprint,
        "source_file_count": len(source_files),
        "source_files": source_files,
        "host": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "processor": platform.processor(),
            "python": platform.python_version(),
        },
        "created_at_unix": int(time.time()),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path)
    parser.add_argument("--strategy", action="append", type=Path, default=[])
    parser.add_argument("--godot-executable", type=Path)
    parser.add_argument("--target-platform", default="")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    repo_root = (args.repo_root or Path(__file__).resolve().parents[2]).resolve()
    strategy_paths = [path for path in args.strategy if path.is_file()]
    payload = build_provenance(
        repo_root,
        strategy_paths,
        godot_executable=args.godot_executable,
        target_platform=args.target_platform,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps({"provenance": str(args.output), "fingerprint": payload["fingerprint"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
