from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from deep_ai.challenge_arena import ArenaAgentSpec, NativeChallengeArena, load_product_payloads
from deep_ai.actor_v3 import ActorConfigV3, NativeActorServiceV3, GameTaskV3
from deep_ai.model_v3 import TORCH_AVAILABLE, create_model
from deep_ai.evaluation_deep import DeepEvaluationBackend, deep_game_result, load_or_freeze_anchor, model_content_hash, run_deep_evaluation
from deep_ai.evaluation_protocol import GameEvidence
from deep_ai.trainer_v3 import AlphaZeroV3Config, AlphaZeroV3Trainer
from tests.test_evaluation import protocol

try:
    import ptcg_ai_core
except ImportError:
    ptcg_ai_core = None


class ActorWatchdogTests(unittest.TestCase):
    def test_watchdog_closes_inference_before_joining_and_returns_neutral_attempts(self):
        operations=[]
        service=object.__new__(NativeActorServiceV3)
        service.control=None
        service.config=ActorConfigV3(training=False,strict=False,progress_timeout_ms=1)
        service.pool=SimpleNamespace(start=lambda rows:None,wait_for=lambda timeout:False,
            drain_games=lambda:[],cancel=lambda:operations.append("cancel"),
            wait=lambda:operations.append("join"),metrics=lambda:{})
        service.batch=SimpleNamespace(close=lambda:operations.append("close_inference"),drain_samples=lambda:{})
        service.broker=SimpleNamespace(request_count=0,metrics={})
        p=protocol(decks=("fire",))
        tasks=[GameTaskV3(t.task_id,0,t.candidate_deck,t.baseline_deck,t.game_seed,
                         t.candidate_seat,t.first_player,(0,1),(0,0),t.max_decisions) for t in p.tasks("ac",0)]
        streamed=[]
        with patch("deep_ai.actor_v3.time.monotonic",side_effect=[0.0,1.0]):
            report=service.run(tasks,on_games=streamed.extend)
        self.assertEqual(operations,["close_inference","cancel","join"])
        self.assertEqual(report["structural_errors"],0)
        self.assertEqual(len(streamed),4)
        for task,row in zip(p.tasks("ac",0),streamed):
            evidence=GameEvidence.from_result(p,task,deep_game_result(row)).row
            self.assertEqual(evidence["failure_kind"],"timeout")
            self.assertIsNone(evidence["candidate_score_x2"])


@unittest.skipUnless(ptcg_ai_core is not None,"native binding required")
class EvaluationNativeTests(unittest.TestCase):
    def test_immediate_cancel_wakes_waiters_before_workers_initialize(self):
        catalog,decks,strategies=load_product_payloads()
        agent=ArenaAgentSpec("test","test",strategies,{"engine":"strategic_intent_v3"})
        pool=ptcg_ai_core.NativeChallengeArenaPool(catalog,decks,agent.native_payload(),agent.native_payload(),
                                                  {"concurrent_games":4,"deterministic":True,"inner_search_workers":1})
        pool.start([{"task_id": t.task_id, **t.conditions()} for t in protocol(max_decisions=1).tasks("ac",0)])
        pool.cancel()
        self.assertTrue(pool.wait_for(2000))
        pool.wait()

    def test_native_workers_reused_and_game_state_reset(self):
        catalog,decks,strategies=load_product_payloads()
        options={"engine":"strategic_intent_v3","node_budget":8,"belief_samples":1,
                 "internal_evaluation_smoke":True}
        a=ArenaAgentSpec("left","test",strategies,options)
        b=ArenaAgentSpec("right","test",strategies,options)
        tasks=protocol(decks=("fire",),max_decisions=12).tasks("ac",0)
        with NativeChallengeArena(catalog,decks,a,b,workers=1) as arena:
            first=arena.run(tasks)
            repeated=arena.run(tasks)
            self.assertEqual(arena.pool_starts,1)
        with NativeChallengeArena(catalog,decks,a,b,workers=4) as arena:
            parallel=arena.run(list(reversed(tasks)))
        def hashes(output):
            return {r["task_id"]:r["semantic_result_hash"] for r in output["games"]}
        self.assertEqual(hashes(first),hashes(repeated))
        self.assertEqual(hashes(first),hashes(parallel))

    @unittest.skipUnless(TORCH_AVAILABLE,"Torch required")
    def test_deep_streaming_reuse_and_parallel_determinism(self):
        import torch
        p=protocol(decks=("fire",),max_decisions=32)
        model=create_model(model_dim=32,layers=1,heads=4,ffn_dim=64).eval()
        original=model_content_hash(model)
        models={role:model for role in ("candidate","champion","anchor")}
        for device in (("cpu","cuda") if torch.cuda.is_available() else ("cpu",)):
            signatures=[]
            for workers in (1,2):
                backend=DeepEvaluationBackend(models=models,device=device,
                    config=ActorConfigV3(concurrent_games=workers,search_slots=workers,simulations=2,max_depth=2))
                try:
                    for repeat in range(2):
                        rows=[]
                        backend.run(p.tasks("ac",0),on_games=rows.extend)
                        self.assertEqual(len(rows),4)
                        evidence=[GameEvidence.from_result(p,t,next(r for r in rows if r["task_id"]==t.task_id)).row
                                  for t in p.tasks("ac",0)]
                        signatures.append({r["task_id"]:r["evidence_hash"] for r in evidence})
                    self.assertEqual(backend.starts,1)
                    self.assertGreater(backend.last_metrics["inference_requests"],0)
                finally:
                    backend.close()
            self.assertTrue(all(value==signatures[0] for value in signatures),device)
        self.assertEqual(model_content_hash(model),original)


