"""Pokemon TCG Battle - Two Player Hot-Seat Game.

CLI arguments for quick multiplayer testing:
    python main.py --host [port]       Auto-create room (default port 8765)
    python main.py --client <ip> [port]  Auto-join room (default port 8765)
    python main.py                      Normal start (title screen)
"""
import sys
import argparse

# Force UTF-8 encoding for Windows console (safe method)
if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except Exception:
        pass

sys.path.insert(0, '.')

from utils.logger import setup_logging
setup_logging()

from ui.game_app import GameApp
from config import NETWORK_PORT


def main():
    parser = argparse.ArgumentParser(description="宝可梦卡牌对战")
    parser.add_argument("--host", nargs="?", const=NETWORK_PORT, type=int,
                        help="创建房间（房主模式），可选指定端口")
    parser.add_argument("--client", nargs=2, metavar=("IP", "PORT"),
                        help="加入房间（客户端模式），需要指定IP和端口")
    parser.add_argument("--relay", nargs=2, metavar=("HOST", "PORT"),
                        help="通过中继服务器联机，指定服务器地址和端口")
    parser.add_argument("--room", type=str, default=None,
                        help="要加入的房间号（仅与 --relay 配合使用，不指定则创建房间）")
    args = parser.parse_args()

    app = GameApp()

    if args.relay is not None:
        app.auto_relay_host = args.relay[0]
        app.auto_relay_port = int(args.relay[1])
        app.auto_relay_room = args.room
        app.auto_connect = "relay"
    elif args.host is not None:
        app.auto_host_port = args.host
        app.auto_connect = "host"
    elif args.client is not None:
        app.auto_client_ip = args.client[0]
        app.auto_client_port = int(args.client[1])
        app.auto_connect = "client"

    app.run()


if __name__ == '__main__':
    main()
