"""Contiguous batched inference utilities for AlphaZero v2."""
from __future__ import annotations

import queue
import threading
import time
from dataclasses import dataclass
from typing import Any, Protocol, Sequence

import numpy as np

from engine.actions import ChoiceOption
from engine.ai.dl.infoset_encoder import (
    EncodedCandidates,
    EncodedInformationSet,
    InformationSetEncoderV7,
)
from engine.ai.observation import Observation


class CandidateLike(Protocol):
    payload: Any
    choice_option: ChoiceOption | None


@dataclass(frozen=True)
class PolicyValue:
    priors: np.ndarray
    wdl: np.ndarray

    @property
    def value(self) -> float:
        return float(self.wdl[0] - self.wdl[2])

    def validate(self, candidate_count: int) -> None:
        if self.priors.shape != (candidate_count,):
            raise ValueError("policy_size_mismatch")
        if self.wdl.shape != (3,):
            raise ValueError("wdl_size_mismatch")
        if not np.isfinite(self.priors).all() or not np.isfinite(self.wdl).all():
            raise ValueError("non_finite_policy_value")
        if np.any(self.priors < 0.0):
            raise ValueError("negative_policy_probability")
        if not np.isclose(float(self.priors.sum()), 1.0, atol=1e-5):
            raise ValueError("policy_not_normalized")
        if not np.isclose(float(self.wdl.sum()), 1.0, atol=1e-5):
            raise ValueError("wdl_not_normalized")


class PolicyValueEvaluator(Protocol):
    def evaluate(
        self,
        observation: Observation,
        candidates: Sequence[CandidateLike],
        actor_deck_key: str | None,
    ) -> PolicyValue: ...


@dataclass
class _Request:
    information_set: EncodedInformationSet
    candidates: EncodedCandidates
    done: threading.Event
    result: PolicyValue | None = None
    error: BaseException | None = None


