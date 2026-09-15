"""Frozen model snapshots and the learned-model evaluation adapter."""
from __future__ import annotations

import copy
import hashlib
import json
import os
import platform
from dataclasses import asdict, replace
from pathlib import Path
from typing import Any, Callable, Sequence

from .actor_v3 import ActorConfigV3, GameTaskV3, NativeActorServiceV3
from .challenge_arena_build import sha256_file, write_json_atomic
from .evaluation import evaluate
from .evaluation_challenge import evaluation_code_hash
from .evaluation_fairness import canonical_hash
from .evaluation_protocol import COMPARISON_ROLES, EvaluationProtocol, EvaluationTask
from .evaluation_store import cohort_for_output


def model_content_hash(model: Any) -> str:
    import torch
    digest = hashlib.sha256()
    digest.update(canonical_hash(model.config_dict()).encode("ascii"))
    for name, value in sorted(model.state_dict().items()):
        tensor = value.detach().cpu().contiguous()
        digest.update(canonical_hash([name, str(tensor.dtype), list(tensor.shape)]).encode("ascii"))
        digest.update(tensor.reshape(-1).view(torch.uint8).numpy().tobytes())
    return digest.hexdigest()


def load_or_freeze_anchor(root: Path, champion: Any, version: int) -> Any:
    from safetensors.torch import load_file, save_file
    from .model_v3 import create_model
    import torch
    path = root / "anchor.json"
    if path.exists():
        metadata = json.loads(path.read_text(encoding="utf-8"))
        weights = root / "model.safetensors"
        if metadata.get("schema") != "ptcg.ai_evaluation.anchor/1" or sha256_file(weights) != metadata.get("file_sha256"):
            raise ValueError("evaluation_anchor_checksum_mismatch")
        # Creating a container for frozen weights must not consume training RNG.
        with torch.random.fork_rng(devices=[]):
            model = create_model(**metadata["model_config"])
        model.load_state_dict(load_file(str(weights), device="cpu"), strict=True)
        if model_content_hash(model) != metadata["content_hash"]:
            raise ValueError("evaluation_anchor_content_mismatch")
        return model.cpu().eval()
    model = copy.deepcopy(champion).cpu().eval()
    root.mkdir(parents=True, exist_ok=True)
    temporary = root / "model.safetensors.tmp"
    save_file({name: tensor.detach().contiguous() for name, tensor in model.state_dict().items()}, str(temporary))
    os.replace(temporary, root / "model.safetensors")
    write_json_atomic(path, {"schema": "ptcg.ai_evaluation.anchor/1", "origin_champion_version": version,
                             "model_config": model.config_dict(), "content_hash": model_content_hash(model),
                             "file_sha256": sha256_file(root / "model.safetensors")})
    return model


def deep_game_result(result: dict[str, Any]) -> dict[str, Any]:
    """Translate the actor's training DTO into the evaluation executor contract."""
    row = dict(result)
    for native, evaluation in (("game_id", "task_id"), ("deck_a", "candidate_deck"),
                               ("deck_b", "baseline_deck"), ("seed", "game_seed"),
                               ("seat_a", "candidate_seat"), ("winner", "winner_seat"),
                               ("state_hash", "final_state_hash")):
        row[evaluation] = row.pop(native)
    row["final_state_hash"] = str(row["final_state_hash"])
    return row


class DeepEvaluationBackend:
    def __init__(self, *, models: dict[str, Any], config: ActorConfigV3, device: str,
                 control: Any = None, service_factory: Any = NativeActorServiceV3):
        import torch
        os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")
        self.torch = torch
        self.previous_deterministic = torch.are_deterministic_algorithms_enabled()
        self.previous_warn_only = torch.is_deterministic_algorithms_warn_only_enabled()
        self.previous_tf32 = torch.backends.cuda.matmul.allow_tf32
        torch.use_deterministic_algorithms(True)
        torch.backends.cuda.matmul.allow_tf32 = False
        self.models = {index: copy.deepcopy(models[role]).cpu().float().eval()
                       for index, role in enumerate(("candidate", "champion", "anchor"))}
        self.slots = {"candidate": 0, "champion": 1, "anchor": 2}
        self.config = replace(config, training=False, strict=False, dirichlet_epsilon=0.0,
                              max_inflight_leaves=1, inference_amp=False,
                              inference_fixed_batch_size=32, progress_timeout_ms=120000)
        self.device, self.control = device, control
        self.factory = service_factory
        self.service = None
        self.starts = 0
        self.last_metrics: dict[str, Any] = {}

    def run(self, tasks: Sequence[EvaluationTask], *,
            on_games: Callable[[list[dict[str, Any]]], None], isolated: bool = False) -> None:
        service = None if isolated else self.service
        if service is None:
            config = replace(self.config, concurrent_games=1, search_slots=1) if isolated else self.config
            service = self.factory(self.models, device=self.device, config=config, control=self.control)
            self.starts += 1
            if not isolated:
                self.service = service
        native_tasks = []
        for task in tasks:
            left, right = COMPARISON_ROLES[task.comparison]
            slots = [self.slots[right], self.slots[right]]
            slots[task.candidate_seat] = self.slots[left]
            native_tasks.append(GameTaskV3(task.task_id, 0, task.candidate_deck, task.baseline_deck,
                                           task.game_seed, task.candidate_seat, task.first_player,
                                           tuple(slots), (0, 0), task.max_decisions))
        try:
            routes = {task.game_id: task.model_slots for task in native_tasks}
            def collect(rows: list[dict[str, Any]]) -> None:
                for row in rows:
                    if tuple(row.get("model_slots", ())) != routes.get(row.get("game_id")):
                        raise ValueError("evaluation_model_route_mismatch")
                on_games([deep_game_result(row) for row in rows])
            result = service.run(native_tasks, on_games=collect)
            self.last_metrics = dict(result.get("inference", {}))
            if getattr(service, "timed_out", False) and not isolated:
                self.service = None
                service.close()
        finally:
            if isolated:
                service.close()

    def performance(self) -> dict[str, Any]:
        return {"service_starts": self.starts, "device": self.device, "precision": "float32",
                "fixed_inference_batch": 32, "inflight_leaves": 1,
                "inference": self.last_metrics, "gating": False}

    def close(self) -> None:
        try:
            if self.service is not None:
                self.service.close()
                self.service = None
        finally:
            self.torch.use_deterministic_algorithms(self.previous_deterministic, warn_only=self.previous_warn_only)
            self.torch.backends.cuda.matmul.allow_tf32 = self.previous_tf32


