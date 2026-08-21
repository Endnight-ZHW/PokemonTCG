"""Python orchestration for the all-native Deep AI v3 actor pool."""
from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

import numpy as np

from .encoder_v3 import EncodedCandidatesV3, EncodedInformationSetV3
from .inference_v3 import NativeBatchTorchBrokerV3
from .replay_v3 import ReplaySampleV3, ReplayStoreV3, SOURCE_NAMES
from .run_control_v3 import RunControlV3, TrainingCancelled


REPO_ROOT = Path(__file__).resolve().parents[4]


@dataclass(frozen=True, slots=True)
class GameTaskV3:
    game_id: str
    cycle: int
    deck_a: str
    deck_b: str
    seed: int
    seat_a: int
    first_player: int
    model_slots: tuple[int, int] = (0, 0)
    model_versions: tuple[int, int] = (0, 0)
    max_decisions: int = 512

    def validate(self) -> None:
        if not self.game_id or self.seat_a not in (0, 1):
            raise ValueError("invalid_v3_game_task")
        if self.first_player not in (0, 1) or self.seed < 0:
            raise ValueError("invalid_v3_game_task")
        if len(self.model_slots) != 2 or len(self.model_versions) != 2:
            raise ValueError("invalid_v3_game_model_routes")
        if self.max_decisions <= 0:
            raise ValueError("invalid_v3_game_decision_limit")


@dataclass(frozen=True, slots=True)
class ActorConfigV3:
    concurrent_games: int = 64
    search_slots: int = 16
    simulations: int = 128
    max_depth: int = 128
    max_inflight_leaves: int = 8
    inference_target_batch: int = 128
    inference_max_batch: int = 256
    inference_coalesce_ms: float = 2.0
    training: bool = True
    c_puct: float = 1.4
    dirichlet_epsilon: float = 0.25
    strict: bool = True
    direct_policy: bool = False


