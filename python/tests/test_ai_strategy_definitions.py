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
    STRATEGY_SCHEMA,
    STRATEGY_VERSION,
    build_ai_strategy_catalog,
)
from scripts.export_godot_data import DECKS


REPO_ROOT = Path(__file__).resolve().parents[2]
EXPORTED_PATH = REPO_ROOT / "godot" / "data" / "ai_strategies.json"
TACTICS_PATH = (
    REPO_ROOT
    / "native"
    / "challenge_core"
    / "tests"
    / "fixtures"
    / "challenge_tactics.json"
)
TACTICAL_CATEGORIES = {
    "setup",
    "evolution",
    "search",
    "switch",
    "attack",
    "prize_route",
    "resource_preservation",
    "loss_avoidance",
}


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
            (REPO_ROOT / "godot" / "data" / "release_manifest.json").read_text(
                encoding="utf-8"
            )
        )
        cls.tactics = json.loads(TACTICS_PATH.read_text(encoding="utf-8"))

    def test_catalog_covers_exactly_the_release_decks(self):
        release_keys = self.manifest["release_decks"]
        self.assertEqual(len(release_keys), 10)
        self.assertEqual(set(self.catalog["strategies"]), set(release_keys))
        self.assertEqual(set(self.catalog["deck_archetypes"]), set(release_keys))

    def test_runtime_catalog_contains_only_native_strategy_data(self):
        self.assertEqual(self.catalog["schema"], CATALOG_SCHEMA)
        self.assertEqual(self.catalog["version"], CATALOG_VERSION)
        self.assertEqual(self.catalog["content_hash"], _content_hash(self.catalog))
        strategy_ids: set[str] = set()
        for deck_key, strategy in self.catalog["strategies"].items():
            with self.subTest(deck_key=deck_key):
                self.assertEqual(strategy["schema"], STRATEGY_SCHEMA)
                self.assertEqual(strategy["version"], STRATEGY_VERSION)
                self.assertEqual(strategy["deck_key"], deck_key)
                self.assertNotIn(strategy["strategy_id"], strategy_ids)
                strategy_ids.add(strategy["strategy_id"])
                self.assertEqual(strategy["content_hash"], _content_hash(strategy))
                self.assertNotIn("runtime_hook_hash", strategy)
                self.assertNotIn("golden_scenarios", strategy)
                for key in (
                    "card_roles",
                    "stage_goals",
                    "weights",
                    "matchup_weights",
                ):
                    self.assertTrue(strategy[key])
        self.assertNotIn("runtime_hook_hash", self.catalog["fallback"])
        self.assertNotIn("golden_scenarios", self.catalog["fallback"])

    def test_tactical_fixture_contains_109_deck_valid_cases(self):
        self.assertEqual(self.tactics["schema"], "ptcg.challenge_tactics")
        self.assertEqual(self.tactics["version"], 1)
        self.assertEqual(set(self.tactics["decks"]), set(self.catalog["strategies"]))
        seen: set[str] = set()
        total = 0
        for deck_key, scenarios in self.tactics["decks"].items():
            deck_card_ids = {card_id for card_id, _count in DECKS[deck_key]["cards"]}
            goal_ids = {
                goal["id"]
                for goal in self.catalog["strategies"][deck_key]["stage_goals"]
            }
            self.assertEqual({row["category"] for row in scenarios}, TACTICAL_CATEGORIES)
            for scenario in scenarios:
                total += 1
                self.assertNotIn(scenario["id"], seen)
                seen.add(scenario["id"])
                self.assertEqual(scenario["expected"], "higher")
                self.assertIn(scenario["stage"], goal_ids)
                self.assertIn(scenario["surface"], {"action", "choice"})
                encoded = json.dumps(scenario, ensure_ascii=False)
                declared = set(
                    re.findall(
                        r'"(?:card_id|target_card_id)": "([^"]+)"', encoded
                    )
                )
                for values in re.findall(r'"energy_card_ids": \[([^\]]*)\]', encoded):
                    declared.update(re.findall(r'"([^"]+)"', values))
                self.assertLessEqual(declared, deck_card_ids)
        self.assertEqual(total, 109)

    def test_role_cards_belong_to_their_release_deck(self):
        for deck_key, strategy in self.catalog["strategies"].items():
            deck_card_ids = {card_id for card_id, _count in DECKS[deck_key]["cards"]}
            assigned: set[str] = set()
            for card_ids in strategy["card_roles"].values():
                self.assertEqual(len(card_ids), len(set(card_ids)))
                self.assertLessEqual(set(card_ids), deck_card_ids)
                assigned.update(card_ids)
            self.assertEqual(assigned, deck_card_ids)

    def test_exported_json_matches_authoritative_catalog(self):
        exported = json.loads(EXPORTED_PATH.read_text(encoding="utf-8"))
        self.assertEqual(exported, self.catalog)
        self.assertTrue(re.fullmatch(r"[0-9a-f]{64}", exported["content_hash"]))


if __name__ == "__main__":
    unittest.main()
