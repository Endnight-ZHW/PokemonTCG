import copy
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from scripts.ai_evaluation_v7 import PROTOCOL_ID, SCHEMA_VERSION
from scripts.build_ai_evaluation_provenance import build_provenance
from scripts.inspect_ai_evaluation_checkpoints import (
    checkpoint_matches_sha256,
    inspect_checkpoint_root,
)


SIMULATION_FINGERPRINT = "a" * 64
TASK_MANIFEST_ID = "b" * 64
SHARD_COUNT = 50
MIRROR_UNIT_ID = "mirror|colorless|0|17"
CROSS_UNIT_ID = "cross|colorless|darkness|0|50097426"


def _clean_row(
    *,
    matchup_kind: str,
    deck_a: str,
    deck_b: str,
    seed_block: int,
    seed: int,
    seat: int,
    winner: str,
) -> dict:
    return {
        "matchup_kind": matchup_kind,
        "strategy_a_deck": deck_a,
        "strategy_b_deck": deck_b,
        "seed_block": seed_block,
        "seed": seed,
        "seat": seat,
        "terminal_reason": "game_over",
        "invalid_actions": 0,
        "choice_failures": 0,
        "rule_exceptions": 0,
        "max_actions_exhausted": False,
        "winner": winner,
    }


def _mirror_rows() -> list[dict]:
    return [
        _clean_row(
            matchup_kind="mirror",
            deck_a="colorless",
            deck_b="colorless",
            seed_block=0,
            seed=17,
            seat=0,
            winner="A",
        ),
        _clean_row(
            matchup_kind="mirror",
            deck_a="colorless",
            deck_b="colorless",
            seed_block=0,
            seed=17,
            seat=1,
            winner="B",
        ),
    ]


def _cross_rows() -> list[dict]:
    rows: list[dict] = []
    for deck_a, deck_b in (
        ("colorless", "darkness"),
        ("darkness", "colorless"),
    ):
        for seat in (0, 1):
            rows.append(_clean_row(
                matchup_kind="cross",
                deck_a=deck_a,
                deck_b=deck_b,
                seed_block=0,
                seed=50_097_426,
                seat=seat,
                winner="draw",
            ))
    return rows


def _record(
    unit_id: str = MIRROR_UNIT_ID,
    rows: list[dict] | None = None,
    *,
    shard_index: int = 0,
) -> dict:
    frozen_rows = copy.deepcopy(rows if rows is not None else _mirror_rows())
    return {
        "schema_version": SCHEMA_VERSION,
        "protocol_id": PROTOCOL_ID,
        "artifact_kind": "ai_evaluation_checkpoint_unit",
        "simulation_fingerprint": SIMULATION_FINGERPRINT,
        "task_manifest_id": TASK_MANIFEST_ID,
        "evidence_shard_index": shard_index,
        "evidence_shard_count": SHARD_COUNT,
        "unit_id": unit_id,
        "expected_games": 4 if unit_id.startswith("cross|") else 2,
        "matches_sha256": checkpoint_matches_sha256(frozen_rows),
        "matches": frozen_rows,
    }


class CheckpointInspectorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def _case_root(self, name: str) -> Path:
        root = self.root / name
        root.mkdir(parents=True)
        return root

    @staticmethod
    def _write_record(
        root: Path,
        record: dict,
        *,
        shard_index: int = 0,
        name: str = "record.json",
    ) -> Path:
        directory = root / f"shard-{shard_index:03d}"
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / name
        path.write_text(
            json.dumps(record, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        return path

    @staticmethod
    def _inspect(root: Path) -> dict:
        result = inspect_checkpoint_root(
            root,
            simulation_fingerprint=SIMULATION_FINGERPRINT,
            task_manifest_id=TASK_MANIFEST_ID,
            shard_count=SHARD_COUNT,
        )
        if not isinstance(result, dict):
            raise AssertionError("checkpoint inspection result must be an object")
        for key in (
            "valid_unit_ids_by_shard",
            "diagnostics",
            "conflicting_unit_ids_by_shard",
        ):
            if key not in result:
                raise AssertionError(f"checkpoint inspection omitted {key}")
        return result

    @staticmethod
    def _valid_units(result: dict, shard_index: int = 0) -> list[str]:
        return list(
            result["valid_unit_ids_by_shard"].get(str(shard_index), [])
        )

    @staticmethod
    def _conflicting_units(
        result: dict,
        shard_index: int = 0,
    ) -> list[str]:
        return list(
            result["conflicting_unit_ids_by_shard"].get(
                str(shard_index),
                [],
            )
        )

    def test_hash_matches_godot_canonical_normalization(self):
        rows = _mirror_rows()
        self.assertEqual(
            checkpoint_matches_sha256(rows),
            "eb41357deb9298e231ea38a981c23286"
            "868d7a685418f2c4aaacb4c519735235",
        )

        reordered = [
            dict(reversed(list(row.items())))
            for row in rows
        ]
        reordered[0]["seed"] = 17.0
        self.assertEqual(
            checkpoint_matches_sha256(reordered),
            checkpoint_matches_sha256(rows),
        )

    def test_valid_mirror_and_cross_records_are_reported_by_content(self):
        root = self._case_root("valid")
        self._write_record(
            root,
            _record(),
            name="arbitrary-mirror-name.json",
        )
        self._write_record(
            root,
            _record(CROSS_UNIT_ID, _cross_rows()),
            name="arbitrary-cross-name.json",
        )

        result = self._inspect(root)

        self.assertEqual(
            set(self._valid_units(result)),
            {MIRROR_UNIT_ID, CROSS_UNIT_ID},
        )
        self.assertEqual(self._conflicting_units(result), [])

    def test_corrupt_json_and_non_object_json_are_missing(self):
        for label, text in (
            ("syntax", "{this is not valid JSON"),
            ("top_level", "[]"),
        ):
            with self.subTest(label=label):
                root = self._case_root(f"corrupt-{label}")
                directory = root / "shard-000"
                directory.mkdir()
                (directory / "broken.json").write_text(
                    text,
                    encoding="utf-8",
                )

                result = self._inspect(root)

                self.assertEqual(self._valid_units(result), [])
                self.assertTrue(result["diagnostics"])

    def test_wrong_run_and_shard_identity_are_missing(self):
        mutations = {
            "schema_version": ("schema_version", SCHEMA_VERSION - 1),
            "protocol_id": ("protocol_id", "traditional_ai_evaluation_v6"),
            "artifact_kind": ("artifact_kind", "ai_evaluation_result"),
            "simulation_fingerprint": (
                "simulation_fingerprint",
                "c" * 64,
            ),
            "task_manifest": ("task_manifest_id", "d" * 64),
            "shard_index": ("evidence_shard_index", 1),
            "shard_count": ("evidence_shard_count", SHARD_COUNT - 1),
        }
        for label, (field, value) in mutations.items():
            with self.subTest(label=label):
                root = self._case_root(f"identity-{label}")
                record = _record()
                record[field] = value
                self._write_record(root, record)

                result = self._inspect(root)

                self.assertEqual(self._valid_units(result), [])
                self.assertTrue(result["diagnostics"])

    def test_wrong_unit_row_identity_and_game_counts_are_missing(self):
        cases: dict[str, dict] = {}

        wrong_unit = _record()
        wrong_unit["unit_id"] = "mirror|fire|0|17"
        cases["record_unit"] = wrong_unit

        wrong_row = _record()
        wrong_row["matches"][1]["strategy_a_deck"] = "fire"
        wrong_row["matches_sha256"] = checkpoint_matches_sha256(
            wrong_row["matches"]
        )
        cases["row_unit"] = wrong_row

        truncated = _record()
        truncated["matches"] = truncated["matches"][:1]
        truncated["matches_sha256"] = checkpoint_matches_sha256(
            truncated["matches"]
        )
        cases["match_count"] = truncated

        for label, record in cases.items():
            with self.subTest(label=label):
                root = self._case_root(f"unit-{label}")
                self._write_record(root, record)

                result = self._inspect(root)

                self.assertEqual(self._valid_units(result), [])
                self.assertTrue(result["diagnostics"])

    def test_expected_games_remains_advisory(self):
        advisory_game_count = _record()
        advisory_game_count["expected_games"] = 4
        root = self._case_root("godot-parity-advisory")
        self._write_record(root, advisory_game_count)

        result = self._inspect(root)

        self.assertEqual(self._valid_units(result), [MIRROR_UNIT_ID])
        self.assertEqual(self._conflicting_units(result), [])

    def test_unit_requires_exact_unique_seats_and_cross_directions(self):
        cases: dict[str, dict] = {}

        duplicate_mirror_seat = _record()
        duplicate_mirror_seat["matches"][1]["seat"] = 0
        duplicate_mirror_seat["matches_sha256"] = checkpoint_matches_sha256(
            duplicate_mirror_seat["matches"]
        )
        cases["duplicate_mirror_seat"] = duplicate_mirror_seat

        missing_cross_direction = _record(CROSS_UNIT_ID, _cross_rows())
        for row in missing_cross_direction["matches"]:
            row["strategy_a_deck"] = "colorless"
            row["strategy_b_deck"] = "darkness"
        missing_cross_direction["matches_sha256"] = (
            checkpoint_matches_sha256(missing_cross_direction["matches"])
        )
        cases["missing_cross_direction"] = missing_cross_direction

        duplicate_cross_seat = _record(CROSS_UNIT_ID, _cross_rows())
        duplicate_cross_seat["matches"][1]["seat"] = 0
        duplicate_cross_seat["matches_sha256"] = checkpoint_matches_sha256(
            duplicate_cross_seat["matches"]
        )
        cases["duplicate_cross_seat"] = duplicate_cross_seat

        for label, record in cases.items():
            with self.subTest(label=label):
                root = self._case_root(f"exact-identity-{label}")
                self._write_record(root, record)

                result = self._inspect(root)

                self.assertEqual(self._valid_units(result), [])
                self.assertEqual(
                    result["diagnostics"]["invalid_records_by_reason"],
                    {"match_identity_set": 1},
                )

    def test_each_fatal_match_condition_is_missing_even_with_valid_hash(self):
        mutations = {
            "terminal_reason": ("terminal_reason", "action_cap"),
            "invalid_actions": ("invalid_actions", 1),
            "choice_failures": ("choice_failures", 1),
            "rule_exceptions": ("rule_exceptions", 1),
            "max_actions_exhausted": ("max_actions_exhausted", True),
        }
        for label, (field, value) in mutations.items():
            with self.subTest(label=label):
                root = self._case_root(f"fatal-{label}")
                record = _record()
                record["matches"][0][field] = value
                record["matches_sha256"] = checkpoint_matches_sha256(
                    record["matches"]
                )
                self._write_record(root, record)

                result = self._inspect(root)

                self.assertEqual(self._valid_units(result), [])
                self.assertTrue(result["diagnostics"])

    def test_tampered_matches_hash_is_missing(self):
        root = self._case_root("tampered-hash")
        record = _record()
        record["matches_sha256"] = "0" * 64
        self._write_record(root, record)

        result = self._inspect(root)

        self.assertEqual(self._valid_units(result), [])
        self.assertTrue(result["diagnostics"])

    def test_identical_duplicate_is_idempotently_valid(self):
        root = self._case_root("same-duplicate")
        record = _record()
        self._write_record(root, record, name="first.json")
        self._write_record(root, copy.deepcopy(record), name="second.json")

        result = self._inspect(root)

        self.assertEqual(self._valid_units(result), [MIRROR_UNIT_ID])
        self.assertEqual(self._conflicting_units(result), [])

    def test_conflicting_duplicate_is_treated_as_missing(self):
        root = self._case_root("conflicting-duplicate")
        first = _record()
        second = _record()
        second["matches"][0]["winner"] = "B"
        second["matches_sha256"] = checkpoint_matches_sha256(
            second["matches"]
        )
        self.assertNotEqual(
            first["matches_sha256"],
            second["matches_sha256"],
        )
        self._write_record(root, first, name="first.json")
        self._write_record(root, second, name="second.json")

        result = self._inspect(root)

        self.assertEqual(self._valid_units(result), [])
        self.assertIn(MIRROR_UNIT_ID, self._conflicting_units(result))
        self.assertTrue(result["diagnostics"])

    def test_invalid_duplicate_does_not_poison_a_valid_record(self):
        root = self._case_root("invalid-and-valid")
        valid = _record()
        invalid = copy.deepcopy(valid)
        invalid["matches_sha256"] = "0" * 64
        self._write_record(root, invalid, name="invalid.json")
        self._write_record(root, valid, name="valid.json")

        result = self._inspect(root)

        self.assertEqual(self._valid_units(result), [MIRROR_UNIT_ID])
        self.assertEqual(self._conflicting_units(result), [])
        self.assertTrue(result["diagnostics"])


class CheckpointInspectorPowerShellContractTests(unittest.TestCase):
    def test_lpt_checkpoint_presence_uses_inspected_content(self):
        script_path = (
            Path(__file__).resolve().parents[2]
            / "tools"
            / "evaluate_godot_ai.ps1"
        )
        script = script_path.read_text(encoding="utf-8-sig")

        self.assertEqual(
            script.count("inspect_ai_evaluation_checkpoints.py"),
            1,
        )
        self.assertIn("valid_unit_ids_by_shard", script)
        self.assertNotIn('"$unitHash-*.json"', script)
        self.assertIsNone(re.search(
            r"Get-ChildItem[\s\S]{0,500}\$unitHash-\*\.json",
            script,
        ))

    def test_wall_clock_scope_distinguishes_prior_attempt_checkpoints(self):
        script_path = (
            Path(__file__).resolve().parents[2]
            / "tools"
            / "evaluate_godot_ai.ps1"
        )
        script = script_path.read_text(encoding="utf-8-sig")

        detection = script.index("$hadCheckpointFilesAtEvidenceStart")
        stopwatch = script.index(
            "$evidenceStopwatch = "
            "[System.Diagnostics.Stopwatch]::StartNew()"
        )
        self.assertLess(detection, stopwatch)
        self.assertIn("'current_attempt_only'", script[detection:stopwatch])
        self.assertIn("'full_evidence_stage'", script[detection:stopwatch])
        self.assertIn("'--wall-clock-scope'", script)
        self.assertIn("-WallClockScope $evidenceWallClockScope", script)


class CheckpointInspectorProvenanceTests(unittest.TestCase):
    def test_inspector_is_bound_to_simulation_provenance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inspector = (
                root
                / "python"
                / "scripts"
                / "inspect_ai_evaluation_checkpoints.py"
            )
            inspector.parent.mkdir(parents=True)
            inspector.write_text("# inspector v1\n", encoding="utf-8")

            before = build_provenance(root, [], target_platform="windows")
            inspector.write_text("# inspector v2\n", encoding="utf-8")
            after = build_provenance(root, [], target_platform="windows")

            self.assertNotEqual(
                before["simulation_fingerprint"],
                after["simulation_fingerprint"],
            )
            self.assertEqual(
                before["analysis_fingerprint"],
                after["analysis_fingerprint"],
            )
            self.assertNotEqual(
                before["component_hashes"]["evaluation_tool"],
                after["component_hashes"]["evaluation_tool"],
            )


if __name__ == "__main__":
    unittest.main()
