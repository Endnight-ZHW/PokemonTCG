"""Build split simulation/analysis provenance for a schema-v7 AI evaluation."""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
import time
from pathlib import Path

try:
    from scripts.ai_evaluation_v7 import (
        PROTOCOL_ID,
        SCHEMA_VERSION,
        performance_host_fingerprint,
        simulation_fingerprint_from_provenance,
        source_fingerprint,
    )
except ModuleNotFoundError:  # Direct script execution.
    from ai_evaluation_v7 import (
        PROTOCOL_ID,
        SCHEMA_VERSION,
        performance_host_fingerprint,
        simulation_fingerprint_from_provenance,
        source_fingerprint,
    )


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


def _source_paths(
    repo_root: Path,
    *,
    target_platform: str = "",
) -> dict[str, list[Path]]:
    simulation_paths: set[Path] = set()
    analysis_paths: set[Path] = set()
    simulation_fixed = (
        repo_root / "release_manifest.json",
        repo_root / "tools" / "toolchain.lock.json",
        repo_root / "tools" / "evaluate_godot_ai.ps1",
        repo_root / ".github" / "workflows" / "verify.yml",
        repo_root / "godot" / "project.godot",
        repo_root / "godot" / "tools" / "ai_evaluation_runner.gd",
        repo_root / "python" / "scripts" / "build_ai_evaluation_task_manifest.py",
        repo_root / "python" / "scripts" / "inspect_ai_evaluation_checkpoints.py",
    )
    analysis_fixed = (
        repo_root / "python" / "scripts" / "ai_evaluation_v7.py",
        repo_root / "python" / "scripts" / "merge_ai_evaluation_shards.py",
        repo_root / "python" / "scripts" / "validate_ai_evaluation.py",
        repo_root / "python" / "scripts" / "render_ai_evaluation_report.py",
        repo_root / "python" / "scripts" / "build_ai_evaluation_provenance.py",
        repo_root / "python" / "scripts" / "summarize_ai_evaluation_profile.py",
        repo_root / "python" / "scripts" / "compare_ai_evaluation_profiles.py",
    )
    simulation_paths.update(path for path in simulation_fixed if path.is_file())
    analysis_paths.update(path for path in analysis_fixed if path.is_file())
    for relative in (
        "godot/ai",
        "godot/core",
        "godot/rules",
    ):
        root = repo_root / relative
        if root.is_dir():
            simulation_paths.update(path for path in root.rglob("*.gd") if path.is_file())
    native_root = repo_root / "godot" / "native" / "onnx_ai"
    if native_root.is_dir():
        simulation_paths.update(
            path for path in native_root.rglob("*") if path.is_file()
        )
    extension_descriptor = repo_root / "godot" / "bin" / "pokemon_ai.gdextension"
    if extension_descriptor.is_file():
        simulation_paths.add(extension_descriptor)
    normalized_platform = (target_platform or "").strip().lower()
    platform_binary_root = repo_root / "godot" / "bin" / normalized_platform
    if normalized_platform and platform_binary_root.is_dir():
        simulation_paths.update(
            path for path in platform_binary_root.rglob("*") if path.is_file()
        )
    baseline_root = repo_root / "godot" / "tools" / "ai_baseline"
    if baseline_root.is_dir():
        simulation_paths.update(
            path for path in baseline_root.rglob("*") if path.is_file()
        )
    data_root = repo_root / "godot" / "data"
    if data_root.is_dir():
        simulation_paths.update(path for path in data_root.glob("*.json") if path.is_file())
    key = lambda path: path.relative_to(repo_root).as_posix()
    return {
        "simulation": sorted(simulation_paths, key=key),
        "analysis": sorted(analysis_paths, key=key),
    }


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


