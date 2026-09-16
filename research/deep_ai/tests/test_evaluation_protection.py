from __future__ import annotations

import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from deep_ai.evaluation import evaluate
from deep_ai.evaluation_protection import protect_anchor_scores
from deep_ai.evaluation_fairness import canonical_hash, rules_content_hash
from tests.test_evaluation import FakeBackend, protocol


class StrategyProtectionTests(unittest.TestCase):
    def paired(self, **changes):
        p = protocol(deck_margin=0, **changes)
        return replace(p, context_json=json.dumps({**p.context, "paired_anchor_screen": True}))

    def test_protects_stronger_historical_side_even_if_previous_screen_failed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            p = self.paired()
            evaluate(p, FakeBackend(scores={"ac": 2, "ah": 1, "ch": 2}), output=root / "prior")
            for score in (1, 2):
                output = root / str(score)
                evaluate(p, FakeBackend(scores={"ac": 2, "ah": score, "ch": 1}), output=output)
                report = protect_anchor_scores(output, [root / "prior"])
                self.assertEqual(report["gate_status"], "pass" if score == 2 else "fail")
                self.assertTrue(all(row["protected_score_rate"] == 1 for row in report["per_deck"].values()))
                self.assertFalse(report["promotion_passed"])

    def test_rejects_another_seed_cohort_and_modified_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, seed in (("current", 17), ("prior", 18)):
                evaluate(self.paired(seed=seed), FakeBackend(), output=root / name)
            with self.assertRaisesRegex(ValueError, "scenario_mismatch"):
                protect_anchor_scores(root / "current", [root / "prior"])
            with (root / "prior/arena-games.jsonl").open("a", encoding="utf-8") as stream:
                stream.write("\n")
            with self.assertRaisesRegex(ValueError, "evidence_hash_mismatch"):
                protect_anchor_scores(root / "current", [root / "prior"])

    def test_rejects_changed_anchor_and_search_work(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            p = self.paired()
            evaluate(p, FakeBackend(), output=root / "prior")
            for key in ("anchor", "candidate"):
                participants = p.participants
                participants[key]["options"] = {"node_budget": 193}
                changed = replace(p, participants_json=json.dumps(participants))
                evaluate(changed, FakeBackend(), output=root / key)
                with self.assertRaisesRegex(ValueError, "anchor_or_rules_mismatch" if key == "anchor" else "search_contract_mismatch"):
                    protect_anchor_scores(root / key, [root / "prior"])

    def test_bundle_metadata_change_requires_matching_sealed_rule_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            p = self.paired()
            for name, hp in (("prior", 100), ("current", 100), ("changed", 110)):
                catalog = {"cards": {"test": {"hp": hp}}, "card_ir": {
                    "cards": {"test": {"cost": ["Psychic"]}}, "content_fingerprint": name}}
                digest = canonical_hash(catalog)
                context = {**p.context, "rules_hash": digest}
                if name != "prior":
                    context.update(rules_hash=rules_content_hash(catalog),
                                   rules_hash_schema="card_semantics_v1", catalog_bundle_hash=digest)
                actual = replace(p, context_json=json.dumps(context))
                evaluate(actual, FakeBackend(), output=root / name)
                inputs = root / name / "runtime/candidate/.inputs"
                inputs.mkdir(parents=True)
                (inputs / f"catalog-{digest}.json").write_text(json.dumps(catalog), encoding="utf-8")
            self.assertEqual(protect_anchor_scores(root / "current", [root / "prior"])["gate_status"], "pass")
            with self.assertRaisesRegex(ValueError, "anchor_or_rules_mismatch"):
                protect_anchor_scores(root / "changed", [root / "prior"])
            path = next((root / "prior/runtime/candidate/.inputs").glob("catalog-*.json"))
            path.write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "rules_evidence_hash_mismatch"):
                protect_anchor_scores(root / "current", [root / "prior"])


if __name__ == "__main__":
    unittest.main()
