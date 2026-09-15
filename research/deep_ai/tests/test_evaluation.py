from __future__ import annotations

import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from deep_ai.evaluation import evaluate, arena_promotion_passed
from deep_ai.evaluation_protocol import EvaluationProtocol, GameEvidence
from deep_ai.evaluation_statistics import BoundedMeanCS, EvaluationAccumulator
from deep_ai.evaluation_store import EvaluationRunStore, EvaluationRoundCache
from deep_ai.evaluation_fairness import canonical_hash
from deep_ai.v3_contract import RELEASE_DECKS


def protocol(*, mode="screen", rounds=1, decks=("fire", "water"), **kwargs):
    return EvaluationProtocol.create(
        backend="challenge", mode=mode, decks=decks,
        participants={role: {"content_hash": canonical_hash(role)} for role in ("candidate", "champion", "anchor")},
        context={"rules_hash": "rules", "decks_hash": "decks", "time_budget_ms": 0},
        maximum_replicates=rounds, minimum_replicates=5 if mode == "promotion" else 1,
        **kwargs,
    )


def result(task, score=1, **kwargs):
    winner = -1 if score == 1 else task.candidate_seat if score == 2 else 1-task.candidate_seat
    return {**task.to_dict(), "winner_seat": winner, "candidate_score_x2": score,
            "success": True, "terminal": True, "truncated": False, "error": "",
            "decisions": 8, "turns": 3,
            "final_state_hash": canonical_hash([task.conditions(), winner]), **kwargs}


class FakeBackend:
    def __init__(self, scores=None, interrupt_after=None, timeout=False, persistent=False):
        self.scores = scores or {"ac": 1, "ah": 1, "ch": 1}
        self.interrupt_after = interrupt_after
        self.timeout = timeout
        self.persistent = persistent
        self.calls = []
        self.closed = False

    def run(self, tasks, *, on_games, isolated=False):
        for task in tasks:
            self.calls.append((task.task_id, isolated))
            row = result(task, self.scores[task.comparison])
            if self.timeout and (len(self.calls) == 1 or self.persistent and isolated):
                row.update(success=False, terminal=False, error="external_agent_timeout")
            on_games([row])
            if len(self.calls) == self.interrupt_after:
                raise InterruptedError("test interruption")

    def close(self):
        self.closed = True

    def performance(self):
        return {"played_games": len(self.calls), "gating": False}


