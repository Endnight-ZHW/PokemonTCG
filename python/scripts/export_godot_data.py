"""Export the Python-authoritative card data into deterministic Godot assets."""
from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path
from typing import Any

PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from card_data.cards import CARD_EFFECT_DEFINITIONS
from card_data.authoring_dsl import (
    card_specs_from_mappings,
    compile_card_ir_v3,
    discover_card_sources,
)
from card_data.consistency import (
    assert_card_rules_consistent,
)
from data.ai_strategy_definitions import build_ai_strategy_catalog
from data.deck_definitions import ALL_CARD_IDS
from engine.commands.ir import (
    compile_effect_to_spec,
)
from engine.commands.ir import OP_BY_EFFECT_TYPE, SUPPORTED_EFFECT_TYPES
from engine.commands.descriptors import (
    VM_COMMAND_DESCRIPTORS,
    descriptor_export_payload,
)
from engine.commands.vm_contract import (
    VM_IR_VERSION,
    iter_command_specs,
    validate_command_spec,
)
from engine.enums import PlayerAction
from scripts.godot_export.card_data import (
    DECKS,
    build_card_payload,
    build_deck_payload,
)
from scripts.godot_export.contracts import (
    build_data_contract,
    effect_examples,
    effect_types,
    load_frozen_fixture,
    load_release_manifest,
)
from scripts.godot_export.resources import (
    exported_image_errors,
    image_hashes,
    image_paths,
    load_image_mapping,
    write_json,
)

DEFAULT_OUTPUT = REPO_ROOT / "godot"
RELEASE_MANIFEST_PATH = REPO_ROOT / "godot" / "data" / "release_manifest.json"

def _release_manifest() -> dict[str, Any]:
    return load_release_manifest(RELEASE_MANIFEST_PATH, set(DECKS))

_RUNTIME_ONLY_VM_OPS = {
    "deal_damage_per_discard_psychic": "compatibility_formula_op",
    "deal_damage_per_energy": "compatibility_formula_op",
    "deal_damage_per_evolved": "compatibility_formula_op",
    "deal_damage_per_hand_size": "compatibility_formula_op",
    "deal_damage_per_self_damage": "compatibility_formula_op",
    "deal_damage_per_self_energy": "compatibility_formula_op",
    "deal_damage_per_self_energy_type": "compatibility_formula_op",
    "deal_damage_plus_bench": "compatibility_formula_op",
    "deal_damage_with_self_penalty": "compatibility_formula_op",
    "set_attack_damage_formula": "compatibility_formula_op",
    "trigger_draw_cards": "trigger_op",
    "trigger_move_basic_energy": "trigger_op",
    "trigger_place_damage_counters": "trigger_op",
    "trigger_switch_with_active": "trigger_op",
}


