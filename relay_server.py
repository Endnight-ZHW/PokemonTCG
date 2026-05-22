"""轻量级 WebSocket 中继服务器 — 宝可梦卡牌对战的云端房间中转.

玩家双方都作为 WebSocket 客户端连接到此服务器。
服务器将同一房间的两人配对后，透明转发所有游戏消息。

使用与游戏相同的 websockets.sync API，确保版本兼容。

用法:  python relay_server.py [--host 0.0.0.0] [--port 8766]
"""
import json
import logging
import random
import threading
import time

import websockets.sync.server

logger = logging.getLogger("relay")

# 房间表: room_id -> {"p1": ws | None, "p2": ws | None, "created_at": float, "p2_joined": threading.Event}
rooms: dict[str, dict] = {}
rooms_lock = threading.Lock()


def generate_room_code() -> str:
    """生成未使用的4位数字房间号."""
    with rooms_lock:
        existing = set(rooms.keys())
    for _ in range(100):
        code = str(random.randint(1000, 9999))
        if code not in existing:
            return code
    for code in [str(i).zfill(4) for i in range(1000, 10000)]:
        if code not in existing:
            return code
    raise RuntimeError("No available room codes")


def handle_client(websocket):
    """处理单个 WebSocket 连接（在独立线程中运行）."""
    remote = websocket.remote_address
    logger.info("新连接: %s:%s", *remote)

    my_room: str | None = None
    my_role: str | None = None
    paired: bool = False

    try:
        # 阶段1: 等待控制命令
        raw = websocket.recv(timeout=30)
        msg = json.loads(raw)
        msg_type = msg.get("type", "")

        if msg_type == "create_room":
            code = generate_room_code()
            with rooms_lock:
                rooms[code] = {
                    "p1": websocket, "p2": None,
                    "created_at": time.time(),
                    "p2_joined": threading.Event(),
                }
            my_room = code
            my_role = "p1"
            websocket.send(json.dumps({
                "type": "room_created", "room_id": code,
            }, ensure_ascii=False))
            logger.info("房间 %s 已创建 (房主: %s:%s)", code, *remote)

        elif msg_type == "join_room":
            code = str(msg.get("room_id", ""))
            with rooms_lock:
                room = rooms.get(code)
            if room is None:
                websocket.send(json.dumps({
                    "type": "error", "message": "房间不存在",
                }, ensure_ascii=False))
                logger.warning("%s:%s 尝试加入不存在的房间 %s", *remote, code)
                return
            if room["p2"] is not None:
                websocket.send(json.dumps({
                    "type": "error", "message": "房间已满",
                }, ensure_ascii=False))
                logger.warning("%s:%s 尝试加入已满的房间 %s", *remote, code)
                return
            with rooms_lock:
                room["p2"] = websocket
            my_room = code
            my_role = "p2"
            websocket.send(json.dumps({
                "type": "room_joined", "room_id": code,
            }, ensure_ascii=False))
            logger.info("%s:%s 加入了房间 %s", *remote, code)

            # 通知双方对手已加入
            p1 = room["p1"]
            if p1:
                p1.send(json.dumps({"type": "opponent_joined"}, ensure_ascii=False))
            websocket.send(json.dumps({"type": "opponent_joined"}, ensure_ascii=False))
            room["p2_joined"].set()
            paired = True

        else:
            websocket.send(json.dumps({
                "type": "error", "message": f"未知命令: {msg_type}",
            }, ensure_ascii=False))
            return

        # 阶段2: 等待对手（仅房主需要）
        if my_role == "p1" and not paired:
            with rooms_lock:
                room = rooms.get(my_room)
            if room:
                if not room["p2_joined"].wait(timeout=120):
                    websocket.send(json.dumps({
                        "type": "error", "message": "等待对手超时",
                    }, ensure_ascii=False))
                    logger.info("房间 %s 等待超时，清理", my_room)
                    return
                paired = True

        # 阶段3: 转发 — 双向透明转发游戏消息
        opponent_role = "p2" if my_role == "p1" else "p1"
        while True:
            try:
                raw = websocket.recv(timeout=30)
            except TimeoutError:
                continue

            with rooms_lock:
                room = rooms.get(my_room)

            if not room:
                break

            opponent = room.get(opponent_role)
            if opponent:
                try:
                    opponent.send(raw)
                except Exception:
                    break
            else:
                break

    except websockets.exceptions.ConnectionClosed:
        pass
    except json.JSONDecodeError:
        logger.warning("%s:%s 收到无效JSON", *remote)
    except Exception:
        logger.exception("%s:%s 未预期的错误", *remote)
    finally:
        logger.info("断开连接: %s:%s (房间: %s)", *remote, my_room or "N/A")
        with rooms_lock:
            if my_room and my_room in rooms:
                room = rooms[my_room]
                room["p2_joined"].set()
                opponent = room.get("p2" if my_role == "p1" else "p1")
                if opponent:
                    try:
                        opponent.send(json.dumps({
                            "type": "opponent_disconnected",
                        }, ensure_ascii=False))
                    except Exception:
                        pass
                del rooms[my_room]
                logger.info("房间 %s 已移除", my_room)


def main(host: str, port: int):
    """启动中继服务器."""
    logger.info("中继服务器启动中: %s:%s", host, port)
    with websockets.sync.server.serve(
        handle_client, host, port,
    ) as server:
        logger.info("中继服务器已启动: %s:%s (等待客户端连接...)", host, port)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            logger.info("收到中断信号，正在关闭...")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="宝可梦卡牌中继服务器")
    parser.add_argument("--host", default="0.0.0.0", help="监听地址 (默认 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8766, help="监听端口 (默认 8766)")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    main(args.host, args.port)