def _pad_candidates(
    rows: Sequence[EncodedCandidates],
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    batch = len(rows)
    max_candidates = max(row.count for row in rows)
    numeric = np.zeros((batch, max_candidates, 32), dtype=np.float32)
    cards = np.zeros((batch, max_candidates), dtype=np.int64)
    types = np.zeros((batch, max_candidates), dtype=np.int64)
    refs = np.zeros((batch, max_candidates, 4), dtype=np.int64)
    mask = np.zeros((batch, max_candidates), dtype=np.bool_)
    for index, row in enumerate(rows):
        count = row.count
        numeric[index, :count] = row.numeric
        cards[index, :count] = row.card_ids
        types[index, :count] = row.type_ids
        refs[index, :count] = row.refs
        mask[index, :count] = row.mask
    return tuple(
        np.ascontiguousarray(value)
        for value in (numeric, cards, types, refs, mask)
    )


class BatchedTorchEvaluator:
    """Thread-safe GPU broker that coalesces independent leaf requests."""

    def __init__(
        self,
        model: Any,
        *,
        device: str = "cuda",
        target_batch_size: int = 128,
        max_batch_size: int = 256,
        coalesce_ms: float = 2.0,
        amp: bool = True,
        encoder: InformationSetEncoderV7 | None = None,
    ) -> None:
        import torch

        self.torch = torch
        self.model = model.to(device)
        self.model.eval()
        self.device = str(device)
        self.target_batch_size = max(1, int(target_batch_size))
        self.max_batch_size = max(
            self.target_batch_size,
            int(max_batch_size),
        )
        self.coalesce_seconds = max(0.0, float(coalesce_ms)) / 1000.0
        self.amp = bool(amp) and self.device.startswith("cuda")
        self.encoder = encoder or InformationSetEncoderV7()
        self._queue: queue.Queue[_Request | None] = queue.Queue()
        self._closed = threading.Event()
        self._thread = threading.Thread(
            target=self._worker,
            name="alphazero-v2-inference",
            daemon=True,
        )
        self.batch_count = 0
        self.request_count = 0
        self.max_observed_batch = 0
        self.total_inference_seconds = 0.0
        self._thread.start()

    def close(self) -> None:
        if self._closed.is_set():
            return
        self._closed.set()
        self._queue.put(None)
        self._thread.join(timeout=10.0)
        if self._thread.is_alive():
            raise RuntimeError("inference_broker_did_not_stop")

    def __enter__(self) -> "BatchedTorchEvaluator":
        return self

    def __exit__(self, *_args: Any) -> None:
        self.close()

    def evaluate(
        self,
        observation: Observation,
        candidates: Sequence[CandidateLike],
        actor_deck_key: str | None,
    ) -> PolicyValue:
        if self._closed.is_set():
            raise RuntimeError("inference_broker_closed")
        information_set = self.encoder.encode_information_set(
            observation,
            actor_deck_key,
        )
        payloads = [candidate.payload for candidate in candidates]
        choice_options = [candidate.choice_option for candidate in candidates]
        if all(option is not None for option in choice_options):
            request_type = str(getattr(candidates[0], "request_type", "select"))
            encoded_candidates = self.encoder.encode_choices(
                observation,
                request_type,
                [option for option in choice_options if option is not None],
            )
        else:
            encoded_candidates = self.encoder.encode_actions(
                observation,
                payloads,
            )
        request = _Request(
            information_set=information_set,
            candidates=encoded_candidates,
            done=threading.Event(),
        )
        self._queue.put(request)
        request.done.wait()
        if request.error is not None:
            raise request.error
        if request.result is None:
            raise RuntimeError("inference_request_missing_result")
        return request.result

    def _worker(self) -> None:
        while not self._closed.is_set():
            first = self._queue.get()
            if first is None:
                return
            batch = [first]
            deadline = time.perf_counter() + self.coalesce_seconds
            while len(batch) < self.max_batch_size:
                if len(batch) >= self.target_batch_size:
                    break
                remaining = deadline - time.perf_counter()
                if remaining <= 0.0:
                    break
                try:
                    item = self._queue.get(timeout=remaining)
                except queue.Empty:
                    break
                if item is None:
                    self._closed.set()
                    break
                batch.append(item)
            self._run_batch(batch)

    def _run_batch(self, requests: Sequence[_Request]) -> None:
        started = time.perf_counter()
        try:
            info = [request.information_set for request in requests]
            candidate_rows = [request.candidates for request in requests]
            candidate_tensors = _pad_candidates(candidate_rows)
            arrays = (
                np.stack([row.state_global for row in info]),
                np.stack([row.entity_numeric for row in info]),
                np.stack([row.entity_card_ids for row in info]),
                np.stack([row.entity_type_ids for row in info]),
                *candidate_tensors,
                np.asarray(
                    [row.actor_deck_id for row in info],
                    dtype=np.int64,
                ),
                np.asarray(
                    [row.opponent_deck_id for row in info],
                    dtype=np.int64,
                ),
            )
            tensors = [
                self.torch.from_numpy(np.ascontiguousarray(array)).to(
                    self.device,
                    non_blocking=True,
                )
                for array in arrays
            ]
            autocast_device = "cuda" if self.device.startswith("cuda") else "cpu"
            with self.torch.inference_mode(), self.torch.autocast(
                device_type=autocast_device,
                enabled=self.amp,
            ):
                policy_logits, wdl_logits = self.model(*tensors)
                policy = self.torch.softmax(
                    policy_logits.float(),
                    dim=-1,
                ).cpu().numpy()
                wdl = self.torch.softmax(
                    wdl_logits.float(),
                    dim=-1,
                ).cpu().numpy()
            for index, request in enumerate(requests):
                count = request.candidates.count
                result = PolicyValue(
                    priors=np.ascontiguousarray(
                        policy[index, :count],
                        dtype=np.float32,
                    ),
                    wdl=np.ascontiguousarray(
                        wdl[index],
                        dtype=np.float32,
                    ),
                )
                result.validate(count)
                request.result = result
        except BaseException as exc:
            for request in requests:
                request.error = exc
        finally:
            elapsed = time.perf_counter() - started
            self.batch_count += 1
            self.request_count += len(requests)
            self.max_observed_batch = max(
                self.max_observed_batch,
                len(requests),
            )
            self.total_inference_seconds += elapsed
            for request in requests:
                request.done.set()


class NativeBatchTorchBroker:
    """GPU inference service for C++ search jobs.

    The native batch owns request IDs and contiguous encoder-v7 storage. This
    broker only transfers whole batches to the device and returns raw logits;
    no per-position Python object graph is reconstructed.
    """

    def __init__(
        self,
        native_batch: Any,
        model: Any,
        *,
        device: str = "cuda",
        target_batch_size: int = 128,
        max_batch_size: int = 256,
        poll_wait_ms: int = 2,
        amp: bool = True,
    ) -> None:
        import torch

        self.torch = torch
        self.native_batch = native_batch
        self.model = model.to(device)
        self.model.eval()
        self.device = str(device)
        self.target_batch_size = max(1, int(target_batch_size))
        self.max_batch_size = max(
            self.target_batch_size,
            int(max_batch_size),
        )
        self.poll_wait_ms = max(1, int(poll_wait_ms))
        self.amp = bool(amp) and self.device.startswith("cuda")
        self._closed = threading.Event()
        self._thread = threading.Thread(
            target=self._worker,
            name="alphazero-v2-native-inference",
            daemon=True,
        )
        self.error: BaseException | None = None
        self.batch_count = 0
        self.request_count = 0
        self.max_observed_batch = 0
        self.max_queue_depth = 0
        self.total_inference_seconds = 0.0
        self._thread.start()

    def close(self) -> None:
        if self._closed.is_set():
            return
        self._closed.set()
        self._thread.join(timeout=10.0)
        if self._thread.is_alive():
            raise RuntimeError("native_inference_broker_did_not_stop")
        if self.error is not None:
            raise RuntimeError("native_inference_broker_failed") from self.error

    def __enter__(self) -> "NativeBatchTorchBroker":
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
                started = time.perf_counter()
                inputs = [
                    self._device_tensor(arrays[name])
                    for name in (
                        "state_global",
                        "entity_numeric",
                        "entity_card_ids",
                        "entity_type_ids",
                        "candidate_numeric",
                        "candidate_card_ids",
                        "candidate_type_ids",
                        "candidate_refs",
                        "candidate_mask",
                        "actor_deck_id",
                        "opponent_deck_id",
                    )
                ]
                autocast_device = (
                    "cuda" if self.device.startswith("cuda") else "cpu"
                )
                with self.torch.inference_mode(), self.torch.autocast(
                    device_type=autocast_device,
                    enabled=self.amp,
                ):
                    policy_logits, wdl_logits = self.model(*inputs)
                policy_output = np.ascontiguousarray(
                    policy_logits.detach().float().cpu().numpy(),
                    dtype=np.float32,
                )
                wdl_output = np.ascontiguousarray(
                    wdl_logits.detach().float().cpu().numpy(),
                    dtype=np.float32,
                )
                self.native_batch.submit_inference(
                    request_ids,
                    policy_output,
                    wdl_output,
                    arrays["candidate_mask"],
                )
                elapsed = time.perf_counter() - started
                count = int(request_ids.size)
                self.batch_count += 1
                self.request_count += count
                self.max_observed_batch = max(
                    self.max_observed_batch,
                    count,
                )
                self.total_inference_seconds += elapsed
        except BaseException as exc:
            self.error = exc
            self._closed.set()
            self.native_batch.close()


class UniformEvaluator:
    """Deterministic test/bootstrap evaluator with no heuristic rollout."""

    def evaluate(
        self,
        observation: Observation,
        candidates: Sequence[CandidateLike],
        actor_deck_key: str | None,
    ) -> PolicyValue:
        del observation, actor_deck_key
        count = len(candidates)
        result = PolicyValue(
            priors=np.full(count, 1.0 / count, dtype=np.float32),
            wdl=np.asarray((0.0, 1.0, 0.0), dtype=np.float32),
        )
        result.validate(count)
        return result