class NativeActorServiceV3:
    def __init__(
        self,
        models: Mapping[int, Any],
        *,
        device: str = "cuda",
        config: ActorConfigV3 | None = None,
        repo_root: str | Path = REPO_ROOT,
        control: RunControlV3 | None = None,
    ) -> None:
        try:
            import ptcg_ai_core
        except ImportError as exc:
            raise RuntimeError("v3_native_actor_binding_unavailable") from exc
        if not hasattr(ptcg_ai_core, "NativeActorPoolV3"):
            raise RuntimeError("v3_native_actor_binding_outdated")
        self.native = ptcg_ai_core
        self.repo_root = Path(repo_root).resolve()
        self.catalog = {
            "cards": json.loads(
                (self.repo_root / "godot" / "data" / "cards.json").read_text(
                    encoding="utf-8"
                )
            ),
            "card_ir": json.loads(
                (self.repo_root / "godot" / "data" / "card_ir_v3.json").read_text(
                    encoding="utf-8"
                )
            ),
        }
        self.decks = json.loads(
            (self.repo_root / "godot" / "data" / "decks.json").read_text(
                encoding="utf-8"
            )
        )
        self.config = config or ActorConfigV3()
        self.control = control
        self.batch = ptcg_ai_core.NativeSelfPlayBatch()
        self.limiter = ptcg_ai_core.NativeSearchLimiter(
            max(1, int(self.config.search_slots))
        )
        self.pool = ptcg_ai_core.NativeActorPoolV3(
            self.catalog,
            self.decks,
            self.batch,
            self.limiter,
            {
                "concurrent_games": self.config.concurrent_games,
                "simulations": self.config.simulations,
                "max_depth": self.config.max_depth,
                "max_inflight_leaves": self.config.max_inflight_leaves,
                "inference_wait_milliseconds": max(
                    1, int(round(self.config.inference_coalesce_ms))
                ),
                "training": self.config.training,
                "direct_policy": self.config.direct_policy,
                "c_puct": self.config.c_puct,
                "dirichlet_epsilon": self.config.dirichlet_epsilon,
            },
        )
        self.broker = NativeBatchTorchBrokerV3(
            self.batch,
            models,
            device=device,
            target_batch_size=self.config.inference_target_batch,
            max_batch_size=self.config.inference_max_batch,
            poll_wait_ms=max(1, int(round(self.config.inference_coalesce_ms))),
        )

    def close(self) -> None:
        self.pool.cancel()
        self.pool.wait()
        self.batch.close()
        self.broker.close()

    def __enter__(self) -> "NativeActorServiceV3":
        return self

    def __exit__(self, *_args: Any) -> None:
        self.close()

    def run(
        self,
        tasks: Sequence[GameTaskV3],
        *,
        replay: ReplayStoreV3 | None = None,
    ) -> dict[str, Any]:
        rows = []
        for task in tasks:
            task.validate()
            row = asdict(task)
            row["model_slots"] = list(task.model_slots)
            row["model_versions"] = list(task.model_versions)
            rows.append(row)
        self.pool.start(rows)
        stopped = threading.Event()
        actors_done = threading.Event()
        writer_state: dict[str, Any] = {"samples": 0, "error": None}
        writer = None
        if replay is not None:
            writer = threading.Thread(
                target=self._sample_writer,
                args=(replay, actors_done, writer_state),
                name="deep-ai-v3-replay-writer",
                daemon=True,
            )
            writer.start()
        monitor = threading.Thread(
            target=self._control_monitor,
            args=(stopped,),
            name="deep-ai-v3-control",
            daemon=True,
        )
        monitor.start()
        try:
            self.pool.wait()
        finally:
            actors_done.set()
            stopped.set()
            monitor.join(timeout=2.0)
            if writer is not None:
                writer.join(timeout=30.0)
                if writer.is_alive():
                    raise RuntimeError("v3_replay_writer_did_not_stop")
        games = list(self.pool.drain_games())
        native_samples = self.batch.drain_samples()
        written = int(writer_state["samples"])
        if writer_state["error"] is not None:
            raise RuntimeError("v3_replay_writer_failed") from writer_state["error"]
        if replay is not None:
            written += self._write_native_samples(native_samples, replay)
            replay.flush()
        if self.control is not None and self.control.cancel_path.exists():
            raise TrainingCancelled("deep_ai_v3_cancelled")
        errors = [row for row in games if not bool(row.get("success"))]
        structural_errors = [
            row for row in errors
            if str(row.get("error", ""))
                not in {"v3_actor_decision_cap", "v3_actor_cancelled"}
        ]
        if errors and self.control is not None:
            failure_path = self.control.run_dir / "actor-failures-v3.jsonl"
            with failure_path.open("a", encoding="utf-8", newline="\n") as handle:
                for row in errors:
                    handle.write(json.dumps({
                        "schema": "ptcg_deep_actor_failure_v3",
                        "time": time.time(),
                        **row,
                    }, ensure_ascii=False, sort_keys=True) + "\n")
                handle.flush()
                os.fsync(handle.fileno())
        if self.config.strict and structural_errors:
            first = structural_errors[0]
            raise RuntimeError(
                "v3_actor_batch_failed:"
                f"{len(structural_errors)}:"
                f"{first.get('game_id')}:{first.get('error')}"
            )
        return {
            "games": games,
            "game_count": len(games),
            "failed_games": len(errors),
            "structural_errors": len(structural_errors),
            "failure_records": errors,
            "samples": written if replay is not None else int(
                native_samples.get("actor", np.empty(0)).size
            ),
            "written_samples": written,
            "native": dict(self.pool.metrics()),
            "inference": self.broker.metrics,
        }

    def _sample_writer(
        self,
        replay: ReplayStoreV3,
        actors_done: threading.Event,
        state: dict[str, Any],
    ) -> None:
        try:
            while True:
                arrays = self.batch.drain_samples()
                count = self._write_native_samples(arrays, replay)
                state["samples"] = int(state["samples"]) + count
                if actors_done.is_set():
                    # One final drain closes the race with the last actor.
                    arrays = self.batch.drain_samples()
                    state["samples"] = int(state["samples"]) + self._write_native_samples(
                        arrays, replay
                    )
                    replay.flush()
                    return
                actors_done.wait(0.25)
        except BaseException as exc:
            state["error"] = exc
            self.pool.cancel()

    def _control_monitor(self, stopped: threading.Event) -> None:
        paused = False
        while not stopped.wait(0.1):
            if self.control is None:
                continue
            try:
                if self.control.cancel_path.exists():
                    self.pool.cancel()
                    return
                should_pause = self.control.pause_path.exists()
                if should_pause and not paused:
                    self.pool.pause()
                    self.control.status("paused")
                    paused = True
                elif not should_pause and paused:
                    self.pool.resume()
                    self.control.status("running")
                    paused = False
            except TrainingCancelled:
                self.pool.cancel()
                return

    @staticmethod
    def _write_native_samples(
        arrays: dict[str, Any],
        replay: ReplayStoreV3,
    ) -> int:
        count = int(np.asarray(arrays.get("actor", ())).size)
        game_ids = list(arrays.get("game_ids", ()))
        written = 0
        for index in range(count):
            candidate_count = int(np.asarray(arrays["candidate_mask"])[index].sum())
            information_set = EncodedInformationSetV3(
                np.ascontiguousarray(arrays["state_global"][index], dtype=np.float32),
                np.ascontiguousarray(arrays["entity_numeric"][index], dtype=np.float32),
                np.ascontiguousarray(arrays["entity_card_ids"][index], dtype=np.int64),
                np.ascontiguousarray(arrays["entity_type_ids"][index], dtype=np.int64),
                np.ascontiguousarray(arrays["entity_mask"][index], dtype=np.bool_),
                np.int64(arrays["actor_deck_id"][index]),
                np.int64(arrays["opponent_deck_id"][index]),
            )
            candidates = EncodedCandidatesV3(
                np.ascontiguousarray(
                    arrays["candidate_numeric"][index, :candidate_count],
                    dtype=np.float32,
                ),
                np.ascontiguousarray(
                    arrays["candidate_card_ids"][index, :candidate_count],
                    dtype=np.int64,
                ),
                np.ascontiguousarray(
                    arrays["candidate_type_ids"][index, :candidate_count],
                    dtype=np.int64,
                ),
                np.ascontiguousarray(
                    arrays["candidate_refs"][index, :candidate_count],
                    dtype=np.int64,
                ),
                np.ones(candidate_count, dtype=np.bool_),
            )
            source_id = int(arrays["source"][index])
            added, _path = replay.add_if_missing(
                ReplaySampleV3(
                    information_set,
                    candidates,
                    np.ascontiguousarray(
                        arrays["policy_target"][index, :candidate_count],
                        dtype=np.float32,
                    ),
                    np.ascontiguousarray(arrays["wdl_target"][index], dtype=np.float32),
                    str(game_ids[index]),
                    int(arrays["game_seed"][index]),
                    int(arrays["ply"][index]),
                    int(arrays["actor"][index]),
                    int(arrays["actor_deck_id"][index]),
                    int(arrays["opponent_deck_id"][index]),
                    int(arrays["model_version"][index]),
                    int(arrays["cycle"][index]),
                    int(arrays["phase_bucket"][index]),
                    SOURCE_NAMES.get(source_id, "self_play"),
                )
            )
            written += int(added)
        return written
