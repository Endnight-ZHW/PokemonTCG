"""Card author workflow: lint, focused tests, and catalog status."""
from __future__ import annotations

import argparse
from hashlib import sha256
import json
from pathlib import Path
import sys
import unittest
from typing import Any


PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from card_data.authoring_dsl import (
    compile_card_ir_v3,
    discover_effect_sources,
    iter_effect_specs,
    card_specs_from_mappings,
)
from card_data.consistency import assert_card_rules_consistent, load_godot_vm_ops
from card_data.effects import CARD_EFFECT_DEFINITIONS
from data.deck_definitions import ALL_CARD_IDS
from engine.commands.descriptors import VM_COMMAND_DESCRIPTORS
from engine.commands.vm_contract import iter_command_specs


GENERATED_IR_PATH = REPO_ROOT / "godot" / "data" / "card_ir_v3.json"
CORE_SOURCE_NAMES = (
    "ptcg_random.hpp",
    "ptcg_random.cpp",
    "ptcg_value.hpp",
    "ptcg_rules.hpp",
    "ptcg_rules.cpp",
    "ptcg_game.hpp",
    "ptcg_game.cpp",
    "ptcg_rules_session.hpp",
    "ptcg_rules_session.cpp",
)
FORBIDDEN_CORE_TOKENS = (
    "godot_cpp",
    "pybind11",
    "Python.h",
    "onnxruntime",
    'include "ptcg_ai_core.hpp"',
    'include "ptcg_search.hpp"',
    'include "native_deep_search.hpp"',
)
CHOICE_CAPACITY_ARG_BY_OP = {
    "attach_energy": "amount",
    "attach_energy_from_discard": "amount",
    "deal_bench_damage": "count",
    "discard_cards": "amount",
    "discard_energy": "amount",
    "draw_and_attach_energy": "energy_count",
    "look_top_deck": "take",
    "relocate_energy": "amount",
    "search_any_and_switch": "count",
    "search_cards": "count",
    "shuffle_from_discard_to_deck": "count",
}
FOCUSED_NATIVE_CARD_TESTS = {
    # Author-tool routing only: these are scenario tests, never rule dispatch.
    "sv1-108": (
        "tests.test_native_ai_core.NativeAICoreTests."
        "test_native_legality_honors_authoritative_attack_lock_fields",
        "tests.test_native_ai_core.NativeAICoreTests."
        "test_native_ability_resumes_remaining_effects_after_choice",
    ),
    "svi-chiy": (
        "tests.test_native_ai_core.NativeAICoreTests."
        "test_native_chi_yu_attaches_all_discard_energy_to_first_target",
        "tests.test_native_ai_core.NativeAICoreTests."
        "test_native_chi_yu_discard_distribution_is_protocol_bounded",
    ),
    "svf-terr": (
        "tests.test_native_ai_core.NativeAICoreTests."
        "test_native_named_attack_lock_survives_switch_but_instance_lock_does_not",
    ),
    "svm-skarmory": (
        "tests.test_native_ai_core.NativeAICoreTests."
        "test_native_named_attack_lock_survives_switch_but_instance_lock_does_not",
    ),
}
CARD_AUTHOR_TEST_MODULES = (
    "tests.test_card_authoring_dsl",
    "tests.test_vm_descriptors",
    "tests.test_card_rules_consistency",
)


def build_release_card_ir() -> tuple[dict[str, Any], Any, dict[str, Any]]:
    source_index = discover_effect_sources(PYTHON_ROOT / "card_data" / "effects")
    specs = card_specs_from_mappings(
        CARD_EFFECT_DEFINITIONS,
        source_index=source_index,
    )
    card_ir = compile_card_ir_v3(specs, all_card_ids=ALL_CARD_IDS)
    return card_ir, source_index, specs


def _card_command_payloads(card_payload: dict[str, Any]):
    for block_kind in ("attacks", "abilities"):
        for block_name, block in dict(card_payload.get(block_kind) or {}).items():
            yield f"{block_kind}/{block_name}", list(block.get("commands") or [])
    yield "trainer", list(card_payload.get("trainer_commands") or [])