def run_deep_evaluation(*, candidate: Any, champion: Any, anchor: Any, config: ActorConfigV3,
                        device: str, output: Path, seed: int, cycle: int, maximum_candidates: int,
                        maximum_replicates: int, max_decisions: int, mode: str,
                        control: Any = None, on_report: Callable | None = None,
                        decks: Sequence[str] | None = None) -> dict[str, Any]:
    os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")
    from .challenge_arena import native_binding_build_info, load_product_payloads
    from .v3_contract import RELEASE_DECKS
    import torch
    catalog, deck_data, _ = load_product_payloads()
    binding = native_binding_build_info()
    models = {"candidate": candidate, "champion": champion, "anchor": anchor}
    participants = {role: {"content_hash": model_content_hash(model), "engine": "infoset_puct_v3"}
                    for role, model in models.items()}
    # Scheduling throughput is execution metadata, not a change to the
    # evaluation's deterministic, fixed-work decision contract.
    effective = replace(config, training=False, strict=False, dirichlet_epsilon=0.0,
                         max_inflight_leaves=1, inference_amp=False, inference_fixed_batch_size=32,
                         progress_timeout_ms=120000)
    work = {key: value for key, value in asdict(effective).items() if key not in {
        "concurrent_games", "search_slots", "inference_target_batch", "inference_max_batch", "inference_coalesce_ms"}}
    campaign_path = output.parent / "evaluation-campaign.json"
    campaign = {"schema": "ptcg.ai_evaluation.campaign/1", "maximum_candidates": maximum_candidates,
                "family_alpha": 0.05, "seed": seed}
    if campaign_path.exists():
        if json.loads(campaign_path.read_text(encoding="utf-8")) != campaign:
            raise ValueError("evaluation_campaign_changed_error_budget_cannot_reset")
    else:
        write_json_atomic(campaign_path, campaign)
    protocol = EvaluationProtocol.create(
        backend="deep_v3", mode=mode, decks=tuple(decks or RELEASE_DECKS), participants=participants,
        context={"rules_hash": canonical_hash(catalog), "decks_hash": canonical_hash(deck_data),
                 "binding_hash": binding["binding_sha256"], "evaluation_code_hash": evaluation_code_hash(),
                 "rules_profile": "CN_MAINLAND_3_1_0", "apply_type_matchups": False,
                 "time_budget_ms": 0, "work": work, "device": device,
                 "device_name": torch.cuda.get_device_name(device) if device.startswith("cuda") else "cpu",
                 "platform": platform.platform(), "processor": platform.processor(),
                 "torch_threads": torch.get_num_threads(), "interop_threads": torch.get_num_interop_threads(),
                 "cuda_version": torch.version.cuda,
                 "cublas_workspace_config": os.environ["CUBLAS_WORKSPACE_CONFIG"],
                 "torch_version": str(torch.__version__), "precision": "float32", "fixed_batch": 32},
        seed=seed, cohort=cohort_for_output(output), maximum_replicates=maximum_replicates,
        minimum_replicates=5 if mode == "promotion" else 1, max_decisions=max_decisions,
        maximum_candidates=maximum_candidates, candidate_index=cycle - 1,
    )
    backend = DeepEvaluationBackend(models=models, config=effective, device=device, control=control)
    result = evaluate(protocol, backend, output=output, cache_root=output.parent / "evaluation-cache",
                      on_report=on_report)
    # Verify again before a caller is allowed to promote the live learner.
    if model_content_hash(candidate) != participants["candidate"]["content_hash"]:
        raise ValueError("evaluation_candidate_changed_during_run")
    return result.summary
