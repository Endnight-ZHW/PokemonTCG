#!/usr/bin/env bash
set -euo pipefail

exec > >(tee -a mslx-start.log) 2>&1
printf '\n[%s] Starting PokemonTCG Relay bootstrap\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

relay_binary="./ptcg_relay_server"

if [[ ! -x "$relay_binary" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends g++ libboost-dev nlohmann-json3-dev

  g++ \
    -std=c++17 \
    -O2 \
    -DNDEBUG \
    -pthread \
    -DBOOST_ERROR_CODE_HEADER_ONLY \
    -DBOOST_SYSTEM_NO_DEPRECATED \
    -DBOOST_SYSTEM_NO_LIB \
    -DPTCG_RELAY_VERSION_MAJOR=0 \
    -DPTCG_RELAY_VERSION_MINOR=8 \
    -DPTCG_RELAY_VERSION_PATCH=0 \
    -static-libstdc++ \
    -static-libgcc \
    relay_server.cpp \
    relay_protocol.cpp \
    -o "$relay_binary"
fi

exec "$relay_binary" \
  --host "${PTCG_RELAY_HOST:-0.0.0.0}" \
  --port "${PTCG_RELAY_PORT:-8766}" \
  --threads "${PTCG_RELAY_THREADS:-2}" \
  --max-rooms "${PTCG_RELAY_MAX_ROOMS:-100}"