def _unreachable_choice_errors(card_ir: dict[str, Any]) -> list[str]:
    """Reject choices whose authored minimum exceeds an explicit hard cap."""
    errors: list[str] = []
    for card_id, card_payload in dict(card_ir.get("cards") or {}).items():
        for source, commands in _card_command_payloads(dict(card_payload or {})):
            for command in iter_command_specs(commands):
                op = str(command.get("op", ""))
                descriptor = VM_COMMAND_DESCRIPTORS.get(op, {})
                if not bool(descriptor.get("may_suspend", False)):
                    continue
                args = dict(command.get("args") or {})
                minimum = args.get("min_select")
                capacity_field = CHOICE_CAPACITY_ARG_BY_OP.get(op)
                if type(minimum) is not int or capacity_field is None:
                    continue
                capacity = args.get(capacity_field)
                if type(capacity) is int and minimum > capacity:
                    errors.append(
                        f"{card_id}:{source}:{op} has unreachable choice "
                        f"min_select={minimum} > {capacity_field}={capacity}"
                    )
    return errors


def lint_release_cards(*, check_generated: bool = True) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []
    try:
        card_ir, source_index, specs = build_release_card_ir()
    except Exception as error:  # fail closed with an author-facing diagnostic
        return {
            "ok": False,
            "errors": [f"compile: {error}"],
            "warnings": [],
        }

    if source_index.duplicate_card_ids:
        errors.append(
            "duplicate card IDs: " + ", ".join(source_index.duplicate_card_ids)
        )
    expected_ids = set(map(str, ALL_CARD_IDS))
    if set(specs) != expected_ids:
        errors.append(
            "typed card catalog IDs differ from the frozen release set: "
            f"missing={sorted(expected_ids - set(specs))} "
            f"extra={sorted(set(specs) - expected_ids)}"
        )
    if card_ir["card_count"] != 137:
        errors.append(f"expected 137 cards, got {card_ir['card_count']}")
    if len(VM_COMMAND_DESCRIPTORS) != 80:
        errors.append(
            f"expected 80 VM descriptors, got {len(VM_COMMAND_DESCRIPTORS)}"
        )
    if card_ir["source_mapped_effect_count"] != card_ir["effect_count"]:
        errors.append(
            "source mapping is incomplete: "
            f"{card_ir['source_mapped_effect_count']}/{card_ir['effect_count']}"
        )
    unreachable_choice_errors = _unreachable_choice_errors(card_ir)
    errors.extend(unreachable_choice_errors)

    for card_id, spec in specs.items():
        definition = spec.to_authoring_dict()
        if definition != CARD_EFFECT_DEFINITIONS[card_id]:
            errors.append(
                f"{card_id}: typed authoring roundtrip changed the definition"
            )

    descriptor_path = REPO_ROOT / "godot" / "data" / "vm_command_descriptors.json"
    try:
        peer_ops = load_godot_vm_ops(descriptor_path)
        matrix = assert_card_rules_consistent(peer_supported_ops=peer_ops)
        errors.extend(str(error) for error in matrix.get("errors", []))
    except Exception as error:
        errors.append(f"card rules matrix: {error}")

    core_root = REPO_ROOT / "godot" / "native" / "ptcg_core" / "src"
    core_text: dict[str, str] = {}
    for name in CORE_SOURCE_NAMES:
        path = core_root / name
        if not path.is_file():
            errors.append(f"missing ptcg_core source: {name}")
            continue
        text = path.read_text(encoding="utf-8")
        core_text[name] = text
        for token in FORBIDDEN_CORE_TOKENS:
            if token in text:
                errors.append(f"{name}: forbidden core dependency {token!r}")
    joined_core = "\n".join(core_text.values())
    dispatched_ids = sorted(card_id for card_id in expected_ids if card_id in joined_core)
    if dispatched_ids:
        errors.append(
            "ptcg_core contains release card-ID literals: "
            + ", ".join(dispatched_ids)
        )

    if check_generated:
        if not GENERATED_IR_PATH.is_file():
            errors.append("generated Card IR v3 is missing")
        else:
            try:
                generated = json.loads(GENERATED_IR_PATH.read_text(encoding="utf-8"))
                if generated != card_ir:
                    errors.append(
                        "generated Card IR v3 is stale; run export_godot_data.py"
                    )
            except (OSError, ValueError) as error:
                errors.append(f"generated Card IR v3 is invalid: {error}")
        baseline_path = REPO_ROOT / "contracts" / "rules_migration_baseline.json"
        try:
            baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
            frozen = baseline["fingerprints"]
            frozen_files = {
                "cards_json_sha256": REPO_ROOT / "godot/data/cards.json",
                "decks_json_sha256": REPO_ROOT / "godot/data/decks.json",
                "vm_descriptors_json_sha256": (
                    REPO_ROOT / "godot/data/vm_command_descriptors.json"
                ),
            }
            for field, path in frozen_files.items():
                actual = sha256(path.read_bytes()).hexdigest()
                if actual != frozen.get(field):
                    errors.append(f"migration freeze changed: {field}")
            if card_ir["content_fingerprint"] != frozen.get(
                "card_ir_content_fingerprint"
            ):
                errors.append("migration freeze changed: Card IR content")
            if card_ir["contract_fingerprint"] != frozen.get(
                "card_ir_contract_fingerprint"
            ):
                errors.append("migration freeze changed: Card IR contract")
            if card_ir["descriptor_digest"] != frozen.get(
                "vm_descriptor_digest"
            ):
                errors.append("migration freeze changed: VM descriptor digest")
        except (KeyError, OSError, ValueError, TypeError) as error:
            errors.append(f"migration freeze baseline is invalid: {error}")

    effect_types = sorted({
        effect.effect_type
        for spec in specs.values()
        for effect in iter_effect_specs(spec)
    })
    status = {
        "ok": not errors,
        "format": "ptcg_card_author_status/1",
        "card_ir_version": card_ir["vm_ir_version"],
        "card_count": card_ir["card_count"],
        "authored_card_count": card_ir["authored_card_count"],
        "effect_count": card_ir["effect_count"],
        "effect_type_count": len(effect_types),
        "command_count": card_ir["command_count"],
        "vm_descriptor_count": len(VM_COMMAND_DESCRIPTORS),
        "used_vm_op_count": len(card_ir["used_vm_ops"]),
        "source_mapped_effect_count": card_ir["source_mapped_effect_count"],
        "source_map_coverage": card_ir["source_map_coverage"],
        "content_fingerprint": card_ir["content_fingerprint"],
        "descriptor_digest": card_ir["descriptor_digest"],
        "release_card_id_dispatches": dispatched_ids,
        "unreachable_choice_count": len(unreachable_choice_errors),
        "errors": sorted(set(errors)),
        "warnings": sorted(set(warnings)),
    }
    return status