@unittest.skipUnless(TORCH_AVAILABLE,"Torch required")
class EvaluationCheckpointTests(unittest.TestCase):
    @unittest.skipUnless(ptcg_ai_core is not None,"native binding required")
    def test_shared_deep_run_seals_evidence_and_keeps_campaign_budget(self):
        model=create_model(model_dim=32,layers=1,heads=4,ffn_dim=64).eval()
        with tempfile.TemporaryDirectory() as directory:
            arguments=dict(candidate=model,champion=model,anchor=model,
                config=ActorConfigV3(concurrent_games=1,search_slots=1,simulations=2),device="cpu",
                output=Path(directory)/"cycle",seed=17,cycle=1,maximum_candidates=1,
                maximum_replicates=1,max_decisions=1,mode="screen",decks=("fire",))
            report=run_deep_evaluation(**arguments)
            self.assertTrue(report["evidence"]["finalized"])
            self.assertEqual(len(report["evidence"]["games_sha256"]),64)
            self.assertEqual(report["integrity"]["truncated_games"],4)
            self.assertFalse(report["promotion_passed"])
            with self.assertRaisesRegex(ValueError,"campaign_changed"):
                run_deep_evaluation(**{**arguments,"maximum_candidates":2})

    def test_anchor_is_immutable_and_loading_does_not_consume_rng(self):
        import torch
        model=create_model(model_dim=32,layers=1,heads=4,ffn_dim=64).eval()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            anchor=load_or_freeze_anchor(root,model,0)
            before=torch.get_rng_state().clone()
            changed=copy.deepcopy(model)
            with torch.no_grad(): next(changed.parameters()).add_(1)
            loaded=load_or_freeze_anchor(root,changed,1)
            self.assertEqual(model_content_hash(anchor),model_content_hash(loaded))
            self.assertTrue(torch.equal(before,torch.get_rng_state()))
            weights=root/"model.safetensors"
            weights.write_bytes(weights.read_bytes()+b"corrupt")
            with self.assertRaises(ValueError): load_or_freeze_anchor(root,model,0)

    def test_pending_evaluation_resumes_the_same_cycle_without_training(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            trainer=object.__new__(AlphaZeroV3Trainer)
            trainer.config=AlphaZeroV3Config(output_dir=directory,cycles=1)
            trainer.output_dir=root
            trainer.state_path=root/"training.json"
            trainer.warmup_path=root/"warmup.json"
            trainer.pilot_path=root/"pilot.json"
            trainer.champion_root=root/"champion"
            trainer.champion_root.mkdir(); (trainer.champion_root/"state.json").write_text("{}")
            checkpoint=root/"checkpoint"; checkpoint.mkdir()
            pending={"cycle":1,"evaluation_pending":True,"generated":{"written_samples":64},
                     "training":{"normalized_policy_entropy":.5},"teacher_validation":None}
            (checkpoint/"state.json").write_text(json.dumps({"cycle_record":pending}))
            latest=root/"latest.json"; latest.write_text("{}")
            trainer.learner=SimpleNamespace(latest_path=latest,cycle=1,global_step=2,
                load_latest=lambda:checkpoint,save_checkpoint=Mock(return_value=root/"final"))
            trainer.previous_rows=[]; trainer.warmup_evidence={"passed":True}; trainer.pending_evaluation=None
            trainer._load_champion=lambda:(object(),0)
            trainer._event=lambda *a,**k:None
            self.assertEqual(trainer._load_or_initialize(),1)
            self.assertEqual(trainer.pending_evaluation,pending)
            trainer._repair_resumed_teacher_gate=lambda:None
            trainer._generate_cycle=Mock(side_effect=AssertionError("must not generate again"))
            trainer._candidate_content_hash=lambda:"candidate"
            trainer.control=SimpleNamespace(status=lambda *a:None,checkpoint=lambda:None)
            trainer.replay=SimpleNamespace(verify=lambda:{})
            trainer._arena=lambda cycle:{"gate_status":"infrastructure_fail"}
            with self.assertRaisesRegex(RuntimeError,"evaluation_infrastructure_failed"):
                trainer.run()
            self.assertIsNotNone(trainer.pending_evaluation)
            trainer._arena=lambda cycle:{"integrity":{"structural_errors":0},"gate_status":"inconclusive"}
            summary=trainer.run()
            self.assertFalse(trainer._generate_cycle.called)
            self.assertEqual(len(summary["cycles"]),1)
            self.assertFalse(summary["cycles"][0]["accepted"])
            self.assertTrue(trainer.learner.save_checkpoint.call_args.kwargs["allow_revision"])


if __name__=="__main__": unittest.main()
