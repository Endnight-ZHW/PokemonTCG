from __future__ import annotations

import importlib
import json
from pathlib import Path
import sys
import unittest

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "python"))

from card_data.authoring_dsl import (
    CardEffectSpec,
    compile_card_ir_v3,
    discover_card_sources,
    iter_effect_specs,
    card_specs_from_mappings,
)
from card_data.cards import (
    CARD_DEFINITIONS,
    CARD_EFFECT_DEFINITIONS,
    CARD_EFFECT_SPECS,
)
from data.deck_definitions import ALL_CARD_IDS
from engine.commands.descriptors import VM_COMMAND_DESCRIPTORS
from scripts.card_author import (
    CARD_AUTHOR_TEST_MODULES,
    FOCUSED_NATIVE_CARD_TESTS,
)


class CardAuthoringDslTests(unittest.TestCase):
    def test_release_catalog_crosses_typed_authoring_boundary(self):
        self.assertEqual(set(CARD_EFFECT_SPECS), set(ALL_CARD_IDS))
        self.assertTrue(all(
            isinstance(spec, CardEffectSpec)
            for spec in CARD_EFFECT_SPECS.values()
        ))
        self.assertEqual(
            {
                card_id: spec.to_authoring_dict()
                for card_id, spec in CARD_EFFECT_SPECS.items()
            },
            CARD_EFFECT_DEFINITIONS,
        )

    def test_card_ir_v3_has_complete_source_mapping_and_fingerprint(self):
        source_index = discover_card_sources(
            REPO_ROOT / "python" / "card_data" / "cards"
        )
        self.assertEqual(source_index.duplicate_card_ids, ())
        specs = card_specs_from_mappings(
            CARD_EFFECT_DEFINITIONS,
            source_index=source_index,
        )
        card_ir = compile_card_ir_v3(specs, all_card_ids=ALL_CARD_IDS)
        self.assertEqual(card_ir["format"], "ptcg_card_ir/3")
        self.assertEqual(card_ir["vm_ir_version"], 3)
        self.assertEqual(card_ir["card_count"], 137)
        self.assertEqual(card_ir["authored_card_count"], 137)
        self.assertEqual(card_ir["effect_count"], 160)
        self.assertEqual(card_ir["source_mapped_effect_count"], 160)
        self.assertEqual(card_ir["source_map_coverage"], 1.0)
        self.assertEqual(len(VM_COMMAND_DESCRIPTORS), 80)
        self.assertRegex(card_ir["content_fingerprint"], r"^[0-9a-f]{64}$")
        self.assertRegex(card_ir["contract_fingerprint"], r"^[0-9a-f]{64}$")
        regenerated = compile_card_ir_v3(specs, all_card_ids=ALL_CARD_IDS)
        self.assertEqual(regenerated, card_ir)

    def test_generated_card_ir_is_current(self):
        generated = json.loads(
            (REPO_ROOT / "godot" / "data" / "card_ir_v3.json").read_text(
                encoding="utf-8"
            )
        )
        source_index = discover_card_sources(
            REPO_ROOT / "python" / "card_data" / "cards"
        )
        current = compile_card_ir_v3(
            card_specs_from_mappings(
                CARD_EFFECT_DEFINITIONS,
                source_index=source_index,
            ),
            all_card_ids=ALL_CARD_IDS,
        )
        self.assertEqual(generated, current)

    def test_all_effects_are_typed_and_have_known_ops(self):
        effects = [
            effect
            for spec in CARD_EFFECT_SPECS.values()
            for effect in iter_effect_specs(spec)
        ]
        self.assertEqual(len(effects), 160)
        self.assertEqual(len({effect.effect_type for effect in effects}), 77)

    def test_release_card_semantic_parameters_distinguish_similar_mechanics(self):
        recoil_cards = set()
        counter_ability_cards = set()
        coin_branch_types = set()
        for card_id, definition in CARD_EFFECT_DEFINITIONS.items():
            for attack in definition.get("attacks", {}).values():
                for effect in attack.get("effects", []):
                    if effect.get("effect_type") == "damage_counter_self":
                        recoil_cards.add(card_id)
                        self.assertEqual(
                            effect.get("params", {}).get("damage_kind"),
                            "self_damage",
                            card_id,
                        )
                    if effect.get("effect_type") == "coin_flip":
                        for branch in ("on_heads", "on_tails"):
                            coin_branch_types.update(
                                nested.get("effect_type", "")
                                for nested in effect.get("params", {}).get(
                                    branch,
                                    [],
                                )
                            )
            for ability in definition.get("abilities", {}).values():
                for effect in ability.get("effects", []):
                    if effect.get("effect_type") == "damage_counter_self":
                        counter_ability_cards.add(card_id)
                        self.assertNotIn(
                            "damage_kind",
                            effect.get("params", {}),
                            card_id,
                        )

        self.assertEqual(len(recoil_cards), 8)
        self.assertEqual(counter_ability_cards, {"svd-dodrio", "svf-luca"})
        self.assertEqual(
            coin_branch_types,
            {"attack_fail", "energy_discard", "prevent_all", "status"},
        )
        self.assertTrue(
            CARD_EFFECT_DEFINITIONS["svi-ente"]["abilities"]["压迫感"]
            ["effects"][0]["params"]["requires_active"]
        )
        self.assertTrue(
            CARD_EFFECT_DEFINITIONS["svi-ente"]["abilities"]["压迫感"]
            ["effects"][0]["params"]["before_weakness"]
        )
        for card_id in ("sv1-109", "svl-chat"):
            cycle_draw = next(
                attack
                for attack in CARD_DEFINITIONS[card_id]["attacks"]
                if attack["name"] == "循环抽取"
            )
            self.assertIn("若这样做", cycle_draw["text"])
        self.assertEqual(
            CARD_EFFECT_DEFINITIONS["svf-terr"]["attacks"]["岩窟冲撞"]
            ["effects"][1]["params"]["scope"],
            "player",
        )
        self.assertEqual(
            CARD_EFFECT_DEFINITIONS["svm-skarmory"]["attacks"]["钢铁之刃"]
            ["effects"][0]["params"]["scope"],
            "self",
        )
        self.assertEqual(
            CARD_EFFECT_DEFINITIONS["svd-darkrai"]["attacks"]["漆黑之刃"]
            ["effects"][0]["params"]["scope"],
            "all",
        )
        self.assertEqual(
            CARD_EFFECT_DEFINITIONS["sv2-tatsu"]["attacks"]["预先准备"]
            ["effects"][0]["params"]["filter"],
            "basic_water",
        )
        self.assertEqual(
            CARD_EFFECT_DEFINITIONS["sv1-108"]["abilities"]["以太感知"]
            ["effects"][0]["params"]["filter"],
            "basic_psychic",
        )
        for card_id, expected in {
            "svi-chiy": "basic_fire",
            "svd-dark-patch": "basic_darkness",
        }.items():
            definition = CARD_EFFECT_DEFINITIONS[card_id]
            effects = (
                next(iter(definition["attacks"].values()))["effects"]
                if "attacks" in definition
                else [definition["trainer_effect"]]
            )
            self.assertEqual(
                effects[0]["params"]["energy_type"],
                expected,
            )
        mela_attach = CARD_EFFECT_DEFINITIONS["svi-mela"][
            "trainer_effect"
        ]["params"]["on_pay"][0]
        self.assertEqual(
            mela_attach["params"]["energy_type"],
            "basic_fire",
        )

    def test_card_author_test_registry_only_references_live_tests(self):
        for module_name in CARD_AUTHOR_TEST_MODULES:
            self.assertIsNotNone(importlib.import_module(module_name))
        for qualified_names in FOCUSED_NATIVE_CARD_TESTS.values():
            for qualified_name in qualified_names:
                module_name, class_name, method_name = qualified_name.rsplit(".", 2)
                test_class = getattr(importlib.import_module(module_name), class_name)
                self.assertTrue(callable(getattr(test_class, method_name)))


if __name__ == "__main__":
    unittest.main()