class EvaluationTests(unittest.TestCase):
    def test_complete_matrix_and_roundtrip(self):
        p = protocol(mode="promotion", rounds=5, decks=RELEASE_DECKS)
        tasks = p.tasks("ac", 0)
        self.assertEqual(len(tasks), 400)
        self.assertEqual(len({t.block_id for t in tasks}), 55)
        seeds = {t.pair: t.game_seed for t in tasks}
        self.assertEqual(len(set(seeds.values())), 55)
        self.assertEqual([t.conditions() for t in tasks], [t.conditions() for t in p.tasks("ah", 0)])
        self.assertEqual(EvaluationProtocol.from_dict(p.to_dict()).fingerprint, p.fingerprint)
        changed = replace(p, participants_json=p.participants_json.replace("candidate", "candidate", 1))
        self.assertEqual([t.conditions() for t in changed.tasks("ac", 0)], [t.conditions() for t in tasks])
        screen = protocol(rounds=5, decks=RELEASE_DECKS)
        self.assertNotEqual(screen.tasks("ac", 0)[0].game_seed, tasks[0].game_seed)

    def test_result_cannot_forge_conditions_or_winner(self):
        p = protocol()
        task = p.tasks("ac", 0)[0]
        for override in ({"first_player": 1-task.first_player}, {"winner_seat": 3},
                         {"candidate_seat": True}, {"terminal": "true"}, {"candidate_score_x2": 0}):
            with self.subTest(override=override), self.assertRaises(ValueError):
                GameEvidence.from_result(p, task, result(task, **override))
        row = GameEvidence.from_result(p, task, result(task)).row
        row["block_size"] = 1
        row["evidence_hash"] = canonical_hash({})
        with self.assertRaises(ValueError):
            GameEvidence.verify(p, task, row)

    def test_same_closure_and_repeated_scenario_are_rejected(self):
        p = protocol(decks=("fire",))
        tasks = p.tasks("ac", 0)
        row = GameEvidence.from_result(p, tasks[0], result(tasks[0])).row
        for task in tasks[1:]:
            with self.assertRaises(ValueError):
                GameEvidence.from_result(p, task, {**row, "task_id": task.task_id})
        acc = EvaluationAccumulator(p)
        acc.add(GameEvidence(row))
        with self.assertRaisesRegex(ValueError, "duplicate_evidence"):
            acc.add(GameEvidence(row))
        with tempfile.TemporaryDirectory() as directory:
            with EvaluationRunStore(Path(directory), p) as store:
                with self.assertRaisesRegex(RuntimeError, "unknown_task"):
                    store.append([{**row, "task_id": "forged", "block_id": "forged"}])

    def test_boundary_keeps_small_and_zero_variance_uncertainty(self):
        cs = BoundedMeanCS({"one": 1.0}, alpha=0.05)
        cs.add_round({"one": 1})
        self.assertEqual(cs.snapshot()["interval"], [0, 1])
        for _ in range(100):
            cs.add_round({"one": 1})
        self.assertLess(cs.lower, 1)
        self.assertGreater(cs.lower, 0.5)
        weighted = BoundedMeanCS({"mirror": 1/3, "cross": 2/3}, alpha=0.05)
        weighted.add_round({"mirror": 0, "cross": 1})
        self.assertAlmostEqual(weighted.snapshot()["estimate"], 2/3)
        with self.assertRaises(ValueError):
            weighted.add_round({"mirror": 1})

    def test_missing_anchor_cannot_promote_even_all_wins(self):
        p = protocol(mode="promotion", rounds=5, decks=RELEASE_DECKS)
        acc = EvaluationAccumulator(p)
        for rep in range(5):
            for task in p.tasks("ac", rep):
                acc.add(GameEvidence.from_result(p, task, result(task, 2)))
        report = acc.report(final=True)
        self.assertEqual(report["strength"]["status"], "improved")
        self.assertEqual(report["gate_status"], "inconclusive")
        self.assertFalse(report["promotion_passed"])

    def test_three_way_promotion_and_deck_regression(self):
        p = protocol(mode="promotion", rounds=10, decks=RELEASE_DECKS)
        for degraded in (False, True):
            acc = EvaluationAccumulator(p)
            for rep in range(10):
                for comp in p.comparisons:
                    for task in p.tasks(comp, rep):
                        score = 0 if comp == "ch" else 2
                        if task.candidate_deck == "fire" and comp != "ac":
                            # A naturally weak deck is unchanged, unless the
                            # treatment loses where its fixed control wins.
                            score = 2 if degraded and comp == "ch" else 0
                        acc.add(GameEvidence.from_result(p, task, result(task, score)))
            report = acc.report(final=True)
            self.assertEqual(report["gate_status"], "fail" if degraded else "pass")
            self.assertEqual(report["per_deck"]["fire"]["status"], "confirmed_regression" if degraded else "inconclusive")

    def test_fault_never_counts_as_a_draw_or_loss(self):
        p = protocol(decks=("fire",))
        acc = EvaluationAccumulator(p)
        for task in p.tasks("ac", 0):
            raw = result(task, 2)
            if task.closure == 1:
                raw.update(success=False, terminal=False, truncated=True)
            row = GameEvidence.from_result(p, task, raw)
            if task.closure == 1:
                self.assertIsNone(row.row["candidate_score_x2"])
            acc.add(row)
        report = acc.report(final=True)
        self.assertEqual(report["record"]["games"], 0)
        self.assertEqual(report["integrity"]["truncated_games"], 1)
        self.assertFalse(report["promotion_passed"])

    def test_resume_does_not_replay_completed_game(self):
        p = protocol(decks=("fire",))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            interrupted = FakeBackend(interrupt_after=1)
            with self.assertRaises(InterruptedError):
                evaluate(p, interrupted, output=root)
            second = FakeBackend()
            resumed = evaluate(p, second, output=root)
            self.assertEqual(len(second.calls), 3)
            self.assertEqual(resumed.summary["gate_status"], "pass")
            self.assertTrue(second.closed)
            with self.assertRaises((ValueError,RuntimeError)):
                with EvaluationRunStore(root, replace(p, max_decisions=100)):
                    pass

    def test_isolated_retry_is_strength_neutral_and_audited(self):
        p = protocol(decks=("fire",))
        for persistent in (False, True):
            with tempfile.TemporaryDirectory() as directory:
                backend = FakeBackend(timeout=True, persistent=persistent)
                report = evaluate(p, backend, output=Path(directory))
                self.assertEqual(len(backend.calls), 5)
                self.assertTrue(backend.calls[-1][1])
                self.assertEqual(report.summary["gate_status"], "fail" if persistent else "pass")
                attempts = (Path(directory)/"arena-attempts.jsonl").read_text().splitlines()
                self.assertEqual(len(attempts), 2)

    def test_resume_finalizes_recorded_retry_without_replaying_it(self):
        p=protocol(decks=("fire",))
        append=EvaluationRunStore.append
        def interrupted(store, rows):
            if any(r.get("attempt_count")==2 for r in rows):
                raise InterruptedError("after durable retry, before final shard")
            return append(store,rows)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            with patch.object(EvaluationRunStore,"append",interrupted), self.assertRaises(InterruptedError):
                evaluate(p,FakeBackend(timeout=True),output=root)
            backend=FakeBackend()
            report=evaluate(p,backend,output=root)
            self.assertFalse(backend.calls)
            self.assertEqual(report.summary["record"]["draws"],4)
            self.assertEqual(report.summary["reliability"]["recovered_timeout_games"],1)

    def test_cache_and_shard_corruption_fail_closed(self):
        p = protocol(decks=("fire",))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = EvaluationRoundCache(root/"cache")
            rows = [GameEvidence.from_result(p,t,result(t)).row for t in p.tasks("ac",0)]
            cache.write(p,"ac",0,rows)
            self.assertEqual(len(cache.read(p,"ac",0)),4)
            path = next((root/"cache").rglob("*.json"))
            payload = json.loads(path.read_text()); payload["rows"][0]["winner_seat"]=0
            path.write_text(json.dumps(payload))
            with self.assertRaises(ValueError): cache.read(p,"ac",0)
            evaluate(p,FakeBackend(),output=root/"run")
            shard = next((root/"run"/"shards").glob("*.jsonl"))
            shard.write_text("{}\n")
            with self.assertRaises(RuntimeError): EvaluationRunStore(root/"run",p)

    def test_cache_reuses_only_same_conditions_and_content(self):
        p = protocol(decks=("fire",))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evaluate(p,FakeBackend(),output=root/"first",cache_root=root/"cache")
            backend = FakeBackend()
            report = evaluate(p,backend,output=root/"second",cache_root=root/"cache")
            self.assertFalse(backend.calls)
            self.assertEqual(report.summary["performance_advisory"]["cached_games"],4)
            with self.assertRaises(ValueError):
                GameEvidence.verify(replace(p,seed=18), p.tasks("ac",0)[0], report.games[0])

    def test_old_report_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); original='{"schema":"legacy","score_rate":1}'
            (root/"arena-summary.json").write_text(original)
            with self.assertRaisesRegex(ValueError,"output_protocol_missing"):
                EvaluationRunStore(root,protocol())
            self.assertEqual((root/"arena-summary.json").read_text(),original)

    def test_legacy_gate_and_mismatched_weights_cannot_promote(self):
        self.assertFalse(arena_promotion_passed({"score_rate":1,"failed_games":0}))
        from deep_ai.evaluation_protocol import REPORT_SCHEMA
        report = {"schema":REPORT_SCHEMA,"mode":"promotion","gate_status":"pass",
                  "promotion_passed":True,"reliability":{"passed":True},"protocol_fingerprint":"p",
                  "evidence":{"candidate_content_hash":"a","protocol_fingerprint":"p",
                              "finalized":True,"games_sha256":"0"*64}}
        self.assertTrue(arena_promotion_passed(report,candidate_content_hash="a"))
        self.assertFalse(arena_promotion_passed(report,candidate_content_hash="b"))
        report["evidence"]["finalized"]=False
        self.assertFalse(arena_promotion_passed(report,candidate_content_hash="a"))

    def test_missing_backend_result_is_an_infrastructure_failure(self):
        class Missing(FakeBackend):
            def run(self,tasks,*,on_games,isolated=False):
                pass
        with tempfile.TemporaryDirectory() as directory:
            report=evaluate(protocol(decks=("fire",)),Missing(),output=Path(directory))
            self.assertEqual(report.summary["gate_status"],"infrastructure_fail")
            self.assertFalse(report.summary["promotion_passed"])

    def test_shutdown_failure_is_recorded_before_sealing_report(self):
        class BrokenClose(FakeBackend):
            def close(self):
                raise RuntimeError("failed shutdown")
        with tempfile.TemporaryDirectory() as directory:
            report=evaluate(protocol(decks=("fire",)),BrokenClose(),output=Path(directory))
            self.assertEqual(report.summary["gate_status"],"infrastructure_fail")
            manifest=json.loads((Path(directory)/"arena-manifest.json").read_text())
            self.assertEqual(manifest["gate_status"],"infrastructure_fail")


if __name__ == "__main__":
    unittest.main()
