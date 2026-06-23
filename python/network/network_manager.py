"""Thread-safe bridge between WebSocket and pygame main loop.

Host mode:  start_server(port) -> accept one client -> exchange messages
Client mode: connect(host, port) -> connect to host -> exchange messages

Main thread calls poll() each frame and send() to queue outgoing messages.
The network thread handles all blocking WebSocket I/O.
"""
import json
import queue
import threading
import time
import websockets.sync.server
import websockets.sync.client
from network.message_protocol import (
    COALESCABLE_MESSAGES,
    LEGACY_MESSAGE_TYPES,
    MSG_CONNECTION_FAILED,
    MSG_ERROR,
    MSG_OPPONENT_DISCONNECTED,
    MSG_PING,
    MSG_PONG,
    envelope_message,
    is_newer_sequence,
    is_protocol_compatible,
    is_protocol_message,
    next_seq,
)
from utils.logger import get_logger

logger = get_logger(__name__)


class NetworkManager:
    """Thread-safe bridge between a WebSocket connection and pygame main loop."""

    def __init__(self):
        self._incoming = queue.Queue()
        self._outgoing = queue.Queue()
        self._thread: threading.Thread | None = None
        self._running = False
        self._websocket = None
        self._connected = threading.Event()
        self._is_host = False
        self._last_error: str | None = None
        self._server = None  # Keep reference for shutdown
        self._last_message_time: float = time.time()
        self._last_recv_time: float = time.time()
        self._last_send_time: float = time.time()
        self._heartbeat_interval: float = 15.0  # send ping if idle this long
        self._recv_timeout: float = 0.05
        self._send_seq: int = 0
        self._last_recv_seq: int = 0
        self._is_relay = False
        self._relay_room_code: str | None = None

    # ── Public API (called from main thread) ──────────────────────

    def start_host(self, port: int = 8765):
        """Start WebSocket server and wait for one client connection."""
        self._is_host = True
        self._running = True
        self._last_error = None
        self._last_recv_time = time.time()
        self._last_send_time = self._last_recv_time
        self._send_seq = 0
        self._last_recv_seq = 0
        self._thread = threading.Thread(
            target=self._run_host, args=(port,),
            daemon=True, name="net-host"
        )
        self._thread.start()

    def connect_to_host(self, host: str, port: int = 8765):
        """Connect to a remote host as client."""
        self._is_host = False
        self._running = True
        self._last_error = None
        self._last_recv_time = time.time()
        self._last_send_time = self._last_recv_time
        self._send_seq = 0
        self._last_recv_seq = 0
        self._thread = threading.Thread(
            target=self._run_client, args=(host, port),
            daemon=True, name="net-client"
        )
        self._thread.start()

    def connect_to_relay(self, server_host: str, server_port: int,
                         is_host: bool, room_code: str | None = None):
        """Connect to relay server and create or join a room.

        is_host=True:  create a new room (relay host / 房主)
        is_host=False: join existing room with room_code (relay client / 挑战者)
        """
        self._is_host = is_host
        self._is_relay = True
        self._running = True
        self._last_error = None
        self._last_recv_time = time.time()
        self._last_send_time = self._last_recv_time
        self._send_seq = 0
        self._last_recv_seq = 0
        self._relay_room_code = room_code
        self._thread = threading.Thread(
            target=self._run_relay,
            args=(server_host, server_port, is_host, room_code),
            daemon=True, name="net-relay"
        )
        self._thread.start()

    @property
    def is_connected(self) -> bool:
        return self._connected.is_set()

    @property
    def is_busy(self) -> bool:
        """True if thread is running but not yet connected."""
        return self._running and not self._connected.is_set()

    @property
    def last_error(self) -> str | None:
        err = self._last_error
        self._last_error = None
        return err

    @property
    def is_host(self) -> bool:
        return self._is_host

    @property
    def is_relay(self) -> bool:
        return self._is_relay

    @property
    def relay_room_code(self) -> str | None:
        return self._relay_room_code

    @property
    def is_stale(self) -> bool:
        """True if no message received for NETWORK_TIMEOUT seconds."""
        if not self._connected.is_set():
            return False
        from config import NETWORK_TIMEOUT
        return time.time() - self._last_recv_time > NETWORK_TIMEOUT

    def poll(self, max_messages: int | None = None) -> list[dict]:
        """Called each frame from main thread. Returns all pending messages."""
        messages = []
        while max_messages is None or len(messages) < max_messages:
            try:
                messages.append(self._incoming.get_nowait())
            except queue.Empty:
                break
        return messages

    def send(self, message: dict):
        """Queue a message for the network thread to send."""
        if self._running:
            self._put_outgoing(message)

    def _next_envelope(self, message: dict) -> dict:
        self._send_seq = next_seq(self._send_seq)
        return envelope_message(message, self._send_seq)

    def _put_coalesced(self, q: queue.Queue, message: dict):
        """Put a message, replacing older queued state updates when safe."""
        msg_type = message.get("type")
        if msg_type not in COALESCABLE_MESSAGES:
            q.put(message)
            return

        retained = []
        while True:
            try:
                queued = q.get_nowait()
            except queue.Empty:
                break
            if queued is None or queued.get("type") != msg_type:
                retained.append(queued)
        for queued in retained:
            q.put(queued)
        q.put(message)

    def _put_outgoing(self, message: dict):
        self._put_coalesced(self._outgoing, message)

    def _put_incoming(self, message: dict):
        self._put_coalesced(self._incoming, message)

    def _connection_failed(self, error: str):
        self._last_error = error
        self._running = False
        self._put_incoming({
            "type": MSG_CONNECTION_FAILED,
            "error": error,
        })

    def _opponent_disconnected(self):
        self._put_incoming({"type": MSG_OPPONENT_DISCONNECTED})

    def stop(self):
        """Shutdown the network connection and thread.

        Thread-safe: called from main thread while network thread
        blocks on serve_forever() or _message_loop().
        """
        self._running = False

        # Close server socket to unblock serve_forever()
        server = self._server
        if server is not None:
            try:
                server.close()
            except Exception:
                pass

        # Close websocket to unblock recv() in _message_loop
        ws = self._websocket
        if ws is not None:
            try:
                ws.close()
            except Exception:
                pass

        # Push sentinel to unblock outgoing queue drain
        try:
            self._outgoing.put_nowait(None)
        except queue.Full:
            pass

        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2.0)

        self._connected.clear()
        self._websocket = None
        self._server = None
        self._is_relay = False
        self._relay_room_code = None

    # ── Network thread (host) ────────────────────────────────────

    def _run_host(self, port: int):
        def handler(websocket):
            self._websocket = websocket
            self._connected.set()
            logger.info("Client connected to host on port %d", port)
            try:
                self._message_loop(websocket)
            except Exception as e:
                logger.error("Host connection error: %s", e)
                self._last_error = str(e)
                self._opponent_disconnected()
            finally:
                self._connected.clear()
                self._websocket = None

        try:
            with websockets.sync.server.serve(handler, "0.0.0.0", port) as server:
                self._server = server
                server.serve_forever()
        except OSError as e:
            self._last_error = str(e)
            logger.error("Server failed to start: %s", e)
        finally:
            self._running = False
            self._server = None

    # ── Network thread (client) ──────────────────────────────────

    def _run_client(self, host: str, port: int):
        try:
            with websockets.sync.client.connect(
                f"ws://{host}:{port}",
                open_timeout=10,
                close_timeout=5,
            ) as websocket:
                self._websocket = websocket
                self._connected.set()
                logger.info("Connected to host at %s:%d", host, port)
                self._message_loop(websocket)
        except OSError as e:
            logger.error("Client connection failed: %s", e)
            self._connection_failed(str(e))
        except Exception as e:
            logger.error("Client error: %s", e)
            self._connection_failed(str(e))

    # ── Network thread (relay) ───────────────────────────────────

    def _run_relay(self, server_host: str, server_port: int,
                   is_host: bool, room_code: str | None):
        """Connect to relay server, perform room handshake, then message loop."""
        try:
            with websockets.sync.client.connect(
                f"ws://{server_host}:{server_port}",
                open_timeout=10,
                close_timeout=5,
            ) as websocket:
                self._websocket = websocket

                # ── Control handshake ──
                if is_host:
                    websocket.send(json.dumps({
                        "type": "create_room",
                    }, ensure_ascii=False))
                    response = json.loads(websocket.recv(timeout=10))
                    if response.get("type") == "room_created":
                        self._relay_room_code = response["room_id"]
                        self._put_incoming({
                            "type": "room_created",
                            "room_id": self._relay_room_code,
                        })
                        logger.info("Relay room created: %s", self._relay_room_code)
                    elif response.get("type") == "error":
                        self._put_incoming({
                            "type": MSG_CONNECTION_FAILED,
                            "error": response.get("message", "创建房间失败"),
                        })
                        return
                    else:
                        self._put_incoming({
                            "type": MSG_CONNECTION_FAILED,
                            "error": f"非预期的响应: {response.get('type')}",
                        })
                        return
                else:
                    websocket.send(json.dumps({
                        "type": "join_room", "room_id": room_code,
                    }, ensure_ascii=False))
                    response = json.loads(websocket.recv(timeout=10))
                    if response.get("type") == "room_joined":
                        logger.info("Joined relay room: %s", room_code)
                    elif response.get("type") == "error":
                        self._put_incoming({
                            "type": MSG_CONNECTION_FAILED,
                            "error": response.get("message", "加入房间失败"),
                        })
                        return
                    else:
                        self._put_incoming({
                            "type": MSG_CONNECTION_FAILED,
                            "error": f"非预期的响应: {response.get('type')}",
                        })
                        return

                # ── Wait for opponent ──
                response = json.loads(websocket.recv(timeout=120))
                if response.get("type") == "opponent_joined":
                    self._connected.set()
                    self._last_recv_time = time.time()
                    self._last_message_time = time.time()
                    self._put_incoming({"type": "opponent_joined"})
                    logger.info("Opponent joined relay room")
                elif response.get("type") == "error":
                    self._put_incoming({
                        "type": MSG_CONNECTION_FAILED,
                        "error": response.get("message", "等待对手失败"),
                    })
                    return
                else:
                    self._put_incoming({
                        "type": MSG_CONNECTION_FAILED,
                        "error": f"非预期的响应: {response.get('type')}",
                    })
                    return

                # ── Enter message relay loop ──
                self._message_loop(websocket)

        except OSError as e:
            logger.error("Relay connection failed: %s", e)
            self._connection_failed(str(e))
        except Exception as e:
            logger.error("Relay error: %s", e)
            self._connection_failed(str(e))

    # ── Shared message loop ──────────────────────────────────────

    def _message_loop(self, websocket):
        """Bidirectional message relay between queues and the socket."""
        while self._running:
            # Send queued outgoing messages (non-blocking)
            try:
                while True:
                    msg = self._outgoing.get_nowait()
                    if msg is None:  # Sentinel to stop
                        return
                    try:
                        wire_msg = self._next_envelope(msg)
                        websocket.send(json.dumps(wire_msg, ensure_ascii=False))
                        self._last_send_time = time.time()
                    except Exception:
                        self._opponent_disconnected()
                        return
            except queue.Empty:
                pass

            # Heartbeat: send ping if idle to keep connection alive
            now = time.time()
            if now - self._last_send_time > self._heartbeat_interval:
                try:
                    websocket.send(json.dumps(
                        self._next_envelope({"type": MSG_PING}),
                        ensure_ascii=False,
                    ))
                    self._last_send_time = now
                except Exception:
                    self._opponent_disconnected()
                    return

            # Receive one incoming message. A short timeout keeps outgoing
            # latency low without burning a CPU core in an empty tight loop.
            try:
                data = websocket.recv(timeout=self._recv_timeout)
                msg = json.loads(data)
                msg_type = msg.get("type", "")

                if is_protocol_message(msg):
                    if not is_protocol_compatible(msg):
                        self._put_incoming({
                            "type": MSG_ERROR,
                            "message": "协议版本不兼容，请双方更新到同一版本。",
                            "expected_version": 2,
                            "actual_version": msg.get("version"),
                        })
                        continue
                    if not is_newer_sequence(msg, self._last_recv_seq):
                        continue
                    self._last_recv_seq = msg.get("seq", self._last_recv_seq)
                    if msg_type in LEGACY_MESSAGE_TYPES:
                        self._put_incoming({
                            "type": MSG_ERROR,
                            "message": "Received a deprecated multiplayer v1 message type; update both clients to v2.",
                        })
                        continue

                # Handle heartbeat
                if msg_type == MSG_PING:
                    # Reply with pong immediately
                    websocket.send(json.dumps(
                        self._next_envelope({"type": MSG_PONG}),
                        ensure_ascii=False,
                    ))
                    self._last_send_time = time.time()
                    self._last_recv_time = time.time()
                    self._last_message_time = self._last_recv_time
                elif msg_type == MSG_PONG:
                    # Pong received: update liveness but don't queue to game.
                    self._last_recv_time = time.time()
                    self._last_message_time = self._last_recv_time
                elif not is_protocol_message(msg):
                    if msg_type in {MSG_OPPONENT_DISCONNECTED, MSG_CONNECTION_FAILED, MSG_ERROR}:
                        self._last_recv_time = time.time()
                        self._last_message_time = self._last_recv_time
                        self._put_incoming(msg)
                    else:
                        self._put_incoming({
                            "type": MSG_ERROR,
                            "message": "收到旧版联机消息，请双方更新到联机协议 v2。",
                        })
                else:
                    # Regular game message
                    self._last_recv_time = time.time()
                    self._last_message_time = time.time()
                    self._put_incoming(msg)
            except TimeoutError:
                pass
            except websockets.exceptions.ConnectionClosed:
                self._opponent_disconnected()
                break
            except Exception as e:
                logger.error("Receive error: %s", e)
                self._opponent_disconnected()
                break
