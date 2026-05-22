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
        self._last_send_time: float = time.time()
        self._heartbeat_interval: float = 15.0  # send ping if idle this long
        self._is_relay = False
        self._relay_room_code: str | None = None

    # ── Public API (called from main thread) ──────────────────────

    def start_host(self, port: int = 8765):
        """Start WebSocket server and wait for one client connection."""
        self._is_host = True
        self._running = True
        self._last_error = None
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
        return time.time() - self._last_message_time > NETWORK_TIMEOUT

    def poll(self) -> list[dict]:
        """Called each frame from main thread. Returns all pending messages."""
        messages = []
        while True:
            try:
                messages.append(self._incoming.get_nowait())
            except queue.Empty:
                break
        return messages

    def send(self, message: dict):
        """Queue a message for the network thread to send."""
        if self._running:
            self._outgoing.put(message)

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
                self._incoming.put({"type": "opponent_disconnected"})
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
            self._last_error = str(e)
            self._running = False
            self._incoming.put({
                "type": "connection_failed",
                "error": str(e),
            })
        except Exception as e:
            logger.error("Client error: %s", e)
            self._last_error = str(e)
            self._running = False
            self._incoming.put({
                "type": "connection_failed",
                "error": str(e),
            })

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
                        self._incoming.put({
                            "type": "room_created",
                            "room_id": self._relay_room_code,
                        })
                        logger.info("Relay room created: %s", self._relay_room_code)
                    elif response.get("type") == "error":
                        self._incoming.put({
                            "type": "connection_failed",
                            "error": response.get("message", "创建房间失败"),
                        })
                        return
                    else:
                        self._incoming.put({
                            "type": "connection_failed",
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
                        self._incoming.put({
                            "type": "connection_failed",
                            "error": response.get("message", "加入房间失败"),
                        })
                        return
                    else:
                        self._incoming.put({
                            "type": "connection_failed",
                            "error": f"非预期的响应: {response.get('type')}",
                        })
                        return

                # ── Wait for opponent ──
                response = json.loads(websocket.recv(timeout=120))
                if response.get("type") == "opponent_joined":
                    self._connected.set()
                    self._last_message_time = time.time()
                    self._incoming.put({"type": "opponent_joined"})
                    logger.info("Opponent joined relay room")
                elif response.get("type") == "error":
                    self._incoming.put({
                        "type": "connection_failed",
                        "error": response.get("message", "等待对手失败"),
                    })
                    return
                else:
                    self._incoming.put({
                        "type": "connection_failed",
                        "error": f"非预期的响应: {response.get('type')}",
                    })
                    return

                # ── Enter message relay loop ──
                self._message_loop(websocket)

        except OSError as e:
            logger.error("Relay connection failed: %s", e)
            self._last_error = str(e)
            self._running = False
            self._incoming.put({
                "type": "connection_failed",
                "error": str(e),
            })
        except Exception as e:
            logger.error("Relay error: %s", e)
            self._last_error = str(e)
            self._running = False
            self._incoming.put({
                "type": "connection_failed",
                "error": str(e),
            })

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
                        websocket.send(json.dumps(msg, ensure_ascii=False))
                        self._last_message_time = time.time()
                        self._last_send_time = time.time()
                    except Exception:
                        self._incoming.put({"type": "opponent_disconnected"})
                        return
            except queue.Empty:
                pass

            # Heartbeat: send ping if idle to keep connection alive
            now = time.time()
            if now - self._last_send_time > self._heartbeat_interval:
                try:
                    websocket.send(json.dumps({"type": "ping"}))
                    self._last_send_time = now
                except Exception:
                    self._incoming.put({"type": "opponent_disconnected"})
                    return

            # Receive one incoming message (10ms timeout to stay responsive)
            try:
                data = websocket.recv(timeout=0.01)
                msg = json.loads(data)
                msg_type = msg.get("type", "")
                # Handle heartbeat
                if msg_type == "ping":
                    # Reply with pong immediately
                    websocket.send(json.dumps({"type": "pong"}))
                    self._last_send_time = time.time()
                elif msg_type == "pong":
                    # Pong received — update liveness but don't queue to game
                    self._last_message_time = time.time()
                else:
                    # Regular game message
                    self._last_message_time = time.time()
                    self._incoming.put(msg)
            except TimeoutError:
                pass
            except websockets.exceptions.ConnectionClosed:
                self._incoming.put({"type": "opponent_disconnected"})
                break
            except Exception as e:
                logger.error("Receive error: %s", e)
                self._incoming.put({"type": "opponent_disconnected"})
                break
