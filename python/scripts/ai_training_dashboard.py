"""Loopback-only Deep AI training dashboard with JSON/SSE APIs."""
from __future__ import annotations

import argparse
import json
import mimetypes
import os
import secrets
import subprocess
import sys
import threading
import time
import urllib.parse
import webbrowser
from dataclasses import asdict
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
STATIC_ROOT = REPO_ROOT / "tools" / "ai_training_dashboard"
sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.trainer_v3 import AlphaZeroV3Config  # noqa: E402
from engine.ai.dl.run_store import (  # noqa: E402
    ACTIVE_STATUSES,
    atomic_write_bytes,
    atomic_write_json,
    create_run_layout,
    process_is_alive,
    read_events,
    read_json,
    resolve_within,
    update_run,
    utc_now,
    validate_run_id,
)


API_PREFIX = "/api/v1"
MAX_BODY_BYTES = 64 * 1024
HEARTBEAT_SECONDS = 2.0


class DashboardState:
    def __init__(self, repo_root: Path, runs_root: Path):
        self.repo_root = repo_root.resolve()
        self.runs_root = runs_root.resolve()
        self.runs_root.mkdir(parents=True, exist_ok=True)
        self.csrf_token = secrets.token_urlsafe(32)
        self.lock = threading.RLock()
        self.children: dict[str, subprocess.Popen[Any]] = {}
        self.log_handles: dict[str, tuple[Any, Any]] = {}
        self.reconcile()

    def _run_dir(self, run_id: str) -> Path:
        return resolve_within(self.runs_root, validate_run_id(run_id))

    def _read_run(self, run_id: str) -> dict[str, Any]:
        return read_json(self._run_dir(run_id) / "run.json")

    def _iter_runs(self) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        for path in self.runs_root.iterdir():
            if not path.is_dir() or not (path / "run.json").is_file():
                continue
            try:
                row = read_json(path / "run.json")
                validate_run_id(str(row.get("run_id", "")))
                rows.append(row)
            except (OSError, ValueError, json.JSONDecodeError):
                continue
        rows.sort(
            key=lambda row: str(row.get("created_at", "")),
            reverse=True,
        )
        return rows

    def _poll_children(self) -> None:
        for run_id, child in list(self.children.items()):
            return_code = child.poll()
            if return_code is None:
                continue
            self.children.pop(run_id, None)
            handles = self.log_handles.pop(run_id, ())
            for handle in handles:
                try:
                    handle.close()
                except OSError:
                    pass
            try:
                run = self._read_run(run_id)
            except OSError:
                continue
            if str(run.get("status", "")) in ACTIVE_STATUSES:
                update_run(
                    self._run_dir(run_id),
                    status="recoverable" if return_code else "completed",
                    pid=0,
                    resumable=True,
                    process_exit_code=int(return_code),
                )

    def reconcile(self) -> None:
        with self.lock:
            self._poll_children()
            for run in self._iter_runs():
                status = str(run.get("status", ""))
                pid = int(run.get("pid", 0) or 0)
                if status not in ACTIVE_STATUSES:
                    continue
                if process_is_alive(pid):
                    # The dashboard cannot adopt a Popen object after restart,
                    # but control files and event tailing remain fully attached.
                    continue
                update_run(
                    self._run_dir(str(run["run_id"])),
                    status="recoverable",
                    pid=0,
                    resumable=True,
                    recovery_reason="training_process_not_alive",
                )

    def active_run(self) -> dict[str, Any] | None:
        self.reconcile()
        for run in self._iter_runs():
            status = str(run.get("status", ""))
            pid = int(run.get("pid", 0) or 0)
            if status in ACTIVE_STATUSES and process_is_alive(pid):
                return run
        return None

    def list_runs(self) -> list[dict[str, Any]]:
        self.reconcile()
        return self._iter_runs()

    def get_run(self, run_id: str) -> dict[str, Any]:
        self.reconcile()
        return self._read_run(run_id)

    def _new_run_id(self, preset: str) -> str:
        return (
            time.strftime("%Y%m%d-%H%M%S")
            + f"-{preset}-{secrets.token_hex(3)}"
        )

    def create_run(self, payload: dict[str, Any]) -> dict[str, Any]:
        with self.lock:
            if self.active_run() is not None:
                raise RuntimeError("another_training_is_active")
            preset = str(payload.get("preset", "smoke")).strip().lower()
            if preset not in {"smoke", "pilot", "release"}:
                raise ValueError("preset must be smoke, pilot or release")
            seed = int(payload.get("seed", 17))
            smoke_deck = str(payload.get("deck", "fire"))
            allowed = {"preset", "seed", "deck"}
            unknown = sorted(set(payload) - allowed)
            if unknown:
                raise ValueError(
                    "unsupported run fields: " + ", ".join(unknown)
                )
            run_id = self._new_run_id(preset)
            teacher_replay = (
                self.repo_root
                / "python"
                / "data"
                / "ai_training"
                / "bootstrap-v3"
            )
            factory = (
                AlphaZeroV3Config.smoke
                if preset == "smoke"
                else AlphaZeroV3Config.pilot
                if preset == "pilot"
                else AlphaZeroV3Config
            )
            run_dir = create_run_layout(
                self.runs_root,
                run_id,
                run_payload={
                    "format_version": 3,
                    "trainer": "infoset_alphazero_v3",
                    "preset": preset,
                    "seed": seed,
                    "smoke_deck": smoke_deck,
                    "status": "created",
                    "pid": 0,
                    "resumable": False,
                    "config": asdict(
                        factory(
                            str(self.runs_root / run_id),
                            teacher_replay=(
                                str(teacher_replay)
                                if (teacher_replay / "manifest.json").is_file()
                                else ""
                            ),
                            seed=seed,
                        )
                    ),
                },
            )
            atomic_write_json(
                run_dir / "config.json",
                dict(read_json(run_dir / "run.json")["config"]),
            )
            self._launch_training(run_id, preset)
            return read_json(run_dir / "run.json")

    def _launch_training(self, run_id: str, preset: str) -> None:
        run_dir = self._run_dir(run_id)
        logs = run_dir / "logs"
        logs.mkdir(exist_ok=True)
        stdout = (logs / "trainer.stdout.log").open(
            "a", encoding="utf-8", buffering=1
        )
        stderr = (logs / "trainer.stderr.log").open(
            "a", encoding="utf-8", buffering=1
        )
        run = self._read_run(run_id)
        trainer = str(run.get("trainer", ""))
        if trainer != "infoset_alphazero_v3":
            stdout.close()
            stderr.close()
            raise RuntimeError(
                "unsupported_v2_training_run_use_v3_fresh_run"
            )
        command = [
            sys.executable,
            str(PYTHON_ROOT / "scripts" / "train_deep_ai_v3.py"),
            "train",
            "--preset",
            preset,
            "--output-dir",
            str(run_dir),
        ]
        teacher = (
            self.repo_root
            / "python"
            / "data"
            / "ai_training"
            / "bootstrap-v3"
        )
        if (teacher / "manifest.json").is_file():
            command.extend(["--teacher-replay", str(teacher)])
        command.extend(["--seed", str(int(run.get("seed", 17)))])
        creationflags = (
            getattr(subprocess, "CREATE_NO_WINDOW", 0)
            if os.name == "nt"
            else 0
        )
        try:
            child = subprocess.Popen(
                command,
                cwd=self.repo_root,
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                creationflags=creationflags,
            )
        except Exception:
            stdout.close()
            stderr.close()
            raise
        self.children[run_id] = child
        self.log_handles[run_id] = (stdout, stderr)
        update_run(
            run_dir,
            status="starting",
            pid=child.pid,
            launched_at=utc_now(),
        )

    def pause(self, run_id: str) -> dict[str, Any]:
        with self.lock:
            run = self._read_run(run_id)
            if str(run.get("status", "")) not in {"running", "starting"}:
                raise RuntimeError("run_is_not_running")
            atomic_write_bytes(self._run_dir(run_id) / "pause.request", b"pause\n")
            return update_run(self._run_dir(run_id), status="pausing")

    def resume(self, run_id: str) -> dict[str, Any]:
        with self.lock:
            run_dir = self._run_dir(run_id)
            run = read_json(run_dir / "run.json")
            status = str(run.get("status", ""))
            pause = run_dir / "pause.request"
            if pause.exists() and process_is_alive(int(run.get("pid", 0) or 0)):
                pause.unlink()
                return update_run(run_dir, status="running")
            if status not in {
                "recoverable",
                "failed",
                "cancelled",
                "paused",
            }:
                raise RuntimeError("run_is_not_resumable")
            active = self.active_run()
            if active is not None and str(active.get("run_id")) != run_id:
                raise RuntimeError("another_training_is_active")
            for name in ("pause.request", "cancel.request"):
                path = run_dir / name
                if path.exists():
                    path.unlink()
            self._launch_training(run_id, str(run.get("preset", "")))
            return read_json(run_dir / "run.json")

    def cancel(self, run_id: str) -> dict[str, Any]:
        with self.lock:
            run = self._read_run(run_id)
            if str(run.get("status", "")) not in ACTIVE_STATUSES:
                raise RuntimeError("run_is_not_active")
            atomic_write_bytes(
                self._run_dir(run_id) / "cancel.request", b"cancel\n"
            )
            return update_run(self._run_dir(run_id), status="cancelling")