def _print_status(status: dict[str, Any], *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(status, ensure_ascii=False, indent=2, sort_keys=True))
        return
    state = "OK" if status.get("ok") else "FAILED"
    print(
        f"CARD_AUTHOR_{state} cards={status.get('card_count', 0)} "
        f"effects={status.get('effect_count', 0)} "
        f"effect_types={status.get('effect_type_count', 0)} "
        f"vm_ops={status.get('used_vm_op_count', 0)}/"
        f"{status.get('vm_descriptor_count', 0)} "
        f"source_map={status.get('source_map_coverage', 0):.1%} "
        f"fingerprint={status.get('content_fingerprint', '')}"
    )
    for warning in status.get("warnings", []):
        print(f"warning: {warning}")
    for error in status.get("errors", []):
        print(f"error: {error}", file=sys.stderr)


def _run_card_tests(card_id: str) -> bool:
    if card_id and card_id not in set(map(str, ALL_CARD_IDS)):
        print(f"Unknown release card ID: {card_id}", file=sys.stderr)
        return False
    if card_id:
        card_ir, _source_index, _specs = build_release_card_ir()
        payload = dict(card_ir["cards"][card_id])
        command_count = sum(
            1
            for _source, commands in _card_command_payloads(payload)
            for _command in iter_command_specs(commands)
        )
        if payload.get("source") is None:
            print(f"{card_id}: source location is missing", file=sys.stderr)
            return False
        print(f"CARD_TEST_TARGET card={card_id} commands={command_count}")
    names = list(CARD_AUTHOR_TEST_MODULES)
    names.extend(FOCUSED_NATIVE_CARD_TESTS.get(card_id, ()))
    suite = unittest.defaultTestLoader.loadTestsFromNames(names)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful() and card_id:
        print(f"CARD_TEST_OK card={card_id}")
    return result.wasSuccessful()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    lint = subparsers.add_parser("lint", help="validate Card IR and author contracts")
    lint.add_argument("--json", action="store_true")
    lint.add_argument("--no-generated-check", action="store_true")
    status_parser = subparsers.add_parser("status", help="show card catalog coverage")
    status_parser.add_argument("--json", action="store_true")
    test = subparsers.add_parser("test", help="run card compiler/contract tests")
    test.add_argument("--card", default="")
    args = parser.parse_args()

    if args.command in {"lint", "status"}:
        report = lint_release_cards(
            check_generated=not getattr(args, "no_generated_check", False)
        )
        _print_status(report, as_json=bool(args.json))
        raise SystemExit(0 if report.get("ok") else 1)
    lint_report = lint_release_cards(check_generated=True)
    if not lint_report.get("ok"):
        _print_status(lint_report, as_json=False)
        raise SystemExit(1)
    raise SystemExit(0 if _run_card_tests(str(args.card)) else 1)


if __name__ == "__main__":
    main()
