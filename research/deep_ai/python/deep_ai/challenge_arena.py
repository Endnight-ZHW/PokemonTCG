"""Native, callback-free Challenge-vs-Challenge evaluation orchestration."""
from __future__ import annotations

import json
import os
import platform
import subprocess
import sys
import time
from collections import Counter
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from .challenge_arena_build import (
    load_and_verify_agent,
    load_and_verify_binding,
    sha256_file,
    write_json_atomic,
)
from .challenge_arena_stats import gate_status, summarize_games
from .challenge_arena_store import ChallengeArenaRunStore, write_jsonl_atomic
from .challenge_arena_retry import TimeoutRetryJournal
from .evaluation_fairness import (
    SEAT_FIRST_PLAYER_CLOSURES,
    block_kind,
    canonical_hash,
    paired_seed,
)
from .v3_contract import RELEASE_DECKS
from engine.native_state_codec import native_catalog_payload


ARENA_SCHEMA = "ptcg.native_challenge_arena/3"
MANIFEST_SCHEMA = "ptcg.challenge_arena.manifest/3"
RESEARCH_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = Path(__file__).resolve().parents[4]
PRODUCT_DECKS = REPO_ROOT / "godot" / "data" / "decks.json"
PRODUCT_STRATEGIES = REPO_ROOT / "godot" / "data" / "ai_strategies.json"
BASELINES_ROOT = RESEARCH_ROOT / "arena" / "baselines"
PRESET_REPLICATES = {
    "smoke": 1,
    "pr": 2,
    "nightly": 30,
    "release": 50,
    "calibration": 20,
    "focused": 1,
}


def _read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected_json_object:{path}")
    return value


def reporting_code_info() -> dict[str, Any]:
    paths = (
        Path(__file__).resolve(),
        Path(__file__).with_name("challenge_arena_stats.py").resolve(),
        Path(__file__).with_name("challenge_arena_retry.py").resolve(),
        Path(__file__).with_name("evaluation_fairness.py").resolve(),
        Path(__file__).with_name("challenge_arena_store.py").resolve(),
        Path(__file__).with_name("challenge_arena_build.py").resolve(),
        RESEARCH_ROOT / "scripts" / "run_challenge_arena.py",
        RESEARCH_ROOT / "tools" / "run_challenge_arena.ps1",
    )
    files = [
        {
            "path": path.relative_to(REPO_ROOT).as_posix(),
            "sha256": sha256_file(path),
        }
        for path in paths
    ]
    return {
        "schema": "ptcg.challenge_arena.reporting_code/1",
        "files": files,
        "hash": canonical_hash(files),
    }


@dataclass(frozen=True, slots=True)
class ArenaAgentSpec:
    agent_id: str
    build_id: str
    strategies: Mapping[str, Any]
    evaluation_options: Mapping[str, Any] = field(default_factory=dict)
    source: str = ""
    backend: str = "in_process"
    implementation_hash: str = ""
    executable_path: str = ""
    process_config_path: str = ""
    process_log_directory: str = ""
    decision_timeout_milliseconds: int = 120000
    build_manifest: Mapping[str, Any] = field(default_factory=dict)

    def validate(self) -> None:
        if not self.agent_id.strip():
            raise ValueError("arena_agent_id_empty")
        if not isinstance(self.strategies, Mapping) or not self.strategies:
            raise ValueError(f"arena_agent_strategies_empty:{self.agent_id}")
        if not isinstance(self.evaluation_options, Mapping):
            raise ValueError(f"arena_agent_options_invalid:{self.agent_id}")
        if self.backend not in {"in_process", "external_process"}:
            raise ValueError(f"arena_agent_backend_invalid:{self.agent_id}")
        if int(self.decision_timeout_milliseconds) <= 0:
            raise ValueError(f"arena_agent_watchdog_invalid:{self.agent_id}")
        if self.backend == "external_process" and (
            not self.implementation_hash
            or not self.executable_path
            or not self.process_config_path
        ):
            raise ValueError(f"arena_external_agent_incomplete:{self.agent_id}")

    def native_payload(self) -> dict[str, Any]:
        self.validate()
        return {
            "agent_id": self.agent_id,
            "build_id": self.build_id,
            "backend": self.backend,
            "implementation_hash": self.implementation_hash,
            "strategy_hash": canonical_hash(self.strategies),
            "executable_path": self.executable_path,
            "process_config_path": self.process_config_path,
            "process_log_directory": self.process_log_directory,
            "decision_timeout_milliseconds": self.decision_timeout_milliseconds,
            "strategies": dict(self.strategies),
            "evaluation_options": dict(self.evaluation_options),
        }


@dataclass(frozen=True, slots=True)
class ArenaTask:
    task_id: str
    candidate_deck: str
    baseline_deck: str
    game_seed: int
    candidate_seat: int
    first_player: int
    max_decisions: int = 512
    block_id: str = ""
    block_size: int = 0
    block_kind: str = ""
    replicate: int = 0
    closure: int = 0

    def native_payload(self) -> dict[str, Any]:
        return {
            "task_id": self.task_id,
            "candidate_deck": self.candidate_deck,
            "baseline_deck": self.baseline_deck,
            "game_seed": self.game_seed,
            "candidate_seat": self.candidate_seat,
            "first_player": self.first_player,
            "max_decisions": self.max_decisions,
        }


