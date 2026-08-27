"""Run a command and sample peak RSS for matching descendant processes."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

import psutil


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument("--include-name", default="godot")
    parser.add_argument("--sample-ms", type=int, default=25)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = list(args.command)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        parser.error("a command is required after --")

    started = time.perf_counter()
    process = subprocess.Popen(command, cwd=args.cwd.resolve())
    root = psutil.Process(process.pid)
    include = args.include_name.casefold()
    peak_rss = 0
    peak_processes = 0
    samples = 0
    while process.poll() is None:
        rss = 0
        matched = 0
        try:
            descendants = [root, *root.children(recursive=True)]
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            descendants = []
        for descendant in descendants:
            try:
                if include and include not in descendant.name().casefold():
                    continue
                rss += int(descendant.memory_info().rss)
                matched += 1
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
        peak_rss = max(peak_rss, rss)
        peak_processes = max(peak_processes, matched)
        samples += 1
        time.sleep(max(0.005, args.sample_ms / 1000.0))
    return_code = process.wait()
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    payload = {
        "schema": "ptcg_process_tree_rss/1",
        "command": command,
        "cwd": str(args.cwd.resolve()),
        "include_name": args.include_name,
        "sample_interval_ms": max(5, args.sample_ms),
        "samples": samples,
        "peak_matching_processes": peak_processes,
        "peak_rss_bytes": peak_rss,
        "elapsed_ms": elapsed_ms,
        "exit_code": return_code,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as stream:
        json.dump(payload, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    return return_code


if __name__ == "__main__":
    sys.exit(main())
