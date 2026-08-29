"""Native, callback-free Challenge-vs-Challenge evaluation orchestration."""
from __future__ import annotations

import hashlib
import json
import os
import platform
import subprocess
import sys
import time
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

from .challenge_arena_stats import summarize_games
from .v3_contract import RELEASE_DECKS
from engine.native_state_codec import native_catalog_payload


ARENA_SCHEMA = "ptcg.native_challenge_arena/1"
MANIFEST_SCHEMA = "ptcg.challenge_arena.manifest/1"
RESEARCH_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = Path(__file__).resolve().parents[4]
PRODUCT_DECKS = REPO_ROOT / "godot" / "data" / "decks.json"
PRODUCT_STRATEGIES = REPO_ROOT / "godot" / "data" / "ai_strategies.json"
BASELINES_ROOT = RESEARCH_ROOT / "arena" / "baselines"
SEAT_FIRST_PLAYER_CLOSURES = ((0, 0), (1, 0), (0, 1), (1, 1))
PRESET_REPLICATES = {
    "smoke": 1,
    "pr": 2,
    "nightly": 2,
    "release": 5,
    "focused": 1,
}


def _read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected_json_object:{path}")
    return value


def canonical_hash(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


@dataclass(frozen=True, slots=True)
class ArenaAgentSpec:
    agent_id: str
    build_id: str
    strategies: Mapping[str, Any]
    evaluation_options: Mapping[str, Any] = field(default_factory=dict)
    source: str = ""

    def validate(self) -> None:
        if not self.agent_id.strip():
            raise ValueError("arena_agent_id_empty")
        if not isinstance(self.strategies, Mapping) or not self.strategies:
            raise ValueError(f"arena_agent_strategies_empty:{self.agent_id}")
        if not isinstance(self.evaluation_options, Mapping):
            raise ValueError(f"arena_agent_options_invalid:{self.agent_id}")

    def native_payload(self) -> dict[str, Any]:
        self.validate()
        return {
            "agent_id": self.agent_id,
            "build_id": self.build_id,
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
) -> list[tuple[str, str]]:
    decks = tuple(str(value) for value in RELEASE_DECKS)
    if preset == "smoke":
        return [
            ("fire", "water"),
            ("psychic", "lightning"),
            ("fighting", "colorless"),
            ("dragon", "grass"),
        ]
    if preset == "pr":
        return _pr_matchups(decks)
    if preset in {"nightly", "release"}:
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


def generate_tasks(
    preset: str,
    *,
    seed: int = 17,
    replicates: int | None = None,
    max_decisions: int = 512,
    candidate_decks: Sequence[str] = (),
    baseline_decks: Sequence[str] = (),
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
    )
    tasks: list[ArenaTask] = []
    for replicate in range(count):
        game_seed = (int(seed) + replicate * 104729) & 0xFFFFFFFF
        for candidate_deck, baseline_deck in matchups:
            unordered = "__".join(sorted((candidate_deck, baseline_deck)))
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
                    replicate=replicate,
                    closure=closure,
                ))
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
) -> ArenaAgentSpec:
    strategies = dict(product_strategies or _read_json(PRODUCT_STRATEGIES))
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
        )
    raw = _read_json(path)
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

    def run(self, tasks: Sequence[ArenaTask]) -> dict[str, Any]:
        validate_task_matrix(tasks)
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
        pool.wait()
        elapsed_seconds = time.perf_counter() - started
        games = list(pool.drain_games())
        task_by_id = {task.task_id: task for task in tasks}
        for game in games:
            task = task_by_id.get(str(game.get("task_id", "")))
            if task is None:
                raise RuntimeError("challenge_arena_unknown_result_task")
            game["block_id"] = task.block_id
            game["replicate"] = task.replicate
            game["closure"] = task.closure
            game["full_result_hash"] = canonical_hash(game)
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
) -> dict[str, Any]:
    semantic_hashes = sorted(
        str(row.get("semantic_result_hash", "")) for row in games
    )
    return {
        "schema": MANIFEST_SCHEMA,
        "arena_schema": ARENA_SCHEMA,
        "preset": preset,
        "candidate": {
            "agent_id": candidate.agent_id,
            "build_id": candidate.build_id,
            "source": candidate.source,
            "strategy_hash": canonical_hash(candidate.strategies),
        },
        "baseline": {
            "agent_id": baseline.agent_id,
            "build_id": baseline.build_id,
            "source": baseline.source,
            "strategy_hash": canonical_hash(baseline.strategies),
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
        "reporting": {
            "capture_failure_trace": True,
            "capture_all_decisions": bool(trace_all),
        },
        "git": git_metadata(),
        "tasks": {
            "count": len(tasks),
            "hash": canonical_hash([task.native_payload() for task in tasks]),
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

    def write_json(path: Path, value: Mapping[str, Any]) -> None:
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def write_jsonl(path: Path, values: Iterable[Mapping[str, Any]]) -> None:
        path.write_text(
            "".join(
                json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n"
                for value in values
            ),
            encoding="utf-8",
        )

    write_jsonl(output / "arena-games.jsonl", ordered_games)
    write_jsonl(output / "arena-failures.jsonl", failures)
    write_json(output / "arena-summary.json", summary)
    write_json(output / "arena-manifest.json", manifest)


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
    trace_all: bool = False,
    bootstrap_samples: int = 2000,
    truncated_rate_limit: float = 0.01,
    latency_ratio_limit: float = 1.15,
    max_candidate_p95_ms: float | None = None,
) -> dict[str, Any]:
    catalog, decks, _ = load_product_payloads()
    candidate = with_preset_contract(candidate, preset)
    baseline = with_preset_contract(baseline, preset)
    validate_equal_search_contract(candidate, baseline)
    tasks = generate_tasks(
        preset,
        seed=seed,
        replicates=replicates,
        max_decisions=max_decisions,
        candidate_decks=candidate_decks,
        baseline_decks=baseline_decks,
    )
    arena = NativeChallengeArena(
        catalog,
        decks,
        candidate,
        baseline,
        workers=workers,
        capture_failure_trace=True,
        trace_all=trace_all,
    )
    result = arena.run(tasks)
    summary = summarize_games(
        result["games"],
        bootstrap_seed=seed ^ 0x5EED5EED,
        bootstrap_samples=bootstrap_samples,
        truncated_rate_limit=truncated_rate_limit,
        latency_ratio_limit=latency_ratio_limit,
        max_candidate_p95_ms=max_candidate_p95_ms,
        native_metrics=result["native_metrics"],
    )
    summary["arena"] = {
        "schema": ARENA_SCHEMA,
        "preset": preset,
        "candidate": candidate.agent_id,
        "baseline": baseline.agent_id,
        "workers": int(workers),
        "elapsed_seconds": result["elapsed_seconds"],
        "games_per_second": result["games_per_second"],
    }
    manifest = build_manifest(
        preset=preset,
        tasks=tasks,
        games=result["games"],
        catalog=catalog,
        decks=decks,
        candidate=candidate,
        baseline=baseline,
        workers=workers,
        elapsed_seconds=result["elapsed_seconds"],
        trace_all=trace_all,
    )
    write_arena_outputs(
        output,
        games=result["games"],
        summary=summary,
        manifest=manifest,
    )
    return {
        **result,
        "tasks": tasks,
        "summary": summary,
        "manifest": manifest,
        "output": output,
    }