def _pr_matchups(decks: Sequence[str]) -> list[tuple[str, str]]:
    mirrors = [(deck, deck) for deck in decks]
    paired: list[tuple[str, str]] = []
    for index in range(0, len(decks), 2):
        left = decks[index]
        right = decks[(index + 1) % len(decks)]
        paired.extend(((left, right), (right, left)))
    return mirrors + paired


def preset_matchups(
    preset: str,
    *,
    candidate_decks: Sequence[str] = (),
    baseline_decks: Sequence[str] = (),
    mirror_only: bool = False,
) -> list[tuple[str, str]]:
    decks = tuple(str(value) for value in RELEASE_DECKS)
    if mirror_only:
        if preset != "focused":
            raise ValueError("challenge_arena_mirror_only_requires_focused")
        candidates = tuple(str(value) for value in candidate_decks) or decks
        baselines = tuple(str(value) for value in baseline_decks) or decks
        if (
            len(set(candidates)) != len(candidates)
            or len(set(baselines)) != len(baselines)
            or set(candidates) != set(baselines)
        ):
            raise ValueError("challenge_arena_mirror_decks_must_match")
        return [(deck, deck) for deck in candidates]
    if preset == "smoke":
        return [
            ("fire", "water"),
            ("psychic", "lightning"),
            ("fighting", "colorless"),
            ("dragon", "grass"),
        ]
    if preset == "pr":
        return _pr_matchups(decks)
    if preset in {"nightly", "release", "calibration"}:
        return [(candidate, baseline) for candidate in decks for baseline in decks]
    if preset == "focused":
        candidates = tuple(candidate_decks) or decks
        baselines = tuple(baseline_decks) or decks
        return [
            (str(candidate), str(baseline))
            for candidate in candidates
            for baseline in baselines
        ]
    raise ValueError(f"unknown_challenge_arena_preset:{preset}")


def pair_game_seed(
    base_seed: int,
    candidate_deck: str,
    baseline_deck: str,
    replicate: int,
) -> int:
    return paired_seed(
        base_seed,
        candidate_deck,
        baseline_deck,
        replicate,
        namespace="ptcg.challenge_arena.pair_seed/2",
    )


def generate_tasks(
    preset: str,
    *,
    seed: int = 17,
    replicates: int | None = None,
    max_decisions: int = 512,
    candidate_decks: Sequence[str] = (),
    baseline_decks: Sequence[str] = (),
    mirror_only: bool = False,
) -> list[ArenaTask]:
    if max_decisions <= 0:
        raise ValueError("arena_max_decisions_must_be_positive")
    if preset not in PRESET_REPLICATES:
        raise ValueError(f"unknown_challenge_arena_preset:{preset}")
    count = PRESET_REPLICATES[preset] if replicates is None else int(replicates)
    if count <= 0:
        raise ValueError("arena_replicates_must_be_positive")
    matchups = preset_matchups(
        preset,
        candidate_decks=candidate_decks,
        baseline_decks=baseline_decks,
        mirror_only=mirror_only,
    )
    tasks: list[ArenaTask] = []
    for replicate in range(count):
        for candidate_deck, baseline_deck in matchups:
            pair = tuple(sorted((candidate_deck, baseline_deck)))
            game_seed = pair_game_seed(
                seed, candidate_deck, baseline_deck, replicate
            )
            unordered = "__".join(pair)
            block_id = f"{unordered}:seed-{game_seed}:rep-{replicate}"
            for closure, (candidate_seat, first_player) in enumerate(
                SEAT_FIRST_PLAYER_CLOSURES
            ):
                task_id = (
                    f"{preset}:r{replicate}:{candidate_deck}-vs-"
                    f"{baseline_deck}:c{closure}"
                )
                tasks.append(ArenaTask(
                    task_id=task_id,
                    candidate_deck=candidate_deck,
                    baseline_deck=baseline_deck,
                    game_seed=game_seed,
                    candidate_seat=candidate_seat,
                    first_player=first_player,
                    max_decisions=int(max_decisions),
                    block_id=block_id,
                    block_kind=block_kind(candidate_deck, baseline_deck),
                    replicate=replicate,
                    closure=closure,
                ))
    block_sizes = Counter(task.block_id for task in tasks)
    tasks = [
        replace(task, block_size=int(block_sizes[task.block_id]))
        for task in tasks
    ]
    validate_task_matrix(tasks)
    return tasks


def validate_task_matrix(tasks: Sequence[ArenaTask]) -> None:
    if not tasks:
        raise ValueError("challenge_arena_tasks_empty")
    identifiers = [task.task_id for task in tasks]
    if len(identifiers) != len(set(identifiers)):
        raise ValueError("duplicate_challenge_arena_task_id")
    closures: dict[tuple[str, str, int, int], set[tuple[int, int]]] = {}
    for task in tasks:
        if task.candidate_seat not in (0, 1) or task.first_player not in (0, 1):
            raise ValueError(f"invalid_challenge_arena_closure:{task.task_id}")
        key = (
            task.candidate_deck,
            task.baseline_deck,
            task.game_seed,
            task.replicate,
        )
        closures.setdefault(key, set()).add((task.candidate_seat, task.first_player))
    expected = set(SEAT_FIRST_PLAYER_CLOSURES)
    incomplete = [key for key, values in closures.items() if values != expected]
    if incomplete:
        raise ValueError(f"incomplete_challenge_arena_closure:{incomplete[0]}")
    observed_block_sizes = Counter(task.block_id for task in tasks)
    invalid_blocks = [
        task.block_id
        for task in tasks
        if (
            not task.block_id
            or task.block_size != observed_block_sizes[task.block_id]
            or task.block_kind not in {"mirror", "cross_deck"}
        )
    ]
    if invalid_blocks:
        raise ValueError(f"invalid_challenge_arena_block:{invalid_blocks[0]}")