_TRACE_SEMANTICS: dict[str, dict[str, list[str]]] = {
    "basic_attach_attack": {
        "effect_types": ["energy_discard"],
        "vm_ops": ["discard_energy"],
        "features": ["basic_placement", "manual_energy_attachment", "base_attack"],
    },
    "double_turbo_retreat": {
        "effect_types": [],
        "vm_ops": [],
        "features": [
            "special_energy_retreat",
            "retreat",
            "pending_choice",
            "retreat_payment",
        ],
    },
    "evolution_preserves_attachments": {
        "effect_types": [],
        "vm_ops": [],
        "features": ["evolution"],
    },
    "pending_attack_choice_continuation": {
        "effect_types": ["energy_attach"],
        "vm_ops": ["attach_energy"],
        "features": ["pending_choice", "continuation_selected"],
    },
    "pending_attack_choice_cancel": {
        "effect_types": ["energy_attach"],
        "vm_ops": ["attach_energy"],
        "features": ["pending_choice", "continuation_cancelled", "deck_shuffle"],
    },
    "supporter_draw": {
        "effect_types": ["draw"],
        "vm_ops": ["draw_cards"],
        "features": ["supporter"],
    },
    "tool_attachment": {
        "effect_types": [],
        "vm_ops": [],
        "features": ["tool_attachment"],
    },
    "ability_damage_draw": {
        "effect_types": ["damage_counter_self", "draw"],
        "vm_ops": ["place_damage_counters", "draw_cards"],
        "features": ["ability"],
    },
    "activatable_stadium": {
        "effect_types": [],
        "vm_ops": ["draw_cards"],
        "features": ["synthetic_stadium_fixture", "stadium_activation"],
    },
    "end_turn": {
        "effect_types": [],
        "vm_ops": [],
        "features": ["end_turn", "next_turn_draw"],
    },
    "confused_attack_tails": {
        "effect_types": [],
        "vm_ops": [],
        "features": ["portable_coin_flip", "confused_attack_failure", "attack_turn_finish"],
    },
    "ko_then_promote": {
        "effect_types": ["energy_discard"],
        "vm_ops": ["discard_energy"],
        "features": ["knockout", "prize", "promotion", "attack_turn_finish"],
    },
    "heal_supporter": {
        "effect_types": ["heal"],
        "vm_ops": ["heal_damage"],
        "features": ["supporter", "direct_heal"],
    },
    "shuffle_draw_supporter": {
        "effect_types": ["shuffle_draw"],
        "vm_ops": ["shuffle_then_draw_cards"],
        "features": ["supporter", "portable_deck_shuffle", "draw_after_shuffle"],
    },
    "heal_all_ability": {
        "effect_types": ["heal_all"],
        "vm_ops": ["heal_all"],
        "features": ["ability", "multi_pokemon_heal"],
    },
    "damage_then_self_heal_attack": {
        "effect_types": ["damage_and_self_heal"],
        "vm_ops": ["deal_damage_then_heal"],
        "features": ["attack_effect_damage", "self_heal", "attack_turn_finish"],
    },
    "formula_damage_attack": {
        "effect_types": ["attack_damage_formula"],
        "vm_ops": ["deal_damage"],
        "features": ["formula_ast", "self_damage_counter_formula", "attack_turn_finish"],
    },
    "prevent_damage_and_lock_attack": {
        "effect_types": ["prevent_damage", "self_attack_lock"],
        "vm_ops": ["prevent_damage", "apply_self_attack_lock"],
        "features": ["damage_prevention_marker", "self_attack_lock_marker"],
    },
    "conditional_status_attack": {
        "effect_types": ["conditional_status"],
        "vm_ops": ["conditional_status"],
        "features": ["ko_by_attack_condition", "status_application"],
    },
    "conditional_damage_heal_attack": {
        "effect_types": ["conditional_damage_heal"],
        "vm_ops": ["conditional_damage_then_heal"],
        "features": ["healed_this_turn_condition", "conditional_damage"],
    },
    "prevent_effects_attack": {
        "effect_types": ["prevent_effects"],
        "vm_ops": ["prevent_effects"],
        "features": ["effect_prevention_marker", "attack_turn_finish"],
    },
    "search_energy_attack": {
        "effect_types": ["search"],
        "vm_ops": ["search_cards"],
        "features": ["pending_choice", "deck_search", "deck_shuffle"],
    },
    "potion_heal_choice": {
        "effect_types": ["potion_heal"],
        "vm_ops": ["choose_heal_damage"],
        "features": ["pending_choice", "bench_target", "item_heal"],
    },
}


