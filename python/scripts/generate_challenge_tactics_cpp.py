"""Encode the Challenge JSON fixtures for a dependency-free C++ test."""
from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path
from typing import Any, BinaryIO


REPO_ROOT = Path(__file__).resolve().parents[2]


def _slot_for_card(state: dict[str, Any], card_id: str) -> str:
    own = state["players"][0]
    if own.get("active", {}).get("card_id") == card_id:
        return "active"
    for index, pokemon in enumerate(own.get("bench", [])):
        if pokemon.get("card_id") == card_id:
            return f"bench_{index}"
    return ""


def _state(context: dict[str, Any], deck_key: str) -> dict[str, Any]:
    state = json.loads(json.dumps(context))
    players = [state.get("own", {}), state.get("opponent", {})]
    for player in players:
        player.setdefault("active", {})
        for key in ("bench", "discard", "hand"):
            player.setdefault(key, [])
        count = int(player.get("prizes_remaining", 6))
        player["prizes"] = [f"__hidden_prize_{index}" for index in range(count)]
    state.update(
        players=players,
        public_deck_keys=[deck_key, ""],
        active_player_idx=0,
        first_player_idx=1,
        phase="MAIN",
        revision=0,
    )
    return state


def _action(compact: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    action = json.loads(json.dumps(compact))
    payload = dict(action.get("payload", {}))
    card_id = str(action.get("card_id", ""))
    if card_id:
        payload["card_id"] = card_id
        action["source"] = {
            "card_id": card_id,
            "slot": _slot_for_card(state, card_id),
        }
    if "attack_index" in action:
        payload["attack_index"] = int(action["attack_index"])
    target_id = str(action.get("target_card_id", ""))
    if target_id:
        payload["target_card_id"] = target_id
        action["target"] = {
            "card_id": target_id,
            "slot": _slot_for_card(state, target_id),
        }
    action["payload"] = payload
    return action


def _bytes(handle: BinaryIO, value: bytes) -> None:
    handle.write(struct.pack("<I", len(value)))
    handle.write(value)


def _value(handle: BinaryIO, value: Any) -> None:
    if value is None:
        handle.write(b"n")
    elif value is False:
        handle.write(b"f")
    elif value is True:
        handle.write(b"t")
    elif isinstance(value, int):
        handle.write(b"i" + struct.pack("<q", value))
    elif isinstance(value, float):
        handle.write(b"d" + struct.pack("<d", value))
    elif isinstance(value, str):
        handle.write(b"s")
        _bytes(handle, value.encode("utf-8"))
    elif isinstance(value, list):
        handle.write(b"a" + struct.pack("<I", len(value)))
        for item in value:
            _value(handle, item)
    elif isinstance(value, dict):
        handle.write(b"o" + struct.pack("<I", len(value)))
        for key, item in sorted(value.items()):
            _bytes(handle, str(key).encode("utf-8"))
            _value(handle, item)
    else:
        raise TypeError(type(value).__name__)


def generate(output: Path) -> int:
    cards = json.loads(
        (REPO_ROOT / "godot" / "data" / "cards.json").read_text(encoding="utf-8")
    )
    strategies = json.loads(
        (REPO_ROOT / "godot" / "data" / "ai_strategies.json").read_text(
            encoding="utf-8"
        )
    )
    fixture = json.loads(
        (
            REPO_ROOT
            / "native"
            / "challenge_core"
            / "tests"
            / "fixtures"
            / "challenge_tactics.json"
        ).read_text(encoding="utf-8")
    )
    cases: list[dict[str, Any]] = []
    for deck_key, scenarios in sorted(fixture["decks"].items()):
        for scenario in scenarios:
            state = _state(scenario["context"], deck_key)
            surface = scenario.get("surface", "action")
            preferred = scenario["preferred"]
            over = scenario["over"]
            if surface == "action":
                preferred = _action(preferred, state)
                over = _action(over, state)
            cases.append(
                {
                    "id": scenario["id"],
                    "surface": surface,
                    "state": state,
                    "choice": scenario.get("choice_context", {}),
                    "preferred": preferred,
                    "over": over,
                }
            )
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as handle:
        handle.write(b"PTCGTACT1")
        _value(handle, strategies)
        _value(handle, cards)
        handle.write(struct.pack("<I", len(cases)))
        for case in cases:
            _value(handle, case)
    return len(cases)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(f"generated={generate(args.output.resolve())}")


if __name__ == "__main__":
    main()