def _file_sha256(path: Path | None) -> str:
    if path is None or not path.is_file():
        return ""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def current_analysis_provenance(repo_root: Path) -> dict[str, object]:
    """Describe only aggregation, validation and reporting implementation."""
    entries = [
        (
            path.relative_to(repo_root).as_posix(),
            path.read_bytes(),
        )
        for path in _source_paths(repo_root)["analysis"]
    ]
    stable: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "protocol_id": PROTOCOL_ID,
        "analysis_source_hash": source_fingerprint(entries),
    }
    stable["analysis_fingerprint"] = hashlib.sha256(
        json.dumps(
            stable,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    return stable


def current_analysis_fingerprint(repo_root: Path) -> str:
    return str(current_analysis_provenance(repo_root)["analysis_fingerprint"])


def build_provenance(
    repo_root: Path,
    strategy_paths: list[Path],
    *,
    godot_executable: Path | None = None,
    target_platform: str = "",
    simulation_config: dict[str, object] | None = None,
) -> dict[str, object]:
    entries: list[tuple[str, bytes]] = []
    simulation_entries: list[tuple[str, bytes]] = []
    analysis_entries: list[tuple[str, bytes]] = []
    component_entries: dict[str, list[tuple[str, bytes]]] = {
        "rules": [],
        "ai": [],
        "card_data": [],
        "evaluation_tool": [],
        "analysis_tool": [],
    }
    source_files: list[str] = []
    effective_target_platform = target_platform or platform.system().lower()
    grouped_paths = _source_paths(
        repo_root,
        target_platform=effective_target_platform,
    )
    for group, paths in grouped_paths.items():
        for path in paths:
            relative = path.relative_to(repo_root).as_posix()
            content = path.read_bytes()
            entry = (relative, content)
            entries.append(entry)
            if group == "simulation":
                simulation_entries.append(entry)
            else:
                analysis_entries.append(entry)
            if group == "analysis":
                component = "analysis_tool"
            elif relative.startswith(("godot/core/", "godot/rules/")):
                component = "rules"
            elif relative.startswith((
                "godot/ai/",
                "godot/native/",
                "godot/bin/",
            )):
                component = "ai"
            elif relative.startswith("godot/data/"):
                component = "card_data"
            else:
                component = "evaluation_tool"
            component_entries[component].append(entry)
            source_files.append(relative)
    strategy_hashes: dict[str, str] = {}
    for index, path in enumerate(strategy_paths):
        resolved = path.resolve()
        content = resolved.read_bytes()
        key = f"strategy-{index}:{resolved.name}"
        entries.append((key, content))
        simulation_entries.append((key, content))
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
    godot_executable_sha256 = _file_sha256(godot_executable)
    host: dict[str, object] = {
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "processor": platform.processor(),
        "python": platform.python_version(),
    }
    normalized_simulation_config = simulation_config or {}
    simulation_stable = {
        "schema_version": SCHEMA_VERSION,
        "protocol_id": PROTOCOL_ID,
        "simulation_source_hash": source_fingerprint(simulation_entries),
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
        "godot_executable_sha256": godot_executable_sha256,
        "target_platform": effective_target_platform,
        "simulation_config": normalized_simulation_config,
    }
    simulation_fingerprint = simulation_fingerprint_from_provenance(
        simulation_stable
    )
    analysis_stable = {
        "schema_version": SCHEMA_VERSION,
        "protocol_id": PROTOCOL_ID,
        "analysis_source_hash": source_fingerprint(analysis_entries),
    }
    analysis_fingerprint = current_analysis_fingerprint(repo_root)
    stable = {
        "schema_version": SCHEMA_VERSION,
        "protocol_id": PROTOCOL_ID,
        "source_hash": source_hash,
        "component_hashes": component_hashes,
        **simulation_stable,
        **analysis_stable,
        "simulation_fingerprint": simulation_fingerprint,
        "analysis_fingerprint": analysis_fingerprint,
        "git_commit": commit,
        "git_dirty": bool(status),
    }
    fingerprint = hashlib.sha256(
        json.dumps(
            {
                "schema_version": SCHEMA_VERSION,
                "protocol_id": PROTOCOL_ID,
                "simulation_fingerprint": simulation_fingerprint,
                "analysis_fingerprint": analysis_fingerprint,
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    return {
        **stable,
        "fingerprint": fingerprint,
        "source_file_count": len(source_files),
        "source_files": source_files,
        "host": host,
        "performance_host_fingerprint": performance_host_fingerprint(
            host,
            godot_runtime_version=godot_version,
            target_platform=effective_target_platform,
        ),
        "created_at_unix": int(time.time()),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path)
    parser.add_argument("--strategy", action="append", type=Path, default=[])
    parser.add_argument("--godot-executable", type=Path)
    parser.add_argument("--target-platform", default="")
    parser.add_argument(
        "--simulation-config",
        type=Path,
        help="JSON object binding schedule, rules and execution settings to the run.",
    )
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    repo_root = (args.repo_root or Path(__file__).resolve().parents[2]).resolve()
    strategy_paths = [path for path in args.strategy if path.is_file()]
    simulation_config: dict[str, object] = {}
    if args.simulation_config is not None:
        loaded = json.loads(args.simulation_config.read_text(encoding="utf-8-sig"))
        if not isinstance(loaded, dict):
            parser.error("--simulation-config must contain a JSON object")
        simulation_config = loaded
    payload = build_provenance(
        repo_root,
        strategy_paths,
        godot_executable=args.godot_executable,
        target_platform=args.target_platform,
        simulation_config=simulation_config,
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