class DashboardHandler(BaseHTTPRequestHandler):
    server_version = "PokemonTCGTrainingDashboard/3"

    @property
    def state(self) -> DashboardState:
        return self.server.dashboard_state  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write(
            "%s - %s\n" % (self.address_string(), fmt % args)
        )

    def _security_headers(self) -> None:
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; connect-src 'self'; "
            "style-src 'self'; script-src 'self'; img-src 'self' data:",
        )
        self.send_header("Cache-Control", "no-store")

    def _json(
        self,
        status: int,
        payload: Any,
    ) -> None:
        wire = json.dumps(
            payload, ensure_ascii=False, sort_keys=True
        ).encode("utf-8")
        self.send_response(status)
        self._security_headers()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(wire)))
        self.end_headers()
        self.wfile.write(wire)

    def _error(self, status: int, code: str, message: str = "") -> None:
        self._json(
            status,
            {"error": code, "message": message or code},
        )

    def _body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length <= 0 or length > MAX_BODY_BYTES:
            raise ValueError("invalid request body length")
        raw = self.rfile.read(length)
        value = json.loads(raw.decode("utf-8"))
        if not isinstance(value, dict):
            raise ValueError("request body must be an object")
        return value

    def _require_csrf(self) -> bool:
        supplied = self.headers.get("X-CSRF-Token", "")
        if not secrets.compare_digest(supplied, self.state.csrf_token):
            self._error(HTTPStatus.FORBIDDEN, "csrf_token_invalid")
            return False
        return True

    def _parts(self) -> list[str]:
        path = urllib.parse.urlsplit(self.path).path
        return [urllib.parse.unquote(item) for item in path.split("/") if item]

    def do_GET(self) -> None:  # noqa: N802
        try:
            parts = self._parts()
            if not parts or parts == ["index.html"]:
                self._static("index.html")
                return
            if len(parts) == 1 and parts[0] in {
                "app.js",
                "style.css",
            }:
                self._static(parts[0])
                return
            if parts == ["api", "v1", "session"]:
                self._json(
                    HTTPStatus.OK,
                    {
                        "csrf_token": self.state.csrf_token,
                        "api_version": 1,
                        "heartbeat_seconds": HEARTBEAT_SECONDS,
                    },
                )
                return
            if parts == ["api", "v1", "runs"]:
                self._json(HTTPStatus.OK, {"runs": self.state.list_runs()})
                return
            if len(parts) == 4 and parts[:3] == ["api", "v1", "runs"]:
                self._json(HTTPStatus.OK, self.state.get_run(parts[3]))
                return
            if (
                len(parts) == 5
                and parts[:3] == ["api", "v1", "runs"]
                and parts[4] == "events"
            ):
                self._sse(parts[3])
                return
            self._error(HTTPStatus.NOT_FOUND, "not_found")
        except (ValueError, OSError, json.JSONDecodeError) as exc:
            self._error(HTTPStatus.BAD_REQUEST, "bad_request", str(exc))

    def _static(self, name: str) -> None:
        path = resolve_within(STATIC_ROOT, name)
        if not path.is_file():
            self._error(HTTPStatus.NOT_FOUND, "not_found")
            return
        wire = path.read_bytes()
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self.send_response(HTTPStatus.OK)
        self._security_headers()
        self.send_header("Content-Type", content_type + "; charset=utf-8")
        self.send_header("Content-Length", str(len(wire)))
        self.end_headers()
        self.wfile.write(wire)

    def _sse(self, run_id: str) -> None:
        validate_run_id(run_id)
        run_dir = self.state._run_dir(run_id)
        if not (run_dir / "run.json").is_file():
            self._error(HTTPStatus.NOT_FOUND, "run_not_found")
            return
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        raw_last = self.headers.get(
            "Last-Event-ID",
            query.get("last_event_id", ["0"])[0],
        )
        try:
            last_seq = max(0, int(raw_last or 0))
        except ValueError:
            last_seq = 0
        self.send_response(HTTPStatus.OK)
        self._security_headers()
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        self.wfile.flush()
        heartbeat_at = 0.0
        try:
            while True:
                rows = read_events(
                    run_dir / "events.jsonl",
                    after_seq=last_seq,
                )
                for row in rows:
                    last_seq = int(row["seq"])
                    wire = (
                        f"id: {last_seq}\n"
                        "event: training_event_v3\n"
                        f"data: {json.dumps(row, ensure_ascii=False, sort_keys=True)}\n\n"
                    ).encode("utf-8")
                    self.wfile.write(wire)
                now = time.monotonic()
                if now >= heartbeat_at:
                    heartbeat = {
                        "type": "heartbeat",
                        "run_id": run_id,
                        "time": utc_now(),
                        "last_seq": last_seq,
                        "run": self.state.get_run(run_id),
                    }
                    self.wfile.write(
                        (
                            "event: heartbeat\n"
                            f"data: {json.dumps(heartbeat, ensure_ascii=False, sort_keys=True)}\n\n"
                        ).encode("utf-8")
                    )
                    heartbeat_at = now + HEARTBEAT_SECONDS
                self.wfile.flush()
                time.sleep(0.25)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def do_POST(self) -> None:  # noqa: N802
        if not self._require_csrf():
            return
        try:
            parts = self._parts()
            payload = self._body()
            if parts == ["api", "v1", "runs"]:
                self._json(
                    HTTPStatus.CREATED,
                    self.state.create_run(payload),
                )
                return
            if (
                len(parts) == 5
                and parts[:3] == ["api", "v1", "runs"]
            ):
                run_id, action = parts[3], parts[4]
                if action == "pause":
                    result = self.state.pause(run_id)
                elif action == "resume":
                    result = self.state.resume(run_id)
                elif action == "cancel":
                    result = self.state.cancel(run_id)
                else:
                    self._error(HTTPStatus.NOT_FOUND, "not_found")
                    return
                self._json(HTTPStatus.OK, result)
                return
            self._error(HTTPStatus.NOT_FOUND, "not_found")
        except ValueError as exc:
            self._error(HTTPStatus.BAD_REQUEST, "bad_request", str(exc))
        except RuntimeError as exc:
            self._error(HTTPStatus.CONFLICT, str(exc))
        except (OSError, json.JSONDecodeError) as exc:
            self._error(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                "server_error",
                str(exc),
            )


class DashboardServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        address: tuple[str, int],
        state: DashboardState,
    ):
        self.dashboard_state = state
        super().__init__(address, DashboardHandler)

    def handle_error(self, request: Any, client_address: Any) -> None:
        error = sys.exc_info()[1]
        if isinstance(
            error,
            (BrokenPipeError, ConnectionAbortedError, ConnectionResetError),
        ):
            return
        super().handle_error(request, client_address)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Start the loopback Deep AI training dashboard."
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8767)
    parser.add_argument(
        "--runs-root",
        default=str(REPO_ROOT / "build" / "ai_training" / "runs"),
    )
    parser.add_argument("--open-browser", action="store_true")
    args = parser.parse_args()
    if args.host not in {"127.0.0.1", "::1", "localhost"}:
        parser.error("The training dashboard may only bind to loopback")
    state = DashboardState(REPO_ROOT, Path(args.runs_root))
    server = DashboardServer((args.host, args.port), state)
    url = f"http://{args.host}:{args.port}/"
    print(f"Deep AI training dashboard: {url}")
    print(f"CSRF token: {state.csrf_token}")
    if args.open_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
