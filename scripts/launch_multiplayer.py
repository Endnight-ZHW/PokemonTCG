"""Multi-instance launcher for testing local multiplayer.

Usage:
    python scripts/launch_multiplayer.py [--host-port PORT] [--client-port PORT]
"""
import subprocess
import sys
import time
import os
import argparse

HOST_PORT = 8765


def _valid_port(value: str) -> int:
    try:
        port = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("端口必须是数字") from exc
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("端口范围必须是 1-65535")
    return port


def parse_args(argv: list[str] | None = None):
    parser = argparse.ArgumentParser(description="启动两个本地联机测试窗口")
    parser.add_argument("--host-port", type=_valid_port, default=HOST_PORT,
                        help=f"房主监听端口，默认 {HOST_PORT}")
    parser.add_argument("--client-port", type=_valid_port, default=None,
                        help="客户端连接端口，默认跟随 --host-port")
    parser.add_argument("--host", default="localhost",
                        help="客户端连接地址，默认 localhost")
    parser.add_argument("--startup-delay", type=float, default=1.5,
                        help="启动客户端前等待秒数，默认 1.5")
    return parser.parse_args(argv)


def build_commands(python: str, main_py: str, host_port: int,
                   client_host: str, client_port: int) -> tuple[list[str], list[str]]:
    return (
        [python, main_py, "--host", str(host_port)],
        [python, main_py, "--client", client_host, str(client_port)],
    )


def _launch(cmd: list[str]):
    if sys.platform == "win32":
        return subprocess.Popen(cmd, creationflags=subprocess.CREATE_NEW_CONSOLE)
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    args = parse_args()
    host_port = args.host_port
    client_port = args.client_port or host_port

    python = sys.executable
    main_py = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "main.py"))
    host_cmd, client_cmd = build_commands(
        python, main_py, host_port, args.host, client_port
    )

    print("=" * 60)
    print("  宝可梦卡牌对战 — 双实例联机启动器")
    print("=" * 60)
    print(f"  房主端口: {host_port}")
    print(f"  客户端连接: {args.host}:{client_port}")
    print()
    print("  启动房主窗口...")
    print("  启动客户端窗口...")
    print()
    print("  提示: 房主窗口先等待，客户端连接成功后自动进入卡组选择。")
    print("=" * 60)

    host_proc = _launch(host_cmd)

    # Brief pause to let host start listening
    time.sleep(max(0.0, args.startup_delay))

    client_proc = _launch(client_cmd)

    print("  两个窗口已启动！")
    print("  等待双方连接后，各自选择卡组即可开始对战。")
    print()
    input("  按 Enter 关闭两个窗口...")

    for proc in (client_proc, host_proc):
        if proc.poll() is None:
            proc.terminate()
    print("  已关闭。")


if __name__ == "__main__":
    main()
