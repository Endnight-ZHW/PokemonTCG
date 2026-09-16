"""Challenge agent loading and the native executor for EvaluationTask batches."""
from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from .challenge_arena_build import (
    load_and_verify_agent,
    load_and_verify_binding,
    sha256_file,
    write_json_atomic,
)
from .evaluation_fairness import canonical_hash
from .evaluation_protocol import EvaluationTask
from engine.native_state_codec import native_catalog_payload


RESEARCH_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = Path(__file__).resolve().parents[4]
PRODUCT_DECKS = REPO_ROOT / "godot" / "data" / "decks.json"
PRODUCT_STRATEGIES = REPO_ROOT / "godot" / "data" / "ai_strategies.json"
BASELINES_ROOT = RESEARCH_ROOT / "arena" / "baselines"

def product_engine_id() -> str:
    source = (REPO_ROOT / "godot" / "ai" / "challenge_ai_client.gd").read_text(encoding="utf-8")
    match = re.search(r'const\s+TRADITIONAL_ENGINE_ID\s*:?=\s*"([^"]+)"', source)
    if match is None:
        raise ValueError("evaluation_product_engine_not_declared")
    return match.group(1)


def _read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected_json_object:{path}")
    return value


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
                "engine": product_engine_id(),
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
    if "engine" not in options:
        options["engine"] = product_engine_id()
    options.setdefault("node_budget", 192)
    options.setdefault("belief_samples", 3)
    options.setdefault("use_deck_inspection", True)
    if options["engine"] == "deck_planner_v1":
        for obsolete in ("use_strategy_optimization", "skip_mandatory", "internal_anytime_search"):
            options.pop(obsolete, None)
    else:
        # Frozen agents retain their own historical switches in this adapter.
        options.setdefault("use_strategy_optimization", True)
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
    for spec in (candidate, baseline):
        if spec.evaluation_options.get("time_budget_ms", 0) != 0:
            raise ValueError("evaluation_requires_fixed_work")
        if spec.evaluation_options.get("search_worker_mode", "single") != "single":
            raise ValueError("evaluation_requires_single_search_worker")
    candidate_budget = dict(candidate.evaluation_options)
    baseline_budget = dict(baseline.evaluation_options)
    # Engine identity and owner deck-inspection knowledge are explicit A/B
    # treatments. Every actual work budget and sampling setting remains paired.
    candidate_budget.pop("engine", None)
    baseline_budget.pop("engine", None)
    candidate_budget.pop("use_deck_inspection", None)
    baseline_budget.pop("use_deck_inspection", None)
    candidate_budget.pop("use_strategy_optimization", None)
    baseline_budget.pop("use_strategy_optimization", None)
    if candidate_budget != baseline_budget:
        raise ValueError(
            "challenge_arena_search_contract_mismatch: candidate and baseline "
            "must use identical fixed work budgets"
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
        self._pool = None
        self.pool_starts = 0

    def close(self) -> None:
        if self._pool is not None:
            self._pool.cancel()
            self._pool.wait()
            self._pool = None

    def __enter__(self) -> NativeChallengeArena:
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()

    def run(
        self,
        tasks: Sequence[EvaluationTask],
        *,
        on_games: Callable[[list[dict[str, Any]]], None] | None = None,
    ) -> dict[str, Any]:
        if not tasks or len({task.task_id for task in tasks}) != len(tasks):
            raise ValueError("evaluation_invalid_task_batch")
        try:
            import ptcg_ai_core
        except ImportError as exc:
            raise RuntimeError(
                "Native Challenge Arena binding is not built; run "
                "research/deep_ai/tools/build_native_binding.ps1"
            ) from exc
        if self._pool is None:
            self._pool = ptcg_ai_core.NativeChallengeArenaPool(
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
            self.pool_starts += 1
        pool = self._pool
        started = time.perf_counter()
        pool.start([{"task_id": task.task_id, **task.conditions()} for task in tasks])
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

        try:
            while not pool.wait_for(250):
                collect()
            pool.wait()
            collect()
        except BaseException:
            self.close()
            raise
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