def load_product_payloads() -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    return native_catalog_payload(), _read_json(PRODUCT_DECKS), _read_json(
        PRODUCT_STRATEGIES
    )


def _resolve_spec_path(identifier: str) -> Path | None:
    direct = Path(identifier)
    if direct.is_file():
        return direct.resolve()
    baseline = BASELINES_ROOT / f"{identifier}.json"
    return baseline.resolve() if baseline.is_file() else None


def load_agent_spec(
    identifier: str,
    *,
    product_strategies: Mapping[str, Any] | None = None,
    default_build_id: str = "working-tree",
    build_manifest: Path | None = None,
) -> ArenaAgentSpec:
    strategies = dict(product_strategies or _read_json(PRODUCT_STRATEGIES))
    built: dict[str, Any] = {}
    if build_manifest is not None:
        built = load_and_verify_agent(build_manifest)
        strategies = _read_json(Path(str(built["strategies_path"])))
    path = _resolve_spec_path(identifier)
    if path is None:
        return ArenaAgentSpec(
            agent_id=str(identifier),
            build_id=default_build_id,
            strategies=strategies,
            evaluation_options={
                "engine": "turn_beam_v2",
                "node_budget": 192,
                "belief_samples": 3,
            },
            source="product-default",
            backend="external_process" if built else "in_process",
            implementation_hash=str(built.get("implementation_hash", "")),
            executable_path=str(built.get("executable_path", "")),
            build_manifest=built,
        )
    raw = _read_json(path)
    if raw.get("schema") != "ptcg.challenge_arena.agent/2":
        raise ValueError(f"arena_agent_spec_schema_mismatch:{path}")
    pinned_ref = str(raw.get("git_ref", ""))
    if pinned_ref and (
        len(pinned_ref) != 40
        or any(character not in "0123456789abcdefABCDEF" for character in pinned_ref)
    ):
        raise ValueError(f"arena_agent_git_ref_not_full_commit:{path}")
    if built and pinned_ref and pinned_ref != str(built.get("git_ref", "")):
        raise ValueError(f"arena_agent_build_ref_mismatch:{path}")
    strategy_path_value = str(raw.get("strategies_path", "")).strip()
    if strategy_path_value:
        strategy_path = Path(strategy_path_value)
        if not strategy_path.is_absolute():
            strategy_path = (REPO_ROOT / strategy_path).resolve()
        strategies = _read_json(strategy_path)
    elif isinstance(raw.get("strategies"), dict):
        strategies = dict(raw["strategies"])
    return ArenaAgentSpec(
        agent_id=str(raw.get("agent_id", identifier)),
        build_id=str(raw.get("build_id", default_build_id)),
        strategies=strategies,
        evaluation_options=dict(raw.get("evaluation_options", {})),
        source=str(path),
        backend="external_process" if built else str(raw.get("backend", "in_process")),
        implementation_hash=str(built.get(
            "implementation_hash", raw.get("implementation_hash", ""))),
        executable_path=str(built.get(
            "executable_path", raw.get("executable_path", ""))),
        decision_timeout_milliseconds=int(raw.get(
            "decision_timeout_milliseconds", 120000
        )),
        build_manifest=built,
    )


def with_preset_contract(spec: ArenaAgentSpec, preset: str) -> ArenaAgentSpec:
    options = dict(spec.evaluation_options)
    options.setdefault("engine", "turn_beam_v2")
    options.setdefault("node_budget", 192)
    options.setdefault("belief_samples", 3)
    if preset == "smoke":
        options.update({
            "internal_evaluation_smoke": True,
            "node_budget": min(32, int(options.get("node_budget", 192))),
            "belief_samples": 1,
        })
    else:
        options.pop("internal_evaluation_smoke", None)
    return replace(spec, evaluation_options=options)


def validate_equal_search_contract(
    candidate: ArenaAgentSpec,
    baseline: ArenaAgentSpec,
) -> None:
    if dict(candidate.evaluation_options) != dict(baseline.evaluation_options):
        raise ValueError(
            "challenge_arena_search_contract_mismatch: candidate and baseline "
            "must use identical fixed evaluation options"
        )
    if (
        candidate.decision_timeout_milliseconds
        != baseline.decision_timeout_milliseconds
    ):
        raise ValueError(
            "challenge_arena_watchdog_mismatch: candidate and baseline "
            "must use the same non-strength watchdog"
        )


