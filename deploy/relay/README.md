# PTCG Relay deployment

`ptcg_relay_server` serves plain WebSocket traffic and `GET /healthz`. Run TLS at
the reverse proxy; do not expose the relay binary as a TLS endpoint.

```text
ptcg_relay_server --host 127.0.0.1 --port 8766 --threads 2 --max-rooms 100
```

When a reverse proxy is on the same host, add `--trusted-proxy 127.0.0.1` so
per-source handshake limiting can use its validated `X-Forwarded-For` address.
Never trust that header from arbitrary peers.

The server emits one JSON object per log line. A healthy response contains
`status`, `connections`, and `rooms`. Room state is intentionally in-memory;
restart coordination should drain existing matches first.
