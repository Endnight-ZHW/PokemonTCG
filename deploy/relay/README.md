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

## Stable SRV address for STUN deployments

Updated Windows/Android clients accept `ws+srv://relay.114600.xyz`. This is an
application-specific discovery URL: the client queries
`_ptcg._tcp.relay.114600.xyz` and opens a plain WebSocket to the SRV target and
port. Existing `ws://` and `wss://` URLs still connect directly. SRV does not
provide TLS; `ws+srv://` does not imply `wss://` encryption.

The Lucky DDNS task `PokemonTCG Relay SRV` maintains these DNS-only records with
a 60-second TTL, using the STUN rule named `PTCGRelay`:

| Record | Name | Content |
| --- | --- | --- |
| A | `relay-host.114600.xyz` | `{STUN_PTCGRelay_IP}` |
| SRV | `_ptcg._tcp.relay.114600.xyz` | `0 0 {STUN_PTCGRelay_PORT} relay-host.114600.xyz` |

The task checks every 36 seconds. IP/port changes therefore still have a DNS
propagation window and can interrupt an active match. Both the STUN rule and
DDNS task must remain enabled; keep the STUN rule name unchanged because the
variables reference it. Do not enable Cloudflare's HTTP proxy on the A record.

`RelaySrvResolver` polls UDP DNS without blocking gameplay and queries again
on each connection or resume. It tries AliDNS, DNSPod, then Cloudflare DNS, with
a two-second timeout per resolver. It validates packet bounds, compression
pointers, transaction IDs, question names and SRV targets before connecting.
Networks blocking all three DNS servers can still use an explicit `ws://` URL.

Older installed clients do not understand `ws+srv://`; rebuild/update the
client before using the stable address. Saved addresses matching this
deployment's old IP endpoints migrate to the SRV default, while custom
server addresses are preserved.
