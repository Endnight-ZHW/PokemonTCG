"""Multi-instance launcher for testing local multiplayer.

Usage:
    python scripts/launch_multiplayer.py [--host-port PORT] [--client-port PORT]
"""
import subprocess
import sys
import time
import os

HOST_PORT = 8765
CLIENT_PORT = 8765


def main():
    # Allow overriding ports
    host_port = HOST_PORT
    client_port = CLIENT_PORT
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--host-port" and i + 1 < len(args):
            host_port = int(args[i + 1]); i += 2
        elif args[i] == "--client-port" and i + 1 < len(args):
            client_port = int(args[i + 1]); i += 2
        else:
            i += 1

    python = sys.executable
    main_py = os.path.join(os.path.dirname(__file__), "..", "main.py")

    print("=" * 60)
    print("  宝可梦卡牌对战 — 双实例联机启动器")
    print("=" * 60)
    print(f"  房主端口: {host_port}")
    print(f"  客户端端口: {client_port}")
    print()
    print("  启动房主窗口...")
    print("  启动客户端窗口...")
    print()
    print("  提示: 房主窗口先等待，客户端连接成功后自动进入卡组选择。")
    print("=" * 60)

    # Launch host (separate window)
    host_cmd = [python, main_py, "--host", str(host_port)]
    if sys.platform == "win32":
        host_proc = subprocess.Popen(
            host_cmd,
            creationflags=subprocess.CREATE_NEW_CONSOLE,
        )
    else:
        host_proc = subprocess.Popen(
            host_cmd,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    # Brief pause to let host start listening
    time.sleep(1.5)

    # Launch client (separate window)
    client_cmd = [python, main_py, "--client", "localhost", str(client_port)]
    if sys.platform == "win32":
        client_proc = subprocess.Popen(
            client_cmd,
            creationflags=subprocess.CREATE_NEW_CONSOLE,
        )
    else:
        client_proc = subprocess.Popen(
            client_cmd,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    print("  两个窗口已启动！")
    print("  等待双方连接后，各自选择卡组即可开始对战。")
    print()
    input("  按 Enter 关闭两个窗口...")

    host_proc.terminate()
    client_proc.terminate()
    print("  已关闭。")


if __name__ == "__main__":
    main()
