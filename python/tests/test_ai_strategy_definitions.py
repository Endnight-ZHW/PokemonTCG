from __future__ import annotations

import hashlib
import json
import re
import sys
import unittest
from copy import deepcopy
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from data.ai_strategy_definitions import (
    CATALOG_SCHEMA,
    CATALOG_VERSION,
    GOLDEN_CATEGORIES,
    RUNTIME_HOOK_FILES,
    STRATEGY_SCHEMA,
    STRATEGY_VERSION,
    build_ai_strategy_catalog,
    runtime_hook_hash,
)
from scripts.export_godot_data import DECKS


REPO_ROOT = Path(__file__).resolve().parents[2]
EXPORTED_PATH = REPO_ROOT / "godot" / "data" / "ai_strategies.json"


def _content_hash(payload: dict) -> str:
    canonical = deepcopy(payload)
    canonical.pop("content_hash", None)
    encoded = json.dumps(
        canonical,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


class AIStrategyDefinitionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.catalog = build_ai_strategy_catalog(DECKS)
        cls.manifest = json.loads(
            (REPO_ROOT / "release_manifest.json").read_text(encoding="utf-8")
        )

    def test_catalog_covers_exactly_ten_release_decks(self):
        release_keys = self.manifest["release_decks"]
        self.assertEqual(len(release_keys), 10)
        self.assertEqual(set(self.catalog["strategies"]), set(release_keys))
        self.assertEqual(set(self.catalog["deck_archetypes"]), set(release_keys))

    def test_every_strategy_has_complete_versioned_content(self):
        self.assertEqual(self.catalog["schema"], CATALOG_SCHEMA)
        self.assertEqual(self.catalog["version"], CATALOG_VERSION)
        self.assertEqual(self.catalog["content_hash"], _content_hash(self.catalog))
        self.assertRegex(self.catalog["content_hash"], r"^[0-9a-f]{64}$")

        strategy_ids: set[str] = set()
        for deck_key, strategy in self.catalog["strategies"].items():
            with self.subTest(deck_key=deck_key):
                self.assertEqual(strategy["schema"], STRATEGY_SCHEMA)
                self.assertEqual(strategy["version"], STRATEGY_VERSION)
                self.assertEqual(strategy["deck_key"], deck_key)
                self.assertTrue(strategy["strategy_id"])
                self.assertNotIn(strategy["strategy_id"], strategy_ids)
                strategy_ids.add(strategy["strategy_id"])
                self.assertRegex(strategy["content_hash"], r"^[0-9a-f]{64}$")
                self.assertEqual(strategy["content_hash"], _content_hash(strategy))
                self.assertRegex(strategy["runtime_hook_hash"], r"^[0-9a-f]{64}$")
                self.assertEqual(strategy["runtime_hook_hash"], runtime_hook_hash(deck_key))
                self.assertIsInstance(strategy["card_roles"], dict)
                self.assertTrue(strategy["card_roles"])
                self.assertIsInstance(strategy["stage_goals"], list)
                self.assertTrue(strategy["stage_goals"])
                self.assertIsInstance(strategy["weights"], dict)
                self.assertTrue(strategy["weights"])
                self.assertIsInstance(strategy["matchup_weights"], dict)
                self.assertTrue(strategy["matchup_weights"])
                self.assertGreaterEqual(len(strategy["golden_scenarios"]), 8)
                self.assertLessEqual(len(strategy["golden_scenarios"]), 12)

        fallback = self.catalog["fallback"]
        self.assertEqual(fallback["strategy_id"], "generic_balanced_v1")
        self.assertEqual(fallback["version"], STRATEGY_VERSION)
        self.assertRegex(fallback["content_hash"], r"^[0-9a-f]{64}$")
        self.assertEqual(fallback["content_hash"], _content_hash(fallback))
        self.assertRegex(fallback["runtime_hook_hash"], r"^[0-9a-f]{64}$")
        self.assertEqual(fallback["runtime_hook_hash"], runtime_hook_hash("generic"))
        self.assertTrue(fallback["stage_goals"])
        self.assertTrue(fallback["weights"])

    def test_runtime_hook_hash_is_portable_and_covered_by_content_hash(self):
        strategy_root = REPO_ROOT / "godot" / "ai" / "strategies"
        for deck_key, hook_name in RUNTIME_HOOK_FILES.items():
            with self.subTest(deck_key=deck_key):
                digest = hashlib.sha256()
                for file_name in ("deck_strategy.gd", hook_name):
                    source = (
                        (strategy_root / file_name)
                        .read_text(encoding="utf-8")
                        .replace("\r\n", "\n")
                        .replace("\r", "\n")
                    )
                    digest.update(file_name.encode("utf-8"))
                    digest.update(b"\0")
                    digest.update(source.encode("utf-8"))
                    digest.update(b"\0")
                self.assertEqual(runtime_hook_hash(deck_key), digest.hexdigest())

        fire = deepcopy(self.catalog["strategies"]["fire"])
        original_hash = fire["content_hash"]
        fire["runtime_hook_hash"] = "0" * 64
        self.assertNotEqual(original_hash, _content_hash(fire))

    def test_goldens_are_deck_valid_and_cover_all_tactical_categories(self):
        total = 0
        for deck_key, strategy in self.catalog["strategies"].items():
            deck_card_ids = {card_id for card_id, _count in DECKS[deck_key]["cards"]}
            goal_ids = {goal["id"] for goal in strategy["stage_goals"]}
            scenarios = strategy["golden_scenarios"]
            total += len(scenarios)
            self.assertGreaterEqual(len(scenarios), 8)
            self.assertLessEqual(len(scenarios), 12)
            self.assertEqual(
                {scenario["category"] for scenario in scenarios},
                set(GOLDEN_CATEGORIES),
            )
            self.assertEqual(
                len({scenario["id"] for scenario in scenarios}),
                len(scenarios),
            )
            for scenario in scenarios:
                with self.subTest(deck_key=deck_key, scenario=scenario["id"]):
                    self.assertEqual(scenario["expected"], "higher")
                    self.assertIn(scenario["stage"], goal_ids)
                    self.assertIn(scenario["surface"], {"action", "choice"})
                    self.assertIsInstance(scenario["context"], dict)
                    self.assertIsInstance(scenario["preferred"], dict)
                    self.assertIsInstance(scenario["over"], dict)
                    encoded = json.dumps(scenario, ensure_ascii=False)
                    declared_ids = set(re.findall(r'"(?:card_id|target_card_id)": "([^"]+)"', encoded))
                    energy_lists = re.findall(r'"energy_card_ids": \[([^\]]*)\]', encoded)
                    for values in energy_lists:
                        declared_ids.update(re.findall(r'"([^"]+)"', values))
                    self.assertLessEqual(declared_ids, deck_card_ids)
        self.assertGreaterEqual(total, 100)

    def test_runtime_hooks_use_attack_indices_and_base_consumes_goal_hints(self):
        strategy_root = REPO_ROOT / "godot" / "ai" / "strategies"
        for deck_key, hook_name in RUNTIME_HOOK_FILES.items():
            if deck_key == "generic":
                continue
            with self.subTest(deck_key=deck_key):
                source = (strategy_root / hook_name).read_text(encoding="utf-8")
                self.assertIn("_attack_index(action_row)", source)
        base = (strategy_root / "deck_strategy.gd").read_text(encoding="utf-8")
        for required_hook in (
            "choice_mode(info, choice_view)",
            "stage_goal_action_adjustment(info, action_row)",
            "stage_goal_state_adjustment(info)",
            "candidate_score(info, action_row, semantic_catalog)",
        ):
            self.assertIn(required_hook, base)

    def test_role_cards_belong_to_their_release_deck(self):
        for deck_key, strategy in self.catalog["strategies"].items():
            deck_card_ids = {
                card_id for card_id, _count in DECKS[deck_key]["cards"]
            }
            assigned_card_ids: set[str] = set()
            for role, card_ids in strategy["card_roles"].items():
                with self.subTest(deck_key=deck_key, role=role):
                    self.assertTrue(card_ids)
                    self.assertEqual(len(card_ids), len(set(card_ids)))
                    self.assertLessEqual(set(card_ids), deck_card_ids)
                    assigned_card_ids.update(card_ids)
            self.assertEqual(assigned_card_ids, deck_card_ids)

    def test_configuration_and_hooks_do_not_contain_blocked_matchup_terms(self):
        blocked_terms = ("weak" + "ness", "resist" + "ance")
        payload_text = json.dumps(self.catalog, ensure_ascii=False).lower()
        script_text = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted((REPO_ROOT / "godot" / "ai" / "strategies").glob("*.gd"))
        ).lower()
        for term in blocked_terms:
            self.assertNotIn(term, payload_text)
            self.assertNotIn(term, script_text)

    def test_exported_json_matches_the_authoritative_python_catalog(self):
        exported = json.loads(EXPORTED_PATH.read_text(encoding="utf-8"))
        self.assertEqual(exported, self.catalog)
        self.assertTrue(re.fullmatch(r"[0-9a-f]{64}", exported["content_hash"]))


if __name__ == "__main__":
    unittest.main()