def _rules_coverage(
    golden_actions: dict[str, Any],
    vm_semantic_golden: dict[str, Any],
) -> dict[str, Any]:
    """Build a strict mapping inventory without overstating semantic coverage."""
    release_effects = set(effect_types(CARD_EFFECT_DEFINITIONS))
    registered_effects = set(SUPPORTED_EFFECT_TYPES)
    examples = effect_examples(CARD_EFFECT_DEFINITIONS)
    effect_to_op = dict(OP_BY_EFFECT_TYPE)
    effect_to_op.update({
        effect_type: compile_effect_to_spec(example).op
        for effect_type, example in examples.items()
    })
    registered_ops = set(VM_COMMAND_DESCRIPTORS)
    descriptor_payload = descriptor_export_payload(VM_IR_VERSION)
    descriptor_ops = set(descriptor_payload["descriptors"])
    produced_ops = set(effect_to_op.values())
    runtime_only_ops = registered_ops - produced_ops
    cases = dict(golden_actions.get("cases", {}))
    vm_cases = dict(vm_semantic_golden.get("cases", {}))
    vm_executed_ops = set(vm_semantic_golden.get("executed_ops", []))

    if descriptor_ops != registered_ops:
        raise RuntimeError(
            "VM descriptors and Python handlers must be 1:1; "
            f"missing_handlers={sorted(descriptor_ops - registered_ops)} "
            f"missing_descriptors={sorted(registered_ops - descriptor_ops)}"
        )

    if release_effects - registered_effects:
        raise RuntimeError(
            f"Release effects missing registrations: {sorted(release_effects - registered_effects)}"
        )
    if set(effect_to_op) != registered_effects:
        raise RuntimeError("Every registered effect must have exactly one VM op mapping")
    if produced_ops - registered_ops:
        raise RuntimeError(
            f"Effect mappings target unregistered VM ops: {sorted(produced_ops - registered_ops)}"
        )
    if runtime_only_ops != set(_RUNTIME_ONLY_VM_OPS):
        raise RuntimeError(
            "Every registered VM op not produced by an effect mapping must have an "
            f"explicit classification; missing={sorted(runtime_only_ops - set(_RUNTIME_ONLY_VM_OPS))} "
            f"stale={sorted(set(_RUNTIME_ONLY_VM_OPS) - runtime_only_ops)}"
        )
    if set(_TRACE_SEMANTICS) != set(cases):
        raise RuntimeError(
            f"Trace semantics inventory differs from generated cases: "
            f"missing={sorted(set(cases) - set(_TRACE_SEMANTICS))} "
            f"stale={sorted(set(_TRACE_SEMANTICS) - set(cases))}"
        )
    if (
        int(vm_semantic_golden.get("fixture_version", 0)) != 2
        or vm_executed_ops != registered_ops
        or set(vm_cases) != registered_ops
    ):
        raise RuntimeError(
            "Native VM semantic fixture must execute every registered op; "
            f"missing={sorted(registered_ops - vm_executed_ops)} "
            f"extra={sorted(vm_executed_ops - registered_ops)}"
        )
    for op, row in vm_cases.items():
        if (
            str(row.get("descriptor", {}).get("op", "")) != op
            or str(row.get("command_spec", {}).get("op", "")) != op
            or not bool(row.get("expected", {}).get("success", False))
        ):
            raise RuntimeError(
                f"VM semantic case is not a successful direct execution: {op}"
            )

    action_to_cases: dict[str, list[str]] = {action.name: [] for action in PlayerAction}
    for case_name, row in cases.items():
        for action in row.get("actions", []):
            action_name = str(action.get("action", ""))
            if action_name in action_to_cases and case_name not in action_to_cases[action_name]:
                action_to_cases[action_name].append(case_name)
    untraced_actions = [name for name, mapped in action_to_cases.items() if not mapped]
    if untraced_actions:
        raise RuntimeError(f"Public PlayerAction values lack a trace: {untraced_actions}")

    vm_op_mappings: dict[str, dict[str, Any]] = {}
    for op in sorted(registered_ops):
        effect_sources = sorted(
            effect_type
            for effect_type, mapped_op in effect_to_op.items()
            if mapped_op == op
        )
        vm_op_mappings[op] = {
            "effect_types": effect_sources,
            "classification": (
                "effect_compiler" if effect_sources else _RUNTIME_ONLY_VM_OPS[op]
            ),
        }

    semantic_effects = sorted({
        effect_type
        for row in _TRACE_SEMANTICS.values()
        for effect_type in row["effect_types"]
    })
    public_semantic_ops = sorted({
        op for row in _TRACE_SEMANTICS.values() for op in row["vm_ops"]
    })
    semantic_ops = sorted(set(public_semantic_ops) | vm_executed_ops)
    if not set(semantic_effects).issubset(release_effects):
        raise RuntimeError("Semantic trace effect labels must be release effect types")
    if not set(semantic_ops).issubset(registered_ops):
        raise RuntimeError("Semantic trace VM op labels must be registered VM ops")

    step_count = sum(len(row.get("trace", [])) for row in cases.values())
    return {
        "coverage_version": 3,
        "mapping_inventory": {
            "release_effect_types": sorted(release_effects),
            "registered_effect_types": sorted(registered_effects),
            "non_release_registered_effect_types": sorted(
                registered_effects - release_effects
            ),
            "effect_to_vm_op": {
                key: effect_to_op[key] for key in sorted(effect_to_op)
            },
            "registered_vm_ops": sorted(registered_ops),
            "vm_op_mappings": vm_op_mappings,
            "public_player_actions": sorted(action_to_cases),
            "action_to_trace_cases": action_to_cases,
        },
        "vm_descriptor_contract": {
            "descriptor_schema_version": descriptor_payload[
                "descriptor_schema_version"
            ],
            "descriptor_digest": descriptor_payload["descriptor_digest"],
            "descriptor_ops": sorted(descriptor_ops),
            "handler_ops": sorted(registered_ops),
            "preflight_ops": sorted(
                op for op, descriptor in descriptor_payload["descriptors"].items()
                if str(descriptor.get("preflight_evaluator", ""))
            ),
            "golden_ops": sorted(vm_cases),
            "executed_ops": sorted(vm_executed_ops),
        },
        "semantic_trace_inventory": {
            "case_count": len(cases),
            "transaction_step_count": step_count,
            "native_vm_case_count": len(vm_cases),
            "case_semantics": _TRACE_SEMANTICS,
            "native_vm_fixture": "vm_native_golden.json",
            "public_trace_vm_ops_executed": public_semantic_ops,
            "release_effect_types_executed": semantic_effects,
            "registered_vm_ops_executed": semantic_ops,
            "release_effect_types_not_executed": sorted(
                release_effects - set(semantic_effects)
            ),
            "registered_vm_ops_not_executed": sorted(
                registered_ops - set(semantic_ops)
            ),
            "known_cross_runtime_semantic_gaps": list(
                vm_semantic_golden.get(
                    "known_cross_runtime_semantic_gaps", []
                )
            ),
            "explicitly_not_claimed": [
                "all_release_effect_semantics",
            ],
        },
        "counts": {
            "release_effect_types": len(release_effects),
            "registered_effect_types": len(registered_effects),
            "mapped_registered_effect_types": len(effect_to_op),
            "registered_vm_ops": len(registered_ops),
            "mapped_registered_vm_ops": len(vm_op_mappings),
            "public_player_actions": len(action_to_cases),
            "traced_public_player_actions": sum(bool(rows) for rows in action_to_cases.values()),
            "semantic_release_effect_types": len(semantic_effects),
            "semantic_registered_vm_ops": len(semantic_ops),
        },
    }


