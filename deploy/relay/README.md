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

## MSLX Docker custom instance

`mslx-start.sh` supports an MSLX `docker-custom` instance on Linux x86_64. Use
an Ubuntu-based image, set the custom command to `/bin/bash mslx-start.sh`, and
map `8766:8766/tcp`. The first start installs the compiler and header-only
dependencies, builds the relay into the persistent instance directory, and
then starts it. Later starts reuse that binary. Bootstrap and relay output is
also appended to `mslx-start.log` in the instance directory.

For the MSLX runtime image, the relevant instance settings are:

```text
Java mode: docker-custom
Image: MSLX://DockerImage/Java/21
Command: /bin/bash mslx-start.sh
Port mapping: 8766:8766/tcp
Stop command: ^c
```