def native_binding_build_info() -> dict[str, Any]:
    try:
        import ptcg_ai_core
    except ImportError as exc:
        raise RuntimeError(
            "Native Challenge Arena binding is not built; run "
            "research/deep_ai/tools/build_native_binding.ps1"
        ) from exc
    binding = Path(str(ptcg_ai_core.__file__)).resolve()
    return load_and_verify_binding(
        REPO_ROOT,
        binding,
        binding.with_name("ptcg_ai_core.build.json"),
    )


def prepare_agent_runtime(
    spec: ArenaAgentSpec,
    *,
    output: Path,
    catalog: Mapping[str, Any],
    decks: Mapping[str, Any],
    binding_info: Mapping[str, Any],
) -> ArenaAgentSpec:
    if spec.backend == "in_process":
        return replace(
            spec,
            implementation_hash=str(binding_info["input_hash"]),
        )
    if os.name != "nt":
        raise RuntimeError("external_agent_backend_requires_windows")
    inputs = output / ".inputs"
    catalog_path = inputs / f"catalog-{canonical_hash(catalog)}.json"
    decks_path = inputs / f"decks-{canonical_hash(decks)}.json"
    strategies_path = inputs / (
        f"strategies-{canonical_hash(spec.strategies)}.json"
    )
    for path, value in (
        (catalog_path, dict(catalog)),
        (decks_path, dict(decks)),
        (strategies_path, dict(spec.strategies)),
    ):
        if path.is_file():
            if canonical_hash(_read_json(path)) != canonical_hash(value):
                raise RuntimeError(
                    f"arena_runtime_input_hash_mismatch:{path.name}"
                )
        else:
            write_json_atomic(path, value)
    config = {
        "schema": "ptcg.challenge_agent.config/1",
        "catalog_path": str(catalog_path.resolve()),
        "decks_path": str(decks_path.resolve()),
        "strategies_path": str(strategies_path.resolve()),
        "catalog_hash": canonical_hash(catalog),
        "decks_hash": canonical_hash(decks),
        "strategies_hash": canonical_hash(spec.strategies),
        "catalog_file_sha256": sha256_file(catalog_path),
        "decks_file_sha256": sha256_file(decks_path),
        "strategies_file_sha256": sha256_file(strategies_path),
    }
    config_path = inputs / f"agent-{canonical_hash(config)}.json"
    write_json_atomic(config_path, config)
    return replace(
        spec,
        process_config_path=str(config_path.resolve()),
        process_log_directory=str((output / "agent-logs").resolve()),
    )


def validate_agent_identity(
    candidate: ArenaAgentSpec,
    baseline: ArenaAgentSpec,
    *,
    allow_self_play: bool,
) -> None:
    identical = (
        candidate.implementation_hash == baseline.implementation_hash
        and canonical_hash(candidate.strategies) == canonical_hash(baseline.strategies)
        and dict(candidate.evaluation_options) == dict(baseline.evaluation_options)
    )
    if identical and not allow_self_play:
        raise ValueError("arena_agents_are_identical")


class NativeChallengeArena:
    def __init__(
        self,
        catalog: Mapping[str, Any],
        decks: Mapping[str, Any],
        candidate: ArenaAgentSpec,
        baseline: ArenaAgentSpec,
        *,
        workers: int = 8,
        capture_failure_trace: bool = True,
        trace_all: bool = False,
    ) -> None:
        if int(workers) <= 0:
            raise ValueError("challenge_arena_workers_must_be_positive")
        candidate.validate()
        baseline.validate()
        validate_equal_search_contract(candidate, baseline)
        self.catalog = dict(catalog)
        self.decks = dict(decks)
        self.candidate = candidate
        self.baseline = baseline
        self.workers = int(workers)
        self.capture_failure_trace = bool(capture_failure_trace)
        self.trace_all = bool(trace_all)

    def run(
        self,
        tasks: Sequence[ArenaTask],
        *,
        on_games: Callable[[list[dict[str, Any]]], None] | None = None,
        require_complete_matrix: bool = True,
    ) -> dict[str, Any]:
        if require_complete_matrix:
            validate_task_matrix(tasks)
        else:
            if not tasks:
                raise ValueError("challenge_arena_retry_tasks_empty")
            identifiers = [task.task_id for task in tasks]
            if len(identifiers) != len(set(identifiers)) or any(
                task.candidate_seat not in (0, 1)
                or task.first_player not in (0, 1)
                or not task.block_id
                or task.block_size <= 0
                for task in tasks
            ):
                raise ValueError("invalid_challenge_arena_retry_tasks")
        try:
            import ptcg_ai_core
        except ImportError as exc:
            raise RuntimeError(
                "Native Challenge Arena binding is not built; run "
                "research/deep_ai/tools/build_native_binding.ps1"
            ) from exc
        pool = ptcg_ai_core.NativeChallengeArenaPool(
            self.catalog,
            self.decks,
            self.candidate.native_payload(),
            self.baseline.native_payload(),
            {
                "concurrent_games": self.workers,
                "deterministic": True,
                "capture_failure_trace": self.capture_failure_trace,
                "capture_all_decisions": self.trace_all,
                "inner_search_workers": 1,
            },
        )
        started = time.perf_counter()
        pool.start([task.native_payload() for task in tasks])
        games: list[dict[str, Any]] = []
        task_by_id = {task.task_id: task for task in tasks}

        def collect() -> None:
            drained = list(pool.drain_games())
            for game in drained:
                task = task_by_id.get(str(game.get("task_id", "")))
                if task is None:
                    raise RuntimeError("challenge_arena_unknown_result_task")
                game["block_id"] = task.block_id
                game["block_size"] = task.block_size
                game["block_kind"] = task.block_kind
                game["replicate"] = task.replicate
                game["closure"] = task.closure
                game["candidate_agent_id"] = self.candidate.agent_id
                game["candidate_build_id"] = self.candidate.build_id
                game["baseline_agent_id"] = self.baseline.agent_id
                game["baseline_build_id"] = self.baseline.build_id
                game["full_result_hash"] = canonical_hash(game)
            if drained and on_games is not None:
                on_games(drained)
            games.extend(drained)

        while not pool.wait_for(1000):
            collect()
        pool.wait()
        collect()
        elapsed_seconds = time.perf_counter() - started
        games.sort(key=lambda row: str(row.get("task_id", "")))
        if len(games) != len(tasks):
            raise RuntimeError(
                f"challenge_arena_result_count_mismatch:{len(games)}:{len(tasks)}"
            )
        return {
            "games": games,
            "native_metrics": dict(pool.metrics()),
            "elapsed_seconds": elapsed_seconds,
            "games_per_second": len(games) / max(elapsed_seconds, 1e-9),
        }


