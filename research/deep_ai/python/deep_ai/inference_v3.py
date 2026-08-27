"""Multi-model GPU batching for the native Deep AI v3 actor pool."""
from __future__ import annotations

import threading
import time
from typing import Any, Mapping

import numpy as np


class NativeBatchTorchBrokerV3:
    def __init__(
        self,
        native_batch: Any,
        models: Mapping[int, Any],
        *,
        device: str = "cuda",
        target_batch_size: int = 128,
        max_batch_size: int = 256,
        poll_wait_ms: int = 2,
        amp: bool = True,
    ) -> None:
        import torch

        if not models:
            raise ValueError("v3_inference_models_empty")
        self.torch = torch
        self.native_batch = native_batch
        self.models = {
            int(slot): model.to(device).eval()
            for slot, model in models.items()
        }
        self.device = str(device)
        self.target_batch_size = max(1, int(target_batch_size))
        self.max_batch_size = max(self.target_batch_size, int(max_batch_size))
        self.poll_wait_ms = max(1, int(poll_wait_ms))
        self.amp = bool(amp) and self.device.startswith("cuda")
        self._closed = threading.Event()
        self._thread = threading.Thread(
            target=self._worker,
            name="deep-ai-v3-inference",
            daemon=True,
        )
        self.error: BaseException | None = None
        self.batch_count = 0
        self.request_count = 0
        self.model_batch_count = 0
        self.max_observed_batch = 0
        self.max_queue_depth = 0
        self.total_inference_seconds = 0.0
        self._thread.start()

    def register_model(self, slot: int, model: Any) -> None:
        if not self._closed.is_set():
            raise RuntimeError("v3_model_registration_requires_stopped_broker")
        self.models[int(slot)] = model.to(self.device).eval()

    def close(self) -> None:
        if self._closed.is_set():
            if self.error is not None:
                raise RuntimeError("v3_inference_broker_failed") from self.error
            return
        self._closed.set()
        self._thread.join(timeout=30.0)
        if self._thread.is_alive():
            raise RuntimeError("v3_inference_broker_did_not_stop")
        if self.error is not None:
            raise RuntimeError("v3_inference_broker_failed") from self.error

    def __enter__(self) -> "NativeBatchTorchBrokerV3":
        return self

    def __exit__(self, *_args: Any) -> None:
        self.close()

    def _device_tensor(self, array: np.ndarray):
        tensor = self.torch.from_numpy(np.ascontiguousarray(array))
        if self.device.startswith("cuda"):
            tensor = tensor.pin_memory()
        return tensor.to(self.device, non_blocking=True)

    def _worker(self) -> None:
        try:
            while not self._closed.is_set():
                self.max_queue_depth = max(
                    self.max_queue_depth,
                    int(self.native_batch.pending_requests),
                )
                arrays = self.native_batch.poll_inference(
                    self.max_batch_size,
                    self.poll_wait_ms,
                    self.target_batch_size,
                    self.poll_wait_ms,
                )
                request_ids = arrays["request_ids"]
                if request_ids.size == 0:
                    if bool(self.native_batch.closed):
                        return
                    continue
                encoder_versions = np.asarray(
                    arrays.get("encoder_version", ()),
                    dtype=np.int32,
                )
                if (
                    encoder_versions.shape != request_ids.shape
                    or not np.all(encoder_versions == 8)
                ):
                    raise RuntimeError("v3_inference_encoder_mismatch")
                started = time.perf_counter()
                model_slots = np.asarray(arrays["model_slots"], dtype=np.int32)
                policy_output = np.zeros_like(
                    arrays["candidate_mask"],
                    dtype=np.float32,
                )
                wdl_output = np.zeros((request_ids.size, 3), dtype=np.float32)
                for slot in sorted(set(int(value) for value in model_slots)):
                    model = self.models.get(slot)
                    if model is None:
                        raise RuntimeError(f"v3_inference_model_slot_missing:{slot}")
                    indices = np.flatnonzero(model_slots == slot)
                    inputs = [
                        self._device_tensor(arrays[name][indices])
                        for name in (
                            "state_global",
                            "entity_numeric",
                            "entity_card_ids",
                            "entity_type_ids",
                            "entity_mask",
                            "candidate_numeric",
                            "candidate_card_ids",
                            "candidate_type_ids",
                            "candidate_refs",
                            "candidate_mask",
                            "actor_deck_id",
                            "opponent_deck_id",
                        )
                    ]
                    with self.torch.inference_mode(), self.torch.autocast(
                        device_type="cuda" if self.device.startswith("cuda") else "cpu",
                        enabled=self.amp,
                        dtype=self.torch.bfloat16,
                    ):
                        policy_logits, wdl_logits = model(*inputs)
                    policy_output[indices] = (
                        policy_logits.detach().float().cpu().numpy()
                    )
                    wdl_output[indices] = (
                        wdl_logits.detach().float().cpu().numpy()
                    )
                    self.model_batch_count += 1
                self.native_batch.submit_inference(
                    request_ids,
                    np.ascontiguousarray(policy_output),
                    np.ascontiguousarray(wdl_output),
                    arrays["candidate_mask"],
                )
                elapsed = time.perf_counter() - started
                count = int(request_ids.size)
                self.batch_count += 1
                self.request_count += count
                self.max_observed_batch = max(self.max_observed_batch, count)
                self.total_inference_seconds += elapsed
        except BaseException as exc:
            self.error = exc
            self._closed.set()
            self.native_batch.close()

    @property
    def metrics(self) -> dict[str, float | int]:
        return {
            "inference_batches": self.batch_count,
            "model_batches": self.model_batch_count,
            "inference_requests": self.request_count,
            "average_batch": self.request_count / max(1, self.batch_count),
            "max_batch": self.max_observed_batch,
            "max_queue": self.max_queue_depth,
            "inference_seconds": self.total_inference_seconds,
        }
