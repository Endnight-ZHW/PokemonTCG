"""Build-input hashing and sidecar validation for Native Challenge Arena."""
from __future__ import annotations

import hashlib
import json
import os
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


BINDING_BUILD_SCHEMA = "ptcg.challenge_arena.binding_build/1"
AGENT_BUILD_SCHEMA = "ptcg.challenge_arena.agent_build/1"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_hash(value: Any) -> str:
    return hashlib.sha256(json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")).hexdigest()


def _manifest_sources(source_root: Path, component: str) -> list[Path]:
    component_root = source_root / "native" / component
    manifest = json.loads(
        (component_root / "source_manifest.json").read_text(encoding="utf-8")
    )
    paths = [component_root / "source_manifest.json"]
    paths.extend(component_root / "src" / name for name in manifest["runtime"])
    paths.extend(sorted((component_root / "src").rglob("*.hpp")))
    paths.extend(sorted((source_root / "native" / "common").glob("*.hpp")))
    return paths


def _input_rows(paths: Iterable[Path], roots: Iterable[Path]) -> list[dict[str, str]]:
    normalized_roots = [root.resolve() for root in roots]
    rows = []
    for path in sorted({entry.resolve() for entry in paths}, key=str):
        relative = None
        for root in normalized_roots:
            try:
                relative = path.relative_to(root).as_posix()
                break
            except ValueError:
                continue
        rows.append({
            "path": relative or path.name,
            "sha256": sha256_file(path),
        })
    return rows


def _git_state(root: Path) -> dict[str, Any]:
    def command(*arguments: str) -> str:
        try:
            return subprocess.check_output(
                ("git", "-C", str(root), *arguments),
                text=True,
                encoding="utf-8",
                errors="replace",
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            return ""

    return {
        "commit": command("rev-parse", "HEAD"),
        "dirty": bool(command("status", "--porcelain")),
    }


def agent_input_manifest(
    repo_root: Path,
    source_root: Path,
    *,
    compiler: str = "",
) -> dict[str, Any]:
    repo_root = repo_root.resolve()
    source_root = source_root.resolve()
    driver_root = repo_root / "research" / "deep_ai" / "native" / "agent"
    rules_paths = _manifest_sources(source_root, "ptcg_core")
    challenge_paths = _manifest_sources(source_root, "challenge_core")
    driver_paths = [
        driver_root / "ptcg_challenge_agent_main.cpp",
        driver_root / "SConstruct",
        repo_root / "native" / "common" / "ptcg_json_adapter.hpp",
    ]
    build_tool_paths = [
        repo_root / "tools" / "toolchain_common.ps1",
        repo_root / "research" / "deep_ai" / "tools" / "build_challenge_agent.ps1",
        repo_root / "research" / "deep_ai" / "scripts" / "challenge_arena_build.py",
        repo_root / "research" / "deep_ai" / "python" / "deep_ai"
        / "challenge_arena_build.py",
    ]
    paths = [*rules_paths, *challenge_paths, *driver_paths]
    rows = _input_rows(paths, (source_root, repo_root))
    implementation = {
        "contract": "ptcg.challenge_arena.agent_build_inputs/1",
        "platform": "windows-x86_64" if os.name == "nt" else platform.system().lower(),
        "configuration": "optimized-cxx17",
        "rules_source_hash": _canonical_hash(
            _input_rows(rules_paths, (source_root, repo_root))
        ),
        "challenge_source_hash": _canonical_hash(
            _input_rows(challenge_paths, (source_root, repo_root))
        ),
        "driver_source_hash": _canonical_hash(
            _input_rows(driver_paths, (source_root, repo_root))
        ),
        "files": rows,
    }
    implementation_hash = _canonical_hash(implementation)
    strategies_path = source_root / "godot" / "data" / "ai_strategies.json"
    build_inputs = {
        "implementation_hash": implementation_hash,
        "strategies_sha256": sha256_file(strategies_path),
        "compiler": compiler or platform.python_compiler(),
        "build_tool_source_hash": _canonical_hash(
            _input_rows(build_tool_paths, (repo_root,))
        ),
    }
    return {
        **implementation,
        "implementation_hash": implementation_hash,
        "strategies_input_sha256": build_inputs["strategies_sha256"],
        "compiler": build_inputs["compiler"],
        "build_tool_source_hash": build_inputs["build_tool_source_hash"],
        "build_tool_files": _input_rows(build_tool_paths, (repo_root,)),
        "build_input_hash": _canonical_hash(build_inputs),
    }


def binding_input_manifest(
    repo_root: Path,
    *,
    compiler: str = "",
) -> dict[str, Any]:
    repo_root = repo_root.resolve()
    research_native = repo_root / "research" / "deep_ai" / "native"
    rules_paths = _manifest_sources(repo_root, "ptcg_core")
    challenge_paths = _manifest_sources(repo_root, "challenge_core")
    arena_paths = [
        research_native / "python" / "SConstruct",
        research_native / "python" / "ptcg_ai_core_module.cpp",
        *sorted((research_native / "src").glob("*.cpp")),
        *sorted((research_native / "src").glob("*.hpp")),
    ]
    paths = [*rules_paths, *challenge_paths, *arena_paths]
    rows = _input_rows(paths, (repo_root,))
    payload = {
        "contract": "ptcg.challenge_arena.binding_build_inputs/1",
        "platform": platform.platform(),
        "python": platform.python_version(),
        "python_compiler": platform.python_compiler(),
        "compiler": compiler or platform.python_compiler(),
        "configuration": "optimized-cxx17",
        "rules_source_hash": _canonical_hash(_input_rows(rules_paths, (repo_root,))),
        "challenge_source_hash": _canonical_hash(
            _input_rows(challenge_paths, (repo_root,))
        ),
        "arena_source_hash": _canonical_hash(_input_rows(arena_paths, (repo_root,))),
        "files": rows,
    }
    return {**payload, "input_hash": _canonical_hash(payload)}


def _mtime_utc(path: Path) -> str:
    return datetime.fromtimestamp(
        path.stat().st_mtime, tz=timezone.utc
    ).isoformat().replace("+00:00", "Z")


def write_json_atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".tmp-{os.getpid()}")
    with temporary.open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def write_binding_sidecar(
    repo_root: Path,
    binding: Path,
    output: Path,
    *,
    compiler: str = "",
) -> dict[str, Any]:
    inputs = binding_input_manifest(repo_root, compiler=compiler)
    result = {
        "schema": BINDING_BUILD_SCHEMA,
        "binding_path": str(binding.resolve()),
        "binding_sha256": sha256_file(binding),
        "binding_mtime_utc": _mtime_utc(binding),
        "compiler": inputs["compiler"],
        "input_hash": inputs["input_hash"],
        "inputs": inputs,
        "git": _git_state(repo_root),
    }
    write_json_atomic(output, result)
    return result


def write_agent_sidecar(
    repo_root: Path,
    source_root: Path,
    executable: Path,
    strategies: Path,
    output: Path,
    *,
    git_ref: str,
    build_id: str,
    compiler: str = "",
) -> dict[str, Any]:
    inputs = agent_input_manifest(
        repo_root, source_root, compiler=compiler
    )
    result = {
        "schema": AGENT_BUILD_SCHEMA,
        "protocol": "ptcg.challenge_agent.ipc/1",
        "git_ref": git_ref,
        "build_id": build_id,
        "build_input_hash": inputs["build_input_hash"],
        "compiler": inputs["compiler"],
        "implementation_hash": inputs["implementation_hash"],
        "executable_path": str(executable.resolve()),
        "executable_sha256": sha256_file(executable),
        "executable_mtime_utc": _mtime_utc(executable),
        "strategies_path": str(strategies.resolve()),
        "strategies_sha256": sha256_file(strategies),
        "inputs": inputs,
        "source_git": _git_state(source_root),
        "driver_git": _git_state(repo_root),
    }
    write_json_atomic(output, result)
    return result


def load_and_verify_binding(repo_root: Path, binding: Path, sidecar: Path) -> dict[str, Any]:
    if not binding.is_file() or not sidecar.is_file():
        raise RuntimeError("arena_native_binding_or_sidecar_missing")
    value = json.loads(sidecar.read_text(encoding="utf-8"))
    if value.get("schema") != BINDING_BUILD_SCHEMA:
        raise RuntimeError("arena_native_binding_sidecar_schema_mismatch")
    if Path(str(value.get("binding_path", ""))).resolve() != binding.resolve():
        raise RuntimeError("arena_native_binding_path_mismatch")
    if value.get("binding_sha256") != sha256_file(binding):
        raise RuntimeError("arena_native_binding_sha256_mismatch")
    current = binding_input_manifest(
        repo_root, compiler=str(value.get("compiler", ""))
    )
    if value.get("input_hash") != current["input_hash"]:
        raise RuntimeError("arena_native_binding_is_stale")
    return value


def load_and_verify_agent(sidecar: Path) -> dict[str, Any]:
    if not sidecar.is_file():
        raise RuntimeError("arena_agent_sidecar_missing")
    value = json.loads(sidecar.read_text(encoding="utf-8"))
    if value.get("schema") != AGENT_BUILD_SCHEMA:
        raise RuntimeError("arena_agent_sidecar_schema_mismatch")
    if value.get("protocol") != "ptcg.challenge_agent.ipc/1":
        raise RuntimeError("arena_agent_protocol_mismatch")
    inputs = value.get("inputs", {})
    if not isinstance(inputs, dict) or (
        value.get("implementation_hash") != inputs.get("implementation_hash")
        or value.get("build_input_hash") != inputs.get("build_input_hash")
    ):
        raise RuntimeError("arena_agent_build_input_mismatch")
    implementation = {
        key: inputs.get(key)
        for key in (
            "contract",
            "platform",
            "configuration",
            "rules_source_hash",
            "challenge_source_hash",
            "driver_source_hash",
            "files",
        )
    }
    if _canonical_hash(implementation) != inputs.get("implementation_hash"):
        raise RuntimeError("arena_agent_implementation_hash_mismatch")
    expected_build_hash = _canonical_hash({
        "implementation_hash": inputs.get("implementation_hash"),
        "strategies_sha256": inputs.get("strategies_input_sha256"),
        "compiler": inputs.get("compiler"),
        "build_tool_source_hash": inputs.get("build_tool_source_hash"),
    })
    if expected_build_hash != inputs.get("build_input_hash"):
        raise RuntimeError("arena_agent_cache_hash_mismatch")
    executable = Path(str(value.get("executable_path", "")))
    strategies = Path(str(value.get("strategies_path", "")))
    if not executable.is_file() or sha256_file(executable) != value.get("executable_sha256"):
        raise RuntimeError("arena_agent_executable_sha256_mismatch")
    if not strategies.is_file() or sha256_file(strategies) != value.get("strategies_sha256"):
        raise RuntimeError("arena_agent_strategies_sha256_mismatch")
    if value.get("strategies_sha256") != inputs.get("strategies_input_sha256"):
        raise RuntimeError("arena_agent_frozen_strategy_input_mismatch")
    return value