def aggregate_native_metrics(
    games: Sequence[Mapping[str, Any]],
    candidate: ArenaAgentSpec,
    baseline: ArenaAgentSpec,
) -> dict[str, Any]:
    """Rebuild the additive pool metrics from durable game rows.

    This makes a resumed report cover pre-crash shards as well as newly run
    batches instead of depending on ephemeral per-process counters.
    """
    additive_fields = (
        "decisions",
        "invalid_actions",
        "illegal_choices",
        "controller_failures",
        "rule_exceptions",
        "candidate_decision_us",
        "baseline_decision_us",
        "candidate_nodes",
        "baseline_nodes",
        "projection_us",
        "legal_actions_us",
        "apply_us",
    )
    result: dict[str, Any] = {
        "schema": "ptcg.native_challenge_arena.metrics/1",
        "tasks": len(games),
        "completed_games": sum(bool(game.get("success", False)) for game in games),
        "failed_games": sum(not bool(game.get("success", False)) for game in games),
        "truncated_games": sum(bool(game.get("truncated", False)) for game in games),
        "candidate_agent_id": candidate.agent_id,
        "candidate_build_id": candidate.build_id,
        "candidate_backend": candidate.backend,
        "candidate_implementation_hash": candidate.implementation_hash,
        "baseline_agent_id": baseline.agent_id,
        "baseline_build_id": baseline.build_id,
        "baseline_backend": baseline.backend,
        "baseline_implementation_hash": baseline.implementation_hash,
        "deterministic": True,
        "inner_search_workers": 1,
        "running": False,
        "finished": True,
        "paused": False,
        "cancelled": False,
    }
    for field_name in additive_fields:
        result[field_name] = sum(
            int(game.get(field_name, 0)) for game in games
        )
    return result