def export(output: Path, *, copy_images: bool = True) -> dict[str, Any]:
    del copy_images  # Images already live at the canonical Godot asset path.
    image_mapping = load_image_mapping(REPO_ROOT, ALL_CARD_IDS)
    card_image_paths = image_paths(image_mapping)
    card_image_hashes = image_hashes(REPO_ROOT, image_mapping)
    cards = build_card_payload(card_image_paths)
    decks = build_deck_payload()
    descriptor_payload = descriptor_export_payload(VM_IR_VERSION)
    descriptor_ops = set(descriptor_payload["descriptors"])

    for spec_index, spec in enumerate(iter_command_specs(cards)):
        errors = validate_command_spec(
            spec,
            supported_ops=descriptor_ops,
            descriptors=VM_COMMAND_DESCRIPTORS,
            allow_internal=False,
            path=f"$.cards.command_specs[{spec_index}]",
        )
        if errors:
            raise RuntimeError(
                "Compiled release card VM contract is invalid: "
                + "; ".join(errors)
            )

    # Fail the authoritative export before writing derived assets when any
    # printed rules segment lacks a runtime binding or either runtime exposes a
    # VM operation the other side cannot execute.
    card_rules_matrix = assert_card_rules_consistent(
        peer_supported_ops=descriptor_ops,
    )
    source_index = discover_card_sources(PYTHON_ROOT / "card_data" / "cards")
    if source_index.duplicate_card_ids:
        raise RuntimeError(
            "Duplicate card effect source IDs: "
            + ", ".join(source_index.duplicate_card_ids)
        )
    typed_specs = card_specs_from_mappings(
        CARD_EFFECT_DEFINITIONS,
        source_index=source_index,
    )
    card_ir = compile_card_ir_v3(typed_specs, all_card_ids=ALL_CARD_IDS)
    if card_ir["source_mapped_effect_count"] != card_ir["effect_count"]:
        raise RuntimeError("Card IR source-map coverage is incomplete")

    data_root = output / "data"
    manifest = _release_manifest()
    write_json(data_root / "cards.json", cards)
    write_json(data_root / "card_ir_v3.json", card_ir)
    write_json(data_root / "decks.json", decks)
    write_json(data_root / "ai_strategies.json", build_ai_strategy_catalog(DECKS))
    write_json(data_root / "card_images.json", card_image_paths)
    write_json(data_root / "card_image_hashes.json", card_image_hashes)
    write_json(data_root / "release_manifest.json", manifest)
    write_json(data_root / "vm_command_descriptors.json", descriptor_payload)
    golden = build_data_contract(cards, decks, CARD_EFFECT_DEFINITIONS, manifest)
    write_json(output / "tests" / "fixtures" / "data_contract.json", golden)
    # Rule fixtures are language-neutral frozen inputs now.  C++ owns their
    # execution tests; the Python authoring export copies them without running
    # a second rules implementation.
    golden_actions = load_frozen_fixture(REPO_ROOT, "rules_golden.json")
    write_json(
        output / "tests" / "fixtures" / "rules_golden.json",
        golden_actions,
    )
    vm_semantic_golden = load_frozen_fixture(REPO_ROOT, "vm_native_golden.json")
    write_json(
        output / "tests" / "fixtures" / "vm_native_golden.json",
        vm_semantic_golden,
    )
    write_json(
        output / "tests" / "fixtures" / "rules_coverage.json",
        _rules_coverage(golden_actions, vm_semantic_golden),
    )
    write_json(
        output / "tests" / "fixtures" / "card_rules_matrix.json",
        card_rules_matrix,
    )
    return golden


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--skip-images", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        output = args.output.resolve()
        with tempfile.TemporaryDirectory() as temporary:
            generated = Path(temporary)
            export(generated, copy_images=False)
            relative_paths = [
                Path("data/cards.json"),
                Path("data/card_ir_v3.json"),
                Path("data/decks.json"),
                Path("data/ai_strategies.json"),
                Path("data/card_images.json"),
                Path("data/card_image_hashes.json"),
                Path("data/release_manifest.json"),
                Path("data/vm_command_descriptors.json"),
                Path("tests/fixtures/data_contract.json"),
                Path("tests/fixtures/rules_golden.json"),
                Path("tests/fixtures/vm_native_golden.json"),
                Path("tests/fixtures/rules_coverage.json"),
                Path("tests/fixtures/card_rules_matrix.json"),
            ]
            stale = [
                str(path)
                for path in relative_paths
                if not (output / path).is_file()
                or (output / path).read_bytes() != (generated / path).read_bytes()
            ]
            if stale:
                raise SystemExit(
                    "Godot generated data is stale: "
                    + ", ".join(stale)
                    + ". Run python/scripts/export_godot_data.py."
                )
            image_errors = exported_image_errors(
                output,
                load_image_mapping(REPO_ROOT, ALL_CARD_IDS),
            )
            if image_errors:
                raise SystemExit(
                    "Godot card images are stale: "
                    + ", ".join(image_errors)
                    + ". Run python/scripts/export_godot_data.py."
                )
        print("Godot generated data is current.")
        return
    result = export(args.output.resolve(), copy_images=not args.skip_images)
    print(
        f"Exported {result['counts']['cards']} cards, "
        f"{result['counts']['decks']} decks and "
        f"{result['counts']['effects']} effect types."
    )


if __name__ == "__main__":
    main()
