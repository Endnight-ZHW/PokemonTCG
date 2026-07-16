from __future__ import annotations

from pathlib import Path
import unittest

from card_data.consistency import (
    assert_card_rules_consistent,
    build_card_rules_matrix,
    load_godot_vm_ops,
)
from data.deck_definitions import ALL_CARD_IDS
from engine.commands.vm_contract import VM_IR_VERSION


class CardRulesConsistencyTests(unittest.TestCase):
    def test_all_137_cards_have_registered_printed_text_bindings(self):
        root = Path(__file__).resolve().parents[2]
        godot_ops = load_godot_vm_ops(root / "godot/rules/vm/vm_contract.gd")
        matrix = assert_card_rules_consistent(peer_supported_ops=godot_ops)

        self.assertEqual(matrix["card_count"], 137)
        self.assertEqual(matrix["expected_card_count"], len(ALL_CARD_IDS))
        self.assertEqual(matrix["vm_ir_version"], VM_IR_VERSION)
        for card_id, card in matrix["cards"].items():
            for segment in card["segments"]:
                self.assertTrue(segment["text"].strip(), card_id)
                self.assertTrue(segment["bindings"], card_id)
                self.assertTrue(segment["public_action"], card_id)
                self.assertIn("hooks", segment)
                self.assertIn("choice_constraints", segment)

    def test_unknown_or_one_sided_vm_op_fails_closed(self):
        root = Path(__file__).resolve().parents[2]
        godot_ops = set(load_godot_vm_ops(root / "godot/rules/vm/vm_contract.gd"))
        godot_ops.remove(next(iter(godot_ops)))
        matrix = build_card_rules_matrix(peer_supported_ops=godot_ops)
        self.assertTrue(any("Python-only VM ops" in error for error in matrix["errors"]))
        with self.assertRaisesRegex(ValueError, "Python-only VM ops"):
            assert_card_rules_consistent(peer_supported_ops=godot_ops)


if __name__ == "__main__":
    unittest.main()