def git_metadata() -> dict[str, Any]:
    def command(*arguments: str) -> str:
        try:
            return subprocess.check_output(
                arguments,
                cwd=REPO_ROOT,
                text=True,
                encoding="utf-8",
                errors="replace",
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            return ""

    return {
        "commit": command("git", "rev-parse", "HEAD"),
        "branch": command("git", "branch", "--show-current"),
        "dirty": bool(command("git", "status", "--porcelain")),
    }


def build_manifest(
    *,
    preset: str,
    tasks: Sequence[ArenaTask],
    games: Sequence[Mapping[str, Any]],
    catalog: Mapping[str, Any],
    decks: Mapping[str, Any],
    candidate: ArenaAgentSpec,
    baseline: ArenaAgentSpec,
    workers: int,
    elapsed_seconds: float,
    trace_all: bool,
    comparison_mode: str,
    binding_info: Mapping[str, Any],
) -> dict[str, Any]:
    semantic_hashes = sorted(
        str(row.get("semantic_result_hash", "")) for row in games
    )
    return {
        "schema": MANIFEST_SCHEMA,
        "arena_schema": ARENA_SCHEMA,
        "preset": preset,
        "comparison_mode": comparison_mode,
        "candidate": {
            "agent_id": candidate.agent_id,
            "build_id": candidate.build_id,
            "source": candidate.source,
            "strategy_hash": canonical_hash(candidate.strategies),
            "backend": candidate.backend,
            "implementation_hash": candidate.implementation_hash,
            "binary": dict(candidate.build_manifest),
        },
        "baseline": {
            "agent_id": baseline.agent_id,
            "build_id": baseline.build_id,
            "source": baseline.source,
            "strategy_hash": canonical_hash(baseline.strategies),
            "backend": baseline.backend,
            "implementation_hash": baseline.implementation_hash,
            "binary": dict(baseline.build_manifest),
        },
        "content": {
            "catalog_hash": canonical_hash(catalog),
            "decks_hash": canonical_hash(decks),
        },
        "search_contract": {
            "mode": "fixed_contract",
            "evaluation_options": dict(candidate.evaluation_options),
            "inner_search_workers": 1,
        },
        "runtime": {
            "workers": int(workers),
            "elapsed_seconds": float(elapsed_seconds),
            "platform": platform.platform(),
            "processor": platform.processor(),
            "python": sys.version,
            "python_compiler": platform.python_compiler(),
            "pid": os.getpid(),
        },
        "native_binding": dict(binding_info),
        "reporting_code": reporting_code_info(),
        "reporting": {
            "capture_failure_trace": True,
            "capture_all_decisions": bool(trace_all),
        },
        "git": git_metadata(),
        "tasks": {
            "count": len(tasks),
            "hash": canonical_hash([
                {
                    **task.native_payload(),
                    "block_id": task.block_id,
                    "block_size": task.block_size,
                    "block_kind": task.block_kind,
                    "replicate": task.replicate,
                    "closure": task.closure,
                }
                for task in tasks
            ]),
        },
        "results": {
            "count": len(games),
            "semantic_result_hash": canonical_hash(semantic_hashes),
            "full_result_hash": canonical_hash(list(games)),
        },
    }


def write_arena_outputs(
    output: Path,
    *,
    games: Sequence[Mapping[str, Any]],
    attempts: Sequence[Mapping[str, Any]],
    summary: Mapping[str, Any],
    manifest: Mapping[str, Any],
) -> None:
    output.mkdir(parents=True, exist_ok=True)
    ordered_games = sorted(games, key=lambda row: str(row.get("task_id", "")))
    failures = [
        row
        for row in ordered_games
        if (
            not bool(row.get("success", False))
            or bool(row.get("truncated", False))
            or any(int(row.get(key, 0)) for key in (
                "invalid_actions",
                "illegal_choices",
                "controller_failures",
                "rule_exceptions",
            ))
        )
    ]

    write_jsonl_atomic(output / "arena-games.jsonl", ordered_games)
    write_jsonl_atomic(
        output / "arena-attempts.jsonl",
        sorted(
            attempts,
            key=lambda row: (
                str(row.get("task_id", "")),
                int(row.get("attempt_number", 0)),
            ),
        ),
    )
    write_jsonl_atomic(output / "arena-failures.jsonl", failures)
    write_json_atomic(output / "arena-summary.json", dict(summary))
    write_json_atomic(output / "arena-manifest.json", dict(manifest))


def run_arena(
    *,
    preset: str,
    candidate: ArenaAgentSpec,
    baseline: ArenaAgentSpec,
    workers: int,
    output: Path,
    seed: int = 17,
    replicates: int | None = None,
    max_decisions: int = 512,
    candidate_decks: Sequence[str] = (),
    baseline_decks: Sequence[str] = (),
    mirror_only: bool = False,
    trace_all: bool = False,
    bootstrap_samples: int = 2000,
    truncated_rate_limit: float = 0.001,
    latency_ratio_limit: float = 1.15,
    max_candidate_p95_ms: float | None = None,
    allow_self_play: bool = False,
    comparison_mode: str = "release-bundle",
) -> dict[str, Any]:
    catalog, decks, _ = load_product_payloads()
    binding_info = native_binding_build_info()
    if comparison_mode not in {
        "release-bundle", "implementation-only", "same-binary-strategy",
    }:
        raise ValueError("challenge_arena_comparison_mode_invalid")
    if comparison_mode == "implementation-only":
        baseline = replace(baseline, strategies=dict(candidate.strategies))
    if comparison_mode == "same-binary-strategy":
        candidate = replace(
            candidate,
            backend="in_process",
            executable_path="",
            process_config_path="",
            build_manifest={},
        )
        baseline = replace(
            baseline,
            backend="in_process",
            executable_path="",
            process_config_path="",
            build_manifest={},
        )
    if candidate.backend != baseline.backend:
        raise ValueError("challenge_arena_mixed_backends_not_allowed")
    if preset in {"nightly", "release"} and (
        candidate.backend != "external_process"
        or baseline.backend != "external_process"
    ):
        raise RuntimeError("trusted_arena_preset_requires_external_agents")
    candidate = with_preset_contract(candidate, preset)
    baseline = with_preset_contract(baseline, preset)
    validate_equal_search_contract(candidate, baseline)
    output = output.resolve()
    candidate = prepare_agent_runtime(
        candidate,
        output=output,
        catalog=catalog,
        decks=decks,
        binding_info=binding_info,
    )
    baseline = prepare_agent_runtime(
        baseline,
        output=output,
        catalog=catalog,
        decks=decks,
        binding_info=binding_info,
    )
    validate_agent_identity(
        candidate, baseline, allow_self_play=allow_self_play
    )
    if preset == "calibration" and not allow_self_play:
        raise ValueError("calibration_requires_allow_self_play")
    if preset == "calibration" and (
        candidate.backend != "external_process"
        or baseline.backend != "external_process"
        or candidate.implementation_hash != baseline.implementation_hash
        or canonical_hash(candidate.strategies) != canonical_hash(baseline.strategies)
    ):
        raise ValueError("calibration_requires_identical_external_agents")
    if preset == "release" and git_metadata()["dirty"]:
        raise ValueError("release_arena_requires_clean_worktree")
    tasks = generate_tasks(
        preset,
        seed=seed,
        replicates=replicates,
        max_decisions=max_decisions,
        candidate_decks=candidate_decks,
        baseline_decks=baseline_decks,
        mirror_only=mirror_only,
    )
    requested_replicates = max(task.replicate for task in tasks) + 1
    if preset == "smoke" and requested_replicates != 1:
        raise ValueError("smoke_preset_requires_one_replicate")
    if preset == "pr" and requested_replicates != 2:
        raise ValueError("pr_preset_requires_two_replicates")
    if preset == "nightly" and not 5 <= requested_replicates <= 30:
        raise ValueError("nightly_replicates_must_be_between_5_and_30")
    if preset == "release" and not 10 <= requested_replicates <= 50:
        raise ValueError("release_replicates_must_be_between_10_and_50")
    reporting_info = reporting_code_info()
    run_fingerprint = canonical_hash({
        "schema": "ptcg.challenge_arena.run_fingerprint/2",
        "preset": preset,
        "comparison_mode": comparison_mode,
        "mirror_only": bool(mirror_only),
        "base_seed": int(seed),
        "catalog_hash": canonical_hash(catalog),
        "decks_hash": canonical_hash(decks),
        "tasks": [
            {
                **task.native_payload(),
                "block_id": task.block_id,
                "block_size": task.block_size,
                "block_kind": task.block_kind,
                "replicate": task.replicate,
                "closure": task.closure,
            }
            for task in tasks
        ],
        "candidate": {
            "agent_id": candidate.agent_id,
            "build_id": candidate.build_id,
            "backend": candidate.backend,
            "implementation_hash": candidate.implementation_hash,
            "strategy_hash": canonical_hash(candidate.strategies),
            "evaluation_options": dict(candidate.evaluation_options),
            "decision_timeout_milliseconds": (
                candidate.decision_timeout_milliseconds
            ),
            "binary_sha256": candidate.build_manifest.get("executable_sha256", ""),
        },
        "baseline": {
            "agent_id": baseline.agent_id,
            "build_id": baseline.build_id,
            "backend": baseline.backend,
            "implementation_hash": baseline.implementation_hash,
            "strategy_hash": canonical_hash(baseline.strategies),
            "evaluation_options": dict(baseline.evaluation_options),
            "decision_timeout_milliseconds": (
                baseline.decision_timeout_milliseconds
            ),
            "binary_sha256": baseline.build_manifest.get("executable_sha256", ""),
        },
        "binding_sha256": binding_info["binding_sha256"],
        "reporting_code_hash": reporting_info["hash"],
        "workers": int(workers),
        "trace_all": bool(trace_all),
        "bootstrap_samples": int(bootstrap_samples),
        "truncated_rate_limit": float(truncated_rate_limit),
        "latency_ratio_limit": float(latency_ratio_limit),
        "max_candidate_p95_ms": max_candidate_p95_ms,
        "allow_self_play": bool(allow_self_play),
        "retry_policy": {
            "timeout_retries": 1,
            "retry_workers": 1,
            "watchdog_is_strength_neutral": True,
        },
    })
    sequential = preset in {"nightly", "release"}
    maximum_replicates = max(task.replicate for task in tasks) + 1
    minimum_replicates = (
        min(5 if preset == "nightly" else 10, maximum_replicates)
        if sequential
        else maximum_replicates
    )
    maximum_looks = (
        maximum_replicates - minimum_replicates + 1 if sequential else 1
    )
    simultaneous_alpha = 0.05 / maximum_looks
    native_metrics: dict[str, Any] = {}
    elapsed_seconds = 0.0
    status = "continue"

    def make_summary(games: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
        metrics = aggregate_native_metrics(games, candidate, baseline)
        result = summarize_games(
            games,
            bootstrap_seed=seed ^ 0x5EED5EED,
            bootstrap_samples=bootstrap_samples,
            confidence_alpha=simultaneous_alpha if sequential else 0.05,
            truncated_rate_limit=truncated_rate_limit,
            latency_ratio_limit=latency_ratio_limit,
            max_candidate_p95_ms=max_candidate_p95_ms,
            native_metrics=metrics,
        )
        if preset == "calibration":
            interval = result["paired_statistics"]["score_rate_ci"]
            result["calibration"] = {
                "identical_external_agent": True,
                "half_within_interval": (
                    interval[0] is not None and interval[1] is not None
                    and float(interval[0]) <= 0.5 <= float(interval[1])
                ),
                "null_distribution": result["paired_statistics"].get(
                    "bootstrap_distribution", {}
                ),
            }
        return result

    with ChallengeArenaRunStore(
        output,
        fingerprint=run_fingerprint,
        task_ids=[task.task_id for task in tasks],
    ) as store:
        elapsed_seconds = store.elapsed_seconds
        if store.complete and (output / "arena-summary.json").is_file() \
                and (output / "arena-manifest.json").is_file():
            summary = _read_json(output / "arena-summary.json")
            manifest = _read_json(output / "arena-manifest.json")
            games = store.games
            return {
                "games": games,
                "native_metrics": dict(summary.get("native_metrics", {})),
                "elapsed_seconds": 0.0,
                "games_per_second": 0.0,
                "tasks": tasks,
                "attempts": store.attempts,
                "summary": summary,
                "manifest": manifest,
                "output": output,
            }

        arena = NativeChallengeArena(
            catalog,
            decks,
            candidate,
            baseline,
            workers=workers,
            capture_failure_trace=True,
            trace_all=trace_all,
        )
        task_by_id = {task.task_id: task for task in tasks}
        retry_journal = TimeoutRetryJournal(store, task_by_id)

        def run_pending_retries() -> float:
            retry_journal.finalize_recorded_retries()
            pending = retry_journal.pending_tasks()
            if not pending:
                return 0.0
            retry_arena = NativeChallengeArena(
                catalog,
                decks,
                candidate,
                baseline,
                workers=1,
                capture_failure_trace=True,
                trace_all=trace_all,
            )

            result = retry_arena.run(
                pending,
                on_games=retry_journal.persist_retry,
                require_complete_matrix=False,
            )
            return float(result["elapsed_seconds"])

        resumed_retry_elapsed = run_pending_retries()
        if resumed_retry_elapsed > 0.0:
            elapsed_seconds += resumed_retry_elapsed
            store.add_elapsed_seconds(resumed_retry_elapsed)
        replicate_values = (
            range(maximum_replicates) if sequential else range(1)
        )
        summary: dict[str, Any] | None = None
        for replicate_index in replicate_values:
            batch = [
                task
                for task in tasks
                if (
                    (task.replicate == replicate_index if sequential else True)
                    and task.task_id not in store.completed_task_ids
                )
            ]
            if batch:
                batch_result = arena.run(
                    batch, on_games=retry_journal.persist_primary
                )
                batch_elapsed = float(batch_result["elapsed_seconds"])
                elapsed_seconds += batch_elapsed
                store.add_elapsed_seconds(batch_elapsed)
                retry_elapsed = run_pending_retries()
                if retry_elapsed > 0.0:
                    elapsed_seconds += retry_elapsed
                    store.add_elapsed_seconds(retry_elapsed)
            games = store.games
            summary = make_summary(games)
            integrity = summary["integrity"]
            if int(integrity.get("rule_exceptions", 0)) > 0 or int(
                integrity.get("unclassified_failures", 0)
            ) > 0:
                status = "infrastructure_fail"
                break
            if int(integrity.get("structural_errors", 0)) > 0:
                status = "fail"
                break
            if not bool(summary.get("reliability", {}).get("passed", True)):
                status = "fail"
                break
            completed_replicates = replicate_index + 1 if sequential else maximum_replicates
            if sequential and completed_replicates < minimum_replicates:
                continue
            look = completed_replicates - minimum_replicates + 1 if sequential else 1
            status = gate_status(
                summary,
                preset=preset,
                look=look,
                maximum_looks=maximum_looks,
                final_look=(
                    completed_replicates >= maximum_replicates
                    if sequential else True
                ),
            )
            if status != "continue":
                break
        games = store.games
        native_metrics = aggregate_native_metrics(games, candidate, baseline)
        if summary is None:
            summary = make_summary(games)
        if status == "continue":
            status = "inconclusive"
        summary["arena"] = {
            "schema": ARENA_SCHEMA,
            "preset": preset,
            "candidate": candidate.agent_id,
            "baseline": baseline.agent_id,
            "workers": int(workers),
            "elapsed_seconds": elapsed_seconds,
            "games_per_second": len(games) / max(elapsed_seconds, 1e-9),
            "gate_status": status,
            "run_fingerprint": run_fingerprint,
            "minimum_replicates": minimum_replicates,
            "maximum_replicates": maximum_replicates,
            "completed_replicates": (
                max((int(game.get("replicate", 0)) for game in games), default=-1) + 1
            ),
            "sequential_alpha": simultaneous_alpha,
        }
        manifest = build_manifest(
            preset=preset,
            tasks=tasks,
            games=games,
            catalog=catalog,
            decks=decks,
            candidate=candidate,
            baseline=baseline,
            workers=workers,
            elapsed_seconds=elapsed_seconds,
            trace_all=trace_all,
            comparison_mode=comparison_mode,
            binding_info=binding_info,
        )
        manifest["run_fingerprint"] = run_fingerprint
        manifest["gate_status"] = status
        manifest["retry_policy"] = {
            "timeout_retries": 1,
            "retry_workers": 1,
            "watchdog_milliseconds": candidate.decision_timeout_milliseconds,
            "watchdog_is_strength_neutral": True,
        }
        ordered_attempts = sorted(
            store.attempts,
            key=lambda row: (
                str(row.get("task_id", "")),
                int(row.get("attempt_number", 0)),
            ),
        )
        manifest["attempts"] = {
            "count": len(ordered_attempts),
            "hash": canonical_hash(ordered_attempts),
        }
        write_arena_outputs(
            output,
            games=games,
            attempts=store.attempts,
            summary=summary,
            manifest=manifest,
        )
        store.mark_complete(status)
    return {
        "games": games,
        "native_metrics": native_metrics,
        "elapsed_seconds": elapsed_seconds,
        "games_per_second": len(games) / max(elapsed_seconds, 1e-9),
        "tasks": tasks,
        "attempts": store.attempts,
        "summary": summary,
        "manifest": manifest,
        "output": output,
    }
