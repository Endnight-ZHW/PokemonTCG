"""Native Challenge adapter for the shared evaluation state machine."""
from __future__ import annotations

import copy
from dataclasses import replace
from pathlib import Path
from typing import Any, Callable, Sequence

from .evaluation import evaluate
from .evaluation_protocol import COMPARISON_ROLES, EvaluationProtocol, EvaluationTask
from .evaluation_store import cohort_for_output
from .evaluation_fairness import canonical_hash
from .challenge_arena_build import sha256_file, write_json_atomic


def evaluation_code_hash() -> str:
    root = Path(__file__).parent
    paths = set(root.glob("evaluation*.py"))
    paths.update(root / name for name in ("challenge_arena.py", "challenge_arena_build.py",
                 "actor_v3.py", "inference_v3.py", "model_v3.py", "encoder_v3.py", "card_vocab.py", "v3_contract.py"))
    return canonical_hash({p.name: sha256_file(p) for p in sorted(paths)})


class ChallengeEvaluationBackend:
    def __init__(self, *, agents: dict[str, Any], catalog: dict, decks: dict,
                 workers: int, trace_all: bool = False):
        self.agents = copy.deepcopy(agents)
        self.catalog = catalog
        self.decks = decks
        self.workers = workers
        self.trace_all = trace_all
        self.arenas: dict[str, Any] = {}
        self.pool_starts = 0
        self.played_games = 0
        self.primary_rows: list[dict[str, Any]] = []

    def run(self, tasks: Sequence[EvaluationTask], *,
            on_games: Callable[[list[dict[str, Any]]], None], isolated: bool = False) -> None:
        from .challenge_arena import NativeChallengeArena
        if not tasks:
            return
        comparison = tasks[0].comparison
        if any(task.comparison != comparison for task in tasks):
            raise ValueError("evaluation_backend_mixed_comparisons")
        left, right = COMPARISON_ROLES[comparison]
        arena = None if isolated else self.arenas.get(comparison)
        if arena is None:
            arena = NativeChallengeArena(self.catalog, self.decks, self.agents[left], self.agents[right],
                                         workers=1 if isolated else self.workers,
                                         capture_failure_trace=True, trace_all=self.trace_all)
            self.pool_starts += 1
            if not isolated:
                self.arenas[comparison] = arena
        def collect(rows: list[dict[str, Any]]) -> None:
            self.played_games += len(rows)
            if comparison == "ac":
                self.primary_rows.extend(rows)
            on_games(rows)

        try:
            arena.run(tasks, on_games=collect)
        finally:
            if isolated:
                arena.close()

    def performance(self) -> dict[str, Any]:
        return {"pool_starts": self.pool_starts, "played_games": self.played_games,
                "workers": self.workers, "gating": False}

    def final_performance(self) -> dict[str, Any]:
        from .evaluation_performance import agent_performance, performance_advisory
        a = agent_performance(self.primary_rows, "candidate")
        b = agent_performance(self.primary_rows, "baseline")
        return {**self.performance(), "candidate": a, "champion": b,
                **performance_advisory(a, b, latency_ratio_limit=1.15, max_candidate_p95_ms=None)}

    def close(self) -> None:
        for arena in self.arenas.values():
            arena.close()
        self.arenas.clear()


