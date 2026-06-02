from __future__ import annotations

import os
import signal
import subprocess
from typing import Any


def terminate_process_tree(process: Any, *, timeout: float = 3.0) -> None:
    """Terminate a subprocess and its descendants without killing unrelated processes."""
    if process is None:
        return

    pid = getattr(process, "pid", None)
    if not pid:
        return

    if os.name == "nt":
        try:
            subprocess.run(
                ["taskkill", "/PID", str(pid), "/T", "/F"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=max(1.0, timeout),
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            pass
        try:
            process.wait(timeout=timeout)
        except (OSError, subprocess.TimeoutExpired):
            pass
        return

    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
    except OSError:
        try:
            if process.poll() is None:
                process.terminate()
        except OSError:
            pass

    try:
        process.wait(timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        try:
            os.killpg(os.getpgid(pid), signal.SIGKILL)
        except OSError:
            try:
                if process.poll() is None:
                    process.kill()
            except OSError:
                pass
        try:
            process.wait(timeout=timeout)
        except (OSError, subprocess.TimeoutExpired):
            pass
