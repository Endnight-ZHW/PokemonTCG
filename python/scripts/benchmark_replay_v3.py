from __future__ import annotations

import argparse
import concurrent.futures
import ctypes
import json
import math
import os
import sys
import tempfile
import time
from pathlib import Path

PYTHON_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.replay_v3 import (  # noqa: E402
    ReplayEntryV3,
    ReplayStoreV3,
)


def _rss_bytes() -> int:
    if sys.platform == "win32":
        size_t = ctypes.c_size_t

        class Counters(ctypes.Structure):
            _fields_ = [
                ("cb", ctypes.c_ulong),
                ("PageFaultCount", ctypes.c_ulong),
                ("PeakWorkingSetSize", size_t),
                ("WorkingSetSize", size_t),
                ("QuotaPeakPagedPoolUsage", size_t),
                ("QuotaPagedPoolUsage", size_t),
                ("QuotaPeakNonPagedPoolUsage", size_t),
                ("QuotaNonPagedPoolUsage", size_t),
                ("PagefileUsage", size_t),
                ("PeakPagefileUsage", size_t),
                ("PrivateUsage", size_t),
            ]

        counters = Counters()
        counters.cb = ctypes.sizeof(counters)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        psapi = ctypes.WinDLL("psapi", use_last_error=True)
        kernel32.GetCurrentProcess.restype = ctypes.c_void_p
        psapi.GetProcessMemoryInfo.argtypes = (
            ctypes.c_void_p,
            ctypes.POINTER(Counters),
            ctypes.c_ulong,
        )
        psapi.GetProcessMemoryInfo.restype = ctypes.c_bool
        process = kernel32.GetCurrentProcess()
        if not psapi.GetProcessMemoryInfo(
            process,
            ctypes.byref(counters),
            counters.cb,
        ):
            raise OSError("GetProcessMemoryInfo failed")
        return int(counters.WorkingSetSize)
    statm = Path("/proc/self/statm")
    if statm.is_file():
        resident_pages = int(statm.read_text(encoding="ascii").split()[1])
        return resident_pages * int(os.sysconf("SC_PAGE_SIZE"))
    import resource

    value = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    return value if sys.platform == "darwin" else value * 1024


def _atomic_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=path.name + ".",
        suffix=".tmp",
        dir=path.parent,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def benchmark(args: argparse.Namespace) -> dict:
    store = ReplayStoreV3(args.replay.resolve(), seed=args.seed)
    replay = store.verify()
    before = _rss_bytes()
    shard_count = math.ceil(args.index_samples / 4096)
    paths = tuple(
        store.root / f"index-only-{index:08d}.safetensors"
        for index in range(shard_count)
    )
    index = [
        ReplayEntryV3(
            paths[(sample // 4096) % shard_count],
            sample % 4096,
            sample & 1,
            sample % 10,
            (sample // 10) % 10,
            sample % 4,
            sample // 25_000,
            sample // 25_000,
        )
        for sample in range(args.index_samples)
    ]
    index_rss = _rss_bytes()
    if len(index) != args.index_samples:
        raise RuntimeError("v3_index_benchmark_incomplete")

    batches = [
        store.sample_entries(args.batch_size, teacher_fraction=0.2)
        for _ in range(args.steps + 2)
    ]
    for entries in batches[:2]:
        store.collate(
            entries,
            device=args.device,
            pin_memory=True,
        )
    if args.device.startswith("cuda"):
        import torch

        torch.cuda.synchronize()

    load_seconds = 0.0

    def load(entries):
        load_started = time.perf_counter()
        batch = store.collate(
            entries,
            device=args.device,
            pin_memory=True,
        )
        return batch, time.perf_counter() - load_started

    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=2,
        thread_name_prefix="v3-replay-benchmark",
    ) as executor:
        iterator = iter(batches[2:])
        futures = []
        for _ in range(2):
            try:
                entries = next(iterator)
            except StopIteration:
                break
            futures.append(executor.submit(load, entries))
        while futures:
            future = futures.pop(0)
            _batch, duration = future.result()
            load_seconds += duration
            try:
                entries = next(iterator)
            except StopIteration:
                continue
            futures.append(executor.submit(load, entries))
    if args.device.startswith("cuda"):
        import torch

        torch.cuda.synchronize()
    elapsed = time.perf_counter() - started
    after_load = _rss_bytes()
    effective_loader_seconds = load_seconds / 2.0
    loader_rate = (
        args.steps * args.batch_size
        / max(effective_loader_seconds, 1e-9)
    )

    summary = json.loads(args.summary.read_text(encoding="utf-8"))
    learner_rates = [
        float(row["training"]["learner_samples_per_second"])
        for row in summary.get("cycles", ())
    ]
    learner_rate = max(learner_rates, default=0.0)
    ratio = loader_rate / max(learner_rate, 1e-9)
    rss_limit = 12 * 1024**3
    payload = {
        "schema": "ptcg_deep_replay_benchmark_v3",
        "replay": replay,
        "index": {
            "samples": args.index_samples,
            "logical_shards": shard_count,
            "rss_before_bytes": before,
            "rss_index_bytes": index_rss,
            "rss_after_loader_bytes": after_load,
            "rss_peak_observed_bytes": max(before, index_rss, after_load),
            "rss_limit_bytes": rss_limit,
            "gate_under_12_gib": max(before, index_rss, after_load) <= rss_limit,
        },
        "loader": {
            "device": args.device,
            "batch_size": args.batch_size,
            "steps": args.steps,
            "double_prefetch": True,
            "elapsed_seconds": elapsed,
            "worker_load_seconds": load_seconds,
            "effective_loader_seconds": effective_loader_seconds,
            "wall_samples_per_second": (
                args.steps * args.batch_size / max(elapsed, 1e-9)
            ),
            "samples_per_second": loader_rate,
            "pilot_learner_samples_per_second": learner_rate,
            "loader_to_learner_ratio": ratio,
            "gate_at_least_2x": ratio >= 2.0,
        },
    }
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--replay", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--index-samples", type=int, default=500_000)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--steps", type=int, default=50)
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    payload = benchmark(args)
    if args.output is not None:
        _atomic_json(args.output.resolve(), payload)
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if (
        payload["index"]["gate_under_12_gib"]
        and payload["loader"]["gate_at_least_2x"]
    ) else 1


if __name__ == "__main__":
    raise SystemExit(main())