def run_challenge_evaluation(*, preset: str, candidate: Any, champion: Any, anchor: Any | None,
                             workers: int, output: Path, seed: int = 17,
                             replicates: int | None = None, max_decisions: int = 1024,
                             allow_self_play: bool = False, comparison_mode: str = "release-bundle",
                             trace_all: bool = False, cache_root: Path | None = None,
                             declare_only: bool = False) -> dict[str, Any]:
    from .challenge_arena import (
        load_product_payloads, native_binding_build_info, prepare_agent_runtime,
        validate_agent_identity, validate_equal_search_contract, with_preset_contract,
    )
    from .v3_contract import RELEASE_DECKS
    modes = {"smoke": "screen", "pr": "screen", "nightly": "regression", "release": "promotion", "calibration": "calibration"}
    mode = modes[preset]
    if mode == "promotion" and anchor is None:
        raise ValueError("evaluation_promotion_requires_frozen_anchor")
    if comparison_mode == "same-binary-strategy" and mode in {"regression", "promotion"}:
        raise ValueError("evaluation_formal_requires_external_agents")
    if comparison_mode == "implementation-only":
        champion = replace(champion, strategies=dict(candidate.strategies))
    if comparison_mode == "same-binary-strategy":
        candidate = replace(candidate, backend="in_process", executable_path="", build_manifest={})
        champion = replace(champion, backend="in_process", executable_path="", build_manifest={})
    anchor = anchor or champion
    catalog, decks, _ = load_product_payloads()
    binding = native_binding_build_info()
    output = output.resolve()
    agents = {role: with_preset_contract(agent, preset) for role, agent in
              {"candidate": candidate, "champion": champion, "anchor": anchor}.items()}
    if len({agent.backend for agent in agents.values()}) != 1:
        raise ValueError("evaluation_mixed_backends_not_allowed")
    for role, agent in agents.items():
        if agent.evaluation_options.get("time_budget_ms", 0) != 0 or agent.evaluation_options.get("search_worker_mode", "single") != "single":
            raise ValueError("evaluation_requires_fixed_work_single_search")
        if mode in {"promotion", "regression"} and agent.backend != "external_process":
            raise ValueError("evaluation_formal_requires_external_agents")
        validate_equal_search_contract(agents["candidate"], agent)
        agents[role] = prepare_agent_runtime(agent, output=output / "runtime" / role,
                                             catalog=catalog, decks=decks, binding_info=binding)
    validate_agent_identity(agents["candidate"], agents["champion"], allow_self_play=allow_self_play)
    participants = {role: {"content_hash": canonical_hash({
        "implementation": agent.implementation_hash or binding["binding_sha256"],
        "binary": agent.build_manifest.get("executable_sha256", binding["binding_sha256"]),
        "strategies": agent.strategies, "options": agent.evaluation_options,
    }), "engine": agent.evaluation_options["engine"], "options": dict(agent.evaluation_options)}
        for role, agent in agents.items()}
    if mode == "calibration" and participants["candidate"] != participants["champion"]:
        raise ValueError("evaluation_calibration_requires_identical_agents")
    maximum = replicates if replicates is not None else (1 if mode == "screen" else 20 if mode == "calibration" else 100)
    if mode == "screen" and not 1 <= maximum <= 3:
        raise ValueError("evaluation_screen_requires_one_to_three_rounds")
    protocol = EvaluationProtocol.create(
        backend="challenge", mode=mode, decks=("fire", "water") if preset == "smoke" else RELEASE_DECKS, participants=participants,
        context={"rules_hash": canonical_hash(catalog), "decks_hash": canonical_hash(decks),
                 "binding_hash": binding["binding_sha256"], "evaluation_code_hash": evaluation_code_hash(),
                 "rules_profile": "CN_MAINLAND_3_1_0", "apply_type_matchups": False,
                 "comparison_mode": comparison_mode,
                 "time_budget_ms": 0, "inner_search_workers": 1,
                 "watchdog_ms": candidate.decision_timeout_milliseconds},
        seed=seed, cohort=cohort_for_output(output), maximum_replicates=maximum,
        minimum_replicates=5 if mode in {"promotion", "regression"} else 1,
        max_decisions=max_decisions,
    )
    backend = ChallengeEvaluationBackend(agents=agents, catalog=catalog, decks=decks,
                                         workers=workers, trace_all=trace_all)
    if declare_only:
        from .evaluation_store import EvaluationRunStore
        with EvaluationRunStore(output, protocol):
            pass
        return {"status": "declared", "protocol_fingerprint": protocol.fingerprint,
                "protocol_path": str(output / "evaluation-protocol.json"),
                "maximum_games": protocol.maximum_replicates * protocol.games_per_round * len(protocol.comparisons)}
    result = evaluate(protocol, backend, output=output,
                      cache_root=cache_root or output.parent / "evaluation-cache")
    summary = result.summary
    write_json_atomic(output / "agent-provenance.json", {
        role: {"agent_id": agent.agent_id, "build_id": agent.build_id,
               "build_manifest": dict(agent.build_manifest)} for role, agent in agents.items()
    })
    return summary
