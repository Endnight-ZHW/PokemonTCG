from __future__ import annotations

import copy
import json
import random
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "python"))

try:
    import ptcg_ai_core
except ImportError:  # pragma: no cover - native build is a separate gate
    ptcg_ai_core = None

from engine.native_rules_session import replay_match_journal


def _load_json(relative: str):
    return json.loads(
        (REPO_ROOT / relative).read_text(encoding="utf-8")
    )


def _expanded_deck(spec: dict) -> list[str]:
    return [
        str(row["card_id"])
        for row in spec["cards"]
        for _ in range(int(row["count"]))
    ]


@unittest.skipIf(ptcg_ai_core is None, "native rules binding is unavailable")
class NativeRulesSessionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cards = _load_json("godot/data/cards.json")
        cls.card_ir = _load_json("godot/data/card_ir_v3.json")
        specs = _load_json("godot/data/decks.json")
        cls.all_decks = {
            key: _expanded_deck(spec)
            for key, spec in specs.items()
        }
        cls.decks = [
            cls.all_decks["fire"],
            cls.all_decks["water"],
        ]

    def _created(self, *, seed: int = 12345, forced_first: int = 0):
        session = ptcg_ai_core.NativeRulesSession()
        result = session.create(
            self.cards,
            self.decks,
            {
                "forced_first": forced_first,
                "public_deck_keys": ["fire", "water"],
            },
            seed,
        )
        self.assertTrue(result["success"], result)
        return session, result

    @staticmethod
    def _bind_first_group(query: dict, action_id: str) -> dict:
        group = query["groups"][0]
        targets = list(group["targets"])
        return {
            "schema_version": 4,
            "action_id": action_id,
            "base_revision": int(query["base_revision"]),
            "actor": int(group["actor"]),
            "kind": str(group["kind"]),
            "source": group["source"],
            "target": targets[0] if targets else None,
            "payload": dict(group["payload"]),
        }

    def test_contract_and_forced_setup_are_deterministic(self):
        first, first_result = self._created()
        second, second_result = self._created()

        contract = first.get_contract()
        self.assertEqual(ptcg_ai_core.abi_version(), 2)
        self.assertEqual(contract["native_abi_version"], 2)
        self.assertEqual(contract["protocol_version"], 6)
        self.assertEqual(contract["action_schema_version"], 4)
        self.assertEqual(contract["choice_view_schema_version"], 2)
        self.assertEqual(contract["snapshot_schema_version"], 3)
        self.assertEqual(contract["vm_ir_version"], 3)
        self.assertEqual(contract["card_count"], 137)
        self.assertEqual(contract["framework_dependencies"], [])

        self.assertEqual(first_result["state"], second_result["state"])
        self.assertEqual(first.rng_state, second.rng_state)
        self.assertEqual(first.state_hash, second.state_hash)
        self.assertEqual(first.journal(), second.journal())

        ir_session = ptcg_ai_core.NativeRulesSession()
        ir_result = ir_session.create(
            {"cards": self.cards, "card_ir": self.card_ir},
            self.decks,
            {"forced_first": 0},
            12345,
        )
        self.assertTrue(ir_result["success"], ir_result)
        self.assertEqual(
            ir_session.get_contract()["card_ir_content_fingerprint"],
            self.card_ir["content_fingerprint"],
        )
        self.assertEqual(
            ir_session.get_contract()["card_ir_contract_fingerprint"],
            self.card_ir["contract_fingerprint"],
        )
        self.assertEqual(
            ir_session.journal()["vm_descriptor_digest"],
            self.card_ir["descriptor_digest"],
        )
        self.assertEqual(
            ir_session.journal()["content_fingerprint"],
            self.card_ir["content_fingerprint"],
        )
        self.assertEqual(
            ir_session.journal()["contract_fingerprint"],
            self.card_ir["contract_fingerprint"],
        )
        ir_replay = replay_match_journal(
            ir_session.journal(),
            catalog={"cards": self.cards, "card_ir": self.card_ir},
            decks=self.decks,
        )
        self.assertTrue(ir_replay.success, ir_replay)
        wrong_catalog_replay = replay_match_journal(
            ir_session.journal(),
            catalog=self.cards,
            decks=self.decks,
        )
        self.assertFalse(wrong_catalog_replay.success)
        self.assertIn(
            wrong_catalog_replay.error_code,
            {
                "journal_catalog_fingerprint_mismatch",
                "journal_content_fingerprint_mismatch",
                "journal_input_mismatch",
            },
        )
        invalid_ir = copy.deepcopy(self.card_ir)
        invalid_ir["content_fingerprint"] = "invalid"
        rejected = ptcg_ai_core.NativeRulesSession().create(
            {"cards": self.cards, "card_ir": invalid_ir},
            self.decks,
            {},
            1,
        )
        self.assertFalse(rejected["success"])
        self.assertEqual(rejected["error_code"], "invalid_card_ir_contract")

    def test_choice_view_is_owner_only_and_failed_choice_rolls_back(self):
        session = ptcg_ai_core.NativeRulesSession()
        created = session.create(self.cards, self.decks, {}, 8080)
        self.assertTrue(created["success"], created)
        pending = created["pending"]
        self.assertEqual(pending["schema_version"], 2)
        owner = int(pending["player"])
        self.assertEqual(session.pending_choice(owner), pending)
        self.assertIsNone(session.pending_choice(1 - owner))

        malformed = session.apply_choice({
            "request_id": pending["request_id"],
            "option_ids": [],
            "cancelled": False,
            "extra": True,
        })
        self.assertFalse(malformed["success"])
        self.assertEqual(malformed["error_code"], "invalid_choice")

        before = (session.state_hash, session.rng_state, session.journal())
        rejected = session.apply_choice(
            {
                "request_id": pending["request_id"],
                "option_ids": [],
                "cancelled": True,
            }
        )
        self.assertFalse(rejected["success"])
        self.assertEqual(rejected["error_code"], "choice_not_cancellable")
        self.assertEqual(
            (session.state_hash, session.rng_state, session.journal()),
            before,
        )

        applied = session.apply_choice(
            {
                "request_id": pending["request_id"],
                "option_ids": [pending["options"][0]["option_id"]],
                "cancelled": False,
            }
        )
        self.assertTrue(applied["success"], applied)
        self.assertEqual(session.revision, 1)
        self.assertIsNone(session.pending_choice(owner))

    def test_action_revision_idempotency_views_snapshot_fork_and_journal(self):
        session, _ = self._created(seed=991)
        query = session.legal_actions(0)
        self.assertEqual(query["schema_version"], 1)
        self.assertTrue(query["success"], query)
        self.assertEqual(query["base_revision"], 0)
        self.assertTrue(query["groups"])

        action = self._bind_first_group(query, "test:setup:1")
        invalid_action = copy.deepcopy(action)
        invalid_action["action_id"] = ""
        rejected_action = session.apply_action(invalid_action)
        self.assertFalse(rejected_action["success"])
        self.assertEqual(rejected_action["error_code"], "invalid_schema")
        self.assertEqual(session.revision, 0)
        applied = session.apply_action(action)
        self.assertTrue(applied["success"], applied)
        self.assertEqual(session.revision, 1)

        own = session.view_for(0)
        opponent = session.view_for(1)
        self.assertIn("hand", own["your"])
        self.assertNotIn("hand", own["opponent"])
        self.assertEqual(own["your"]["active"]["card_id"], action["source"]["card_id"])
        for internal_field in (
            "damage_prevented",
            "all_prevented",
            "outgoing_damage_reduction",
            "attack_locked",
            "attack_locked_names",
            "dazzled",
            "pending_ko_source_kind",
        ):
            self.assertNotIn(internal_field, own["your"]["active"])
        self.assertEqual(opponent["opponent"]["active"], {"hidden": True})
        self.assertNotIn("deck", own["your"])
        self.assertNotIn("prizes", own["your"])

        stable = (session.state_hash, session.rng_state, session.journal())
        duplicate = session.apply_action(action)
        self.assertFalse(duplicate["success"])
        self.assertEqual(duplicate["error_code"], "duplicate_action")
        self.assertEqual(
            (session.state_hash, session.rng_state, session.journal()),
            stable,
        )

        forked = session.fork()
        self.assertEqual(forked.state_hash, session.state_hash)
        self.assertEqual(forked.rng_state, session.rng_state)
        self.assertEqual(forked.snapshot(), session.snapshot())

        search_fork = session.fork_for_search(424242)
        self.assertEqual(search_fork.state_hash, session.state_hash)
        self.assertEqual(search_fork.snapshot(), session.snapshot())
        self.assertEqual(search_fork.rng_state, 424242)
        self.assertEqual(
            (session.state_hash, session.rng_state),
            (stable[0], stable[1]),
        )

        restored = ptcg_ai_core.NativeRulesSession()
        restored.set_catalog(self.cards)
        restored_result = restored.restore(session.snapshot(), session.rng_state)
        self.assertTrue(restored_result["success"], restored_result)
        self.assertEqual(restored.state_hash, session.state_hash)
        self.assertEqual(restored.snapshot(), session.snapshot())

        journal = session.journal()
        self.assertEqual(journal["schema"], "ptcg_match_journal/1")
        self.assertEqual(journal["native_abi_version"], 2)
        self.assertEqual(journal["format_version"], 1)
        self.assertEqual(journal["hash_algorithm"], "fnv1a64-canonical-json")
        self.assertEqual(len(journal["entries"]), 2)
        last = journal["entries"][-1]
        self.assertEqual(last["revision_before"], 0)
        self.assertEqual(last["revision_after"], 1)
        self.assertEqual(last["state_hash"], session.state_hash)
        self.assertRegex(last["event_hash"], r"^[0-9a-f]{16}$")

        replayed = replay_match_journal(
            journal,
            catalog=self.cards,
            decks=self.decks,
        )
        self.assertTrue(replayed.success, replayed)

    def test_player_view_allowlists_pokemon_fields(self):
        session, _ = self._created(seed=992)
        query = session.legal_actions(0)
        action = self._bind_first_group(query, "test:projection:setup")
        applied = session.apply_action(action)
        self.assertTrue(applied["success"], applied)

        snapshot = session.snapshot()
        active = snapshot["players"][0]["active"]
        active["pending_ko_source_kind"] = "attack_damage"
        active["future_internal_probe"] = {"must_not_cross_protocol": True}
        restored = ptcg_ai_core.NativeRulesSession()
        restored.set_catalog(self.cards)
        loaded = restored.load_scenario(
            snapshot,
            session.rng_state,
            {"scenario": "player_view_allowlist"},
        )
        self.assertTrue(loaded["success"], loaded)

        projected = restored.view_for(0)["your"]["active"]
        self.assertNotIn("pending_ko_source_kind", projected)
        self.assertNotIn("future_internal_probe", projected)
        self.assertEqual(projected["card_id"], active["card_id"])

    def test_complete_setup_covers_mulligan_bonus_prizes_and_turn_draw(self):
        session, created = self._created(seed=1)
        self.assertEqual(created["state"]["mulligan_count"], [1, 0])
        step_index = 0
        while session.snapshot()["setup_stage"] != "COMPLETE":
            snapshot = session.snapshot()
            pending = session.pending_choice(0) or session.pending_choice(1)
            if pending is not None:
                response = {
                    "request_id": pending["request_id"],
                    "option_ids": [pending["options"][-1]["option_id"]],
                    "cancelled": False,
                }
                result = session.apply_choice(response)
            else:
                actor = int(snapshot["setup_actor_idx"])
                query = session.legal_actions(actor)
                preferred = next(
                    (
                        group
                        for group in query["groups"]
                        if group["kind"] == "PLAY_BASIC"
                        and snapshot["players"][actor]["active"] is None
                    ),
                    None,
                )
                if preferred is None:
                    preferred = next(
                        group
                        for group in query["groups"]
                        if group["kind"] == "SETUP_DONE"
                    )
                targets = list(preferred["targets"])
                result = session.apply_action({
                    "schema_version": 4,
                    "action_id": f"setup:{step_index}",
                    "base_revision": query["base_revision"],
                    "actor": actor,
                    "kind": preferred["kind"],
                    "source": preferred["source"],
                    "target": targets[0] if targets else None,
                    "payload": preferred["payload"],
                })
            self.assertTrue(result["success"], result)
            step_index += 1
            self.assertLess(step_index, 16)

        final = session.snapshot()
        self.assertEqual(final["phase"], "MAIN")
        self.assertEqual(final["active_player_idx"], 0)
        self.assertEqual([len(player["prizes"]) for player in final["players"]], [6, 6])
        self.assertEqual([len(player["hand"]) for player in final["players"]], [7, 7])
        self.assertEqual(final["extra_draws"], [0, 1])
        self.assertEqual(session.revision, 5)
        self.assertEqual(len(session.journal()["entries"]), 6)

    def test_complete_native_match_is_terminal_and_replayable(self):
        session = ptcg_ai_core.NativeRulesSession()
        created = session.create(
            {"cards": self.cards, "card_ir": self.card_ir},
            self.decks,
            {"forced_first": 0, "public_deck_keys": ["fire", "water"]},
            777,
        )
        self.assertTrue(created["success"], created)
        action_priority = [
            "DECLARE_ATTACK",
            "ATTACH_ENERGY",
            "EVOLVE",
            "PLAY_BASIC",
            "PLAY_TRAINER",
            "USE_ABILITY",
            "USE_STADIUM",
            "END_TURN",
            "RETREAT",
            "SETUP_DONE",
            "PROMOTE",
        ]
        motion_events: list[dict] = []
        presentation_events: list[dict] = []
        for step_index in range(256):
            snapshot = session.snapshot()
            if snapshot["result_status"] != "ONGOING":
                break
            pending = session.pending_choice(0) or session.pending_choice(1)
            if pending is not None:
                selected_count = (
                    int(pending["max_select"])
                    if pending["request_type"] == "select_retreat_payment"
                    else int(pending["min_select"])
                )
                result = session.apply_choice({
                    "request_id": pending["request_id"],
                    "option_ids": [
                        row["option_id"]
                        for row in pending["options"][:selected_count]
                    ],
                    "cancelled": False,
                })
            else:
                actor = (
                    int(snapshot["setup_actor_idx"])
                    if snapshot["phase"] == "SETUP"
                    else int(snapshot["pending_promotions"][0])
                    if snapshot["pending_promotions"]
                    else int(snapshot["active_player_idx"])
                )
                query = session.legal_actions(actor)
                self.assertTrue(query["success"], query)
                groups = list(query["groups"])
                if snapshot["phase"] == "SETUP":
                    preferred = (
                        "PLAY_BASIC"
                        if snapshot["players"][actor]["active"] is None
                        else "SETUP_DONE"
                    )
                    group = next(
                        (row for row in groups if row["kind"] == preferred),
                        groups[0],
                    )
                else:
                    group = min(
                        groups,
                        key=lambda row: (
                            action_priority.index(row["kind"])
                            if row["kind"] in action_priority
                            else len(action_priority)
                        ),
                    )
                result = session.apply_action({
                    "schema_version": 4,
                    "action_id": f"native-match:{step_index}",
                    "base_revision": query["base_revision"],
                    "actor": group["actor"],
                    "kind": group["kind"],
                    "source": group["source"],
                    "target": group["targets"][0] if group["targets"] else None,
                    "payload": group["payload"],
                })
            self.assertTrue(result["success"], result)
            presentation_events.extend(result["events"])
            motion_events.extend(
                event
                for event in result["events"]
                if event.get("event_type") in {
                    "card_moved",
                    "cards_discarded",
                    "cards_drawn",
                    "cards_selected",
                    "energy_attached",
                    "pokemon_evolved",
                    "pokemon_ko",
                    "pokemon_played",
                    "prize_taken",
                    "stadium_changed",
                    "tool_attached",
                    "trainer_played",
                }
            )
        final = session.snapshot()
        self.assertEqual(final["result_status"], "WIN")
        self.assertEqual(final["winner"], 0)
        self.assertEqual(final["result_reason"], "RULE_CONDITIONS")
        self.assertGreater(session.revision, 20)
        action_log = list(final["action_log"])
        self.assertLessEqual(len(action_log), 256)
        for expected_fragment in (
            "使用了「",
            "受到了",
            "抽取了",
            "昏厥了",
            "结束了回合",
            "的回合",
        ):
            self.assertTrue(
                any(expected_fragment in row for row in action_log),
                (expected_fragment, action_log),
            )
        self.assertTrue(
            any(
                event["event_type"] == "damage_dealt"
                for event in presentation_events
            ),
            "deterministic native match did not exercise damage feedback",
        )
        for event in presentation_events:
            event_type = event["event_type"]
            data = event.get("data", {})
            self.assertTrue(data, event)
            if event_type == "attack_declared":
                self.assertTrue(event.get("source"), event)
                self.assertTrue(event.get("target"), event)
            if event_type in {
                "damage_counters_placed",
                "damage_dealt",
                "healed",
            }:
                self.assertGreater(
                    int(event.get("amount", data.get("amount", 0))),
                    0,
                    event,
                )
                self.assertTrue(
                    event.get("target")
                    or data.get("target_slot")
                    or data.get("slot"),
                    event,
                )
            if event_type in {"status_applied", "status_removed"}:
                self.assertTrue(data.get("status"), event)
            if event_type == "game_over":
                self.assertIn(int(data.get("winner", -1)), (0, 1), event)
                self.assertTrue(data.get("reason"), event)
        encountered = {event["event_type"] for event in motion_events}
        self.assertTrue(
            {
                "card_moved",
                "cards_discarded",
                "cards_drawn",
                "energy_attached",
                "pokemon_ko",
                "pokemon_played",
                "prize_taken",
                "trainer_played",
            }.issubset(encountered),
            encountered,
        )
        for event in motion_events:
            data = event.get("data", {})
            count = int(event.get("amount", data.get("count", 0)))
            if event["event_type"] == "cards_selected" and count == 0:
                continue
            self.assertTrue(
                event.get("card_id")
                or data.get("card_id")
                or data.get("card_ids"),
                event,
            )
            if event["event_type"] not in {
                "cards_drawn",
                "pokemon_ko",
                "prize_taken",
            }:
                self.assertTrue(
                    event.get("source")
                    or data.get("source_zone")
                    or data.get("source_slot"),
                    event,
                )
                self.assertTrue(
                    event.get("target")
                    or data.get("target_zone")
                    or data.get("target_slot"),
                    event,
                )
        private_types = {"cards_drawn", "cards_selected", "prize_taken"}
        for event in motion_events:
            if event["event_type"] in private_types:
                self.assertEqual(event.get("visibility"), "owner", event)
        ko_index = next(
            index
            for index, event in enumerate(motion_events)
            if event["event_type"] == "pokemon_ko"
        )
        self.assertTrue(
            motion_events[ko_index]["data"].get("defer_leave_play"),
            motion_events[ko_index],
        )
        ko_leave = next(
            event
            for event in motion_events[ko_index + 1 :]
            if event["event_type"] == "card_moved"
        )
        self.assertTrue(ko_leave["data"].get("ko_leave_play"), ko_leave)
        journal = session.journal()
        self.assertEqual(len(journal["entries"]), session.revision + 1)
        replayed = replay_match_journal(
            journal,
            catalog={"cards": self.cards, "card_ir": self.card_ir},
            decks=self.decks,
        )
        self.assertTrue(replayed.success, replayed)

    def test_randomized_sessions_preserve_rule_state_invariants(self):
        rng = random.Random(0x50544347)

        def card_count(state: dict, owner: int) -> int:
            player = state["players"][owner]
            count = sum(
                len(player[zone])
                for zone in ("deck", "hand", "discard", "prizes")
            )
            for pokemon in [player["active"], *player["bench"]]:
                if not isinstance(pokemon, dict):
                    continue
                count += 1
                count += len(pokemon["evolution_stack_ids"])
                count += len(pokemon["energy_card_ids"])
                count += int(bool(pokemon["attached_tool_id"]))
            if (
                state.get("stadium_card_id")
                and int(state.get("stadium_owner_idx", -1)) == owner
            ):
                count += 1
            return count

        deck_keys = sorted(self.all_decks)
        for match_index in range(len(deck_keys) * 2):
            first_key = deck_keys[match_index % len(deck_keys)]
            second_key = deck_keys[(match_index + 3) % len(deck_keys)]
            match_decks = [
                self.all_decks[first_key],
                self.all_decks[second_key],
            ]
            session = ptcg_ai_core.NativeRulesSession()
            created = session.create(
                {"cards": self.cards, "card_ir": self.card_ir},
                match_decks,
                {
                    "forced_first": match_index % 2,
                    "public_deck_keys": [first_key, second_key],
                },
                9000 + match_index,
            )
            self.assertTrue(created["success"], created)
            for step_index in range(192):
                state = session.snapshot()
                self.assertLessEqual(len(state["action_log"]), 256)
                pending = session.pending_choice(0) or session.pending_choice(1)
                if pending is None:
                    self.assertEqual(card_count(state, 0), 60, state)
                    self.assertEqual(card_count(state, 1), 60, state)
                    for player in state["players"]:
                        for pokemon in player["bench"]:
                            if isinstance(pokemon, dict):
                                self.assertEqual(
                                    pokemon["status_conditions"],
                                    [],
                                    state,
                                )
                    if (
                        state["result_status"] == "ONGOING"
                        and not state["pending_promotions"]
                        and state["phase"] not in {"SETUP", "ATTACK"}
                    ):
                        self.assertIsNotNone(state["players"][0]["active"])
                        self.assertIsNotNone(state["players"][1]["active"])
                if state["result_status"] != "ONGOING":
                    break

                if pending is not None:
                    candidates = list(
                        ptcg_ai_core.NativeGameKernel.choice_candidates(
                            pending
                        )
                    )
                    rng.shuffle(candidates)
                    result = None
                    for candidate in candidates:
                        hash_before = session.state_hash
                        rng_before = session.rng_state
                        probe = session.apply_choice({
                            "request_id": pending["request_id"],
                            "option_ids": list(candidate["selected_options"]),
                            "cancelled": bool(candidate["cancelled"]),
                        })
                        if probe["success"]:
                            result = probe
                            break
                        self.assertEqual(session.state_hash, hash_before)
                        self.assertEqual(session.rng_state, rng_before)
                    self.assertIsNotNone(
                        result,
                        (match_index, step_index, pending, candidates, state),
                    )
                    continue

                actor = (
                    int(state["setup_actor_idx"])
                    if state["phase"] == "SETUP"
                    else int(state["pending_promotions"][0])
                    if state["pending_promotions"]
                    else int(state["active_player_idx"])
                )
                query = session.legal_actions(actor)
                self.assertTrue(query["success"], query)
                actions: list[dict] = []
                for group in query["groups"]:
                    targets = list(group["targets"])
                    for target in targets or [None]:
                        actions.append({
                            "schema_version": 4,
                            "action_id": (
                                f"audit:{match_index}:{step_index}:"
                                f"{len(actions)}"
                            ),
                            "base_revision": query["base_revision"],
                            "actor": group["actor"],
                            "kind": group["kind"],
                            "source": group["source"],
                            "target": target,
                            "payload": group["payload"],
                        })
                self.assertTrue(actions, (match_index, step_index, state))
                result = session.apply_action(rng.choice(actions))
                self.assertTrue(result["success"], result)

            replayed = replay_match_journal(
                session.journal(),
                catalog={"cards": self.cards, "card_ir": self.card_ir},
                decks=match_decks,
            )
            self.assertTrue(replayed.success, replayed)

    def test_cancellable_retreat_restores_full_action_transaction(self):
        fixture = _load_json("godot/tests/fixtures/rules_golden.json")
        case = fixture["cases"]["double_turbo_retreat"]
        snapshot = copy.deepcopy(case["initial_state"])
        snapshot["snapshot_version"] = 3
        snapshot["resolution_stack"]["schema_version"] = 3

        session = ptcg_ai_core.NativeRulesSession()
        session.set_catalog(self.cards)
        loaded = session.load_scenario(
            snapshot,
            int(case["portable_seed"]),
            {"scenario": "double_turbo_retreat"},
        )
        self.assertTrue(loaded["success"], loaded)
        before_snapshot = session.snapshot()
        before_rng = session.rng_state
        before_opponent_view = session.view_for(1)

        query = session.legal_actions(0)
        group = next(row for row in query["groups"] if row["kind"] == "RETREAT")
        targets = list(group["targets"])
        action = {
            "schema_version": 4,
            "action_id": "test:retreat:cancel",
            "base_revision": query["base_revision"],
            "actor": group["actor"],
            "kind": group["kind"],
            "source": group["source"],
            "target": targets[0],
            "payload": group["payload"],
        }
        pending_step = session.apply_action(action)
        self.assertTrue(pending_step["success"], pending_step)
        pending = pending_step["pending"]
        self.assertTrue(pending["can_cancel"])
        self.assertTrue(pending["presentation"]["cancels_action"])
        self.assertEqual(pending["presentation"]["required_units"], 2)
        self.assertEqual(pending_step["events"], [])

        hidden_view = session.view_for(1)
        hidden_view["revision"] = before_opponent_view["revision"]
        self.assertEqual(hidden_view, before_opponent_view)

        cancelled = session.apply_choice({
            "request_id": pending["request_id"],
            "option_ids": [],
            "cancelled": True,
        })
        self.assertTrue(cancelled["success"], cancelled)
        self.assertEqual(cancelled["events"], [])
        after_snapshot = session.snapshot()
        expected_snapshot = copy.deepcopy(before_snapshot)
        expected_snapshot["revision"] = int(pending["base_revision"]) + 1
        self.assertEqual(after_snapshot, expected_snapshot)
        self.assertEqual(session.rng_state, before_rng)
        self.assertNotIn(
            action["action_id"],
            after_snapshot["processed_action_ids"],
        )

    def test_cancellable_trainer_defers_opponent_state_and_events(self):
        fixture = _load_json("godot/tests/fixtures/rules_golden.json")
        snapshot = copy.deepcopy(
            fixture["cases"]["potion_heal_choice"]["initial_state"]
        )
        snapshot["snapshot_version"] = 3
        snapshot["resolution_stack"]["schema_version"] = 3
        snapshot["setup_stage"] = "COMPLETE"
        snapshot["setup_actor_idx"] = -1
        snapshot["players"][0]["hand"] = ["sv2-cand"]
        snapshot["players"][0]["discard"] = []
        snapshot["players"][0]["deck"] = ["sv1-ener-3"] * 10
        snapshot["players"][0]["supporter_played_this_turn"] = False

        session = ptcg_ai_core.NativeRulesSession()
        session.set_catalog(self.cards)
        loaded = session.load_scenario(snapshot, 9191, {"scenario": "candice"})
        self.assertTrue(loaded["success"], loaded)
        before_snapshot = session.snapshot()
        before_rng = session.rng_state
        before_opponent = session.view_for(1)

        query = session.legal_actions(0)
        group = next(
            row
            for row in query["groups"]
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "sv2-cand"
        )
        action = {
            "schema_version": 4,
            "action_id": "test:trainer:cancel",
            "base_revision": query["base_revision"],
            "actor": 0,
            "kind": "PLAY_TRAINER",
            "source": group["source"],
            "target": None,
            "payload": group["payload"],
        }
        pending_step = session.apply_action(action)
        self.assertTrue(pending_step["success"], pending_step)
        self.assertEqual(pending_step["events"], [])
        pending = pending_step["pending"]
        self.assertTrue(pending["can_cancel"])
        self.assertTrue(pending["presentation"]["cancels_action"])

        owner_view = session.view_for(0)
        self.assertEqual(owner_view["your"]["hand_count"], 0)
        opponent_view = session.view_for(1)
        self.assertEqual(opponent_view["opponent"]["hand_count"], 1)
        opponent_view["revision"] = before_opponent["revision"]
        self.assertEqual(opponent_view, before_opponent)

        cancelled = session.apply_choice({
            "request_id": pending["request_id"],
            "option_ids": [],
            "cancelled": True,
        })
        self.assertTrue(cancelled["success"], cancelled)
        self.assertEqual(
            [event["event_type"] for event in cancelled["events"]],
            ["card_moved"],
        )
        self.assertEqual(cancelled["events"][0]["visibility"], "private")
        after_snapshot = session.snapshot()
        expected_snapshot = copy.deepcopy(before_snapshot)
        expected_snapshot["revision"] = int(pending["base_revision"]) + 1
        self.assertEqual(after_snapshot, expected_snapshot)
        self.assertEqual(session.rng_state, before_rng)

    def test_discard_zone_recovery_log_is_not_reported_as_discarding(self):
        fixture = _load_json("godot/tests/fixtures/rules_golden.json")
        snapshot = copy.deepcopy(
            fixture["cases"]["potion_heal_choice"]["initial_state"]
        )
        snapshot["snapshot_version"] = 3
        snapshot["resolution_stack"]["schema_version"] = 3
        snapshot["setup_stage"] = "COMPLETE"
        snapshot["setup_actor_idx"] = -1
        snapshot["phase"] = "MAIN"
        snapshot["turn_number"] = 3
        snapshot["active_player_idx"] = 0
        snapshot["first_player_idx"] = 1
        owner = snapshot["players"][0]
        owner["hand"] = ["svi-erec"]
        owner["discard"] = ["sv1-ener-2"]
        owner["deck"] = ["sv1-151", "sv1-180", "sv1-ener-2"]

        session = ptcg_ai_core.NativeRulesSession()
        session.set_catalog(self.cards)
        loaded = session.load_scenario(
            snapshot,
            0x45524543,
            {"scenario": "energy_recycler_log"},
        )
        self.assertTrue(loaded["success"], loaded)

        query = session.legal_actions(0)
        group = next(
            row
            for row in query["groups"]
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "svi-erec"
        )
        action = {
            "schema_version": 4,
            "action_id": "test:energy-recycler:log",
            "base_revision": query["base_revision"],
            "actor": 0,
            "kind": "PLAY_TRAINER",
            "source": group["source"],
            "target": None,
            "payload": group["payload"],
        }
        suspended = session.apply_action(action)
        self.assertTrue(suspended["success"], suspended)
        pending = suspended["pending"]
        self.assertEqual(pending["request_type"], "shuffle_from_discard")
        self.assertEqual(pending["presentation"]["purpose"], "shuffle_from_discard")
        self.assertEqual(pending["min_select"], 1)
        self.assertEqual(len(pending["options"]), 1)

        resumed = session.apply_choice({
            "request_id": pending["request_id"],
            "option_ids": [pending["options"][0]["option_id"]],
            "cancelled": False,
        })
        self.assertTrue(resumed["success"], resumed)
        final = session.snapshot()
        self.assertIn("sv1-ener-2", final["players"][0]["deck"])
        self.assertNotIn("sv1-ener-2", final["players"][0]["discard"])
        self.assertIn("svi-erec", final["players"][0]["discard"])
        self.assertTrue(
            any(
                "选择将 1 张卡牌从弃牌区放回牌库"
                in row
                for row in final["action_log"]
            ),
            final["action_log"],
        )
        self.assertFalse(
            any("选择弃置" in row for row in final["action_log"]),
            final["action_log"],
        )

    def test_real_hand_discard_choice_remains_explicit_in_log(self):
        fixture = _load_json("godot/tests/fixtures/rules_golden.json")
        snapshot = copy.deepcopy(
            fixture["cases"]["potion_heal_choice"]["initial_state"]
        )
        snapshot["snapshot_version"] = 3
        snapshot["resolution_stack"]["schema_version"] = 3
        snapshot["setup_stage"] = "COMPLETE"
        snapshot["setup_actor_idx"] = -1
        snapshot["phase"] = "MAIN"
        snapshot["turn_number"] = 3
        snapshot["active_player_idx"] = 0
        snapshot["first_player_idx"] = 1
        owner = snapshot["players"][0]
        owner["hand"] = [
            "svl-zinn",
            "sv1-151",
            "sv1-180",
            "sv1-ener-2",
        ]
        owner["discard"] = []
        owner["deck"] = ["sv1-ener-2"] * 10
        owner["supporter_played_this_turn"] = False

        session = ptcg_ai_core.NativeRulesSession()
        session.set_catalog(self.cards)
        loaded = session.load_scenario(
            snapshot,
            0x5A494E4E,
            {"scenario": "real_discard_log"},
        )
        self.assertTrue(loaded["success"], loaded)

        query = session.legal_actions(0)
        group = next(
            row
            for row in query["groups"]
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "svl-zinn"
        )
        suspended = session.apply_action({
            "schema_version": 4,
            "action_id": "test:zinnia:discard-log",
            "base_revision": query["base_revision"],
            "actor": 0,
            "kind": "PLAY_TRAINER",
            "source": group["source"],
            "target": None,
            "payload": group["payload"],
        })
        self.assertTrue(suspended["success"], suspended)
        pending = suspended["pending"]
        self.assertEqual(pending["request_type"], "zinnia")
        self.assertEqual(pending["presentation"]["purpose"], "zinnia")
        self.assertEqual(pending["min_select"], 2)

        resumed = session.apply_choice({
            "request_id": pending["request_id"],
            "option_ids": [
                pending["options"][0]["option_id"],
                pending["options"][1]["option_id"],
            ],
            "cancelled": False,
        })
        self.assertTrue(resumed["success"], resumed)
        action_log = session.snapshot()["action_log"]
        self.assertTrue(
            any("选择弃置了 2 张手牌" in row for row in action_log),
            action_log,
        )

    def test_identical_pokemon_switch_events_keep_explicit_slot_identity(self):
        fixture = _load_json("godot/tests/fixtures/rules_golden.json")
        snapshot = copy.deepcopy(
            fixture["cases"]["double_turbo_retreat"]["initial_state"]
        )
        snapshot["snapshot_version"] = 3
        snapshot["resolution_stack"]["schema_version"] = 3
        snapshot["setup_stage"] = "COMPLETE"
        snapshot["setup_actor_idx"] = -1
        snapshot["phase"] = "MAIN"
        snapshot["turn_number"] = 3
        snapshot["active_player_idx"] = 0
        snapshot["first_player_idx"] = 1
        owner = snapshot["players"][0]
        active = copy.deepcopy(owner["active"])
        active.update({
            "card_id": "svi-chim",
            "damage_counters": 0,
            "energy_card_ids": ["sv1-ener-2"],
            "attached_tool_id": "",
            "status_conditions": [],
            "evolution_stack_ids": [],
            "placed_this_turn": False,
            "modifiers": [],
        })
        bench_copy = copy.deepcopy(active)
        bench_copy["energy_card_ids"] = []
        owner["active"] = active
        owner["bench"] = [bench_copy, None, None, None, None]
        owner["retreated_this_turn"] = False

        session = ptcg_ai_core.NativeRulesSession()
        session.set_catalog(self.cards)
        loaded = session.load_scenario(
            snapshot,
            0x53574150,
            {"scenario": "identical_retreat_event"},
        )
        self.assertTrue(loaded["success"], loaded)
        query = session.legal_actions(0)
        group = next(row for row in query["groups"] if row["kind"] == "RETREAT")
        action = {
            "schema_version": 4,
            "action_id": "test:identical:retreat",
            "base_revision": query["base_revision"],
            "actor": 0,
            "kind": "RETREAT",
            "source": group["source"],
            "target": group["targets"][0],
            "payload": group["payload"],
        }
        suspended = session.apply_action(action)
        self.assertTrue(suspended["success"], suspended)
        pending = suspended["pending"]
        self.assertEqual(pending["request_type"], "select_retreat_payment")
        resumed = session.apply_choice({
            "request_id": pending["request_id"],
            "option_ids": [pending["options"][0]["option_id"]],
            "cancelled": False,
        })
        self.assertTrue(resumed["success"], resumed)
        retreat_event = next(
            event for event in resumed["events"]
            if event["event_type"] == "retreat"
        )
        retreat_data = retreat_event["data"]
        self.assertEqual(retreat_data["player"], 0)
        self.assertEqual(retreat_data["slot"], "bench_0")
        self.assertEqual(retreat_data["bench_idx"], 0)
        self.assertEqual(retreat_data["outgoing_card_id"], "svi-chim")
        self.assertEqual(retreat_data["incoming_card_id"], "svi-chim")

        switch_snapshot = copy.deepcopy(snapshot)
        switch_owner = switch_snapshot["players"][0]
        switch_owner["active"] = copy.deepcopy(active)
        switch_owner["active"]["energy_card_ids"] = []
        switch_owner["bench"] = [copy.deepcopy(bench_copy), None, None, None, None]
        switch_owner["hand"] = ["sv1-150"]
        switch_owner["retreated_this_turn"] = False
        switch_session = ptcg_ai_core.NativeRulesSession()
        switch_session.set_catalog(self.cards)
        switch_loaded = switch_session.load_scenario(
            switch_snapshot,
            0x53574954,
            {"scenario": "identical_switch_event"},
        )
        self.assertTrue(switch_loaded["success"], switch_loaded)
        switch_query = switch_session.legal_actions(0)
        switch_group = next(
            row for row in switch_query["groups"]
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "sv1-150"
        )
        switched = switch_session.apply_action({
            "schema_version": 4,
            "action_id": "test:identical:switch",
            "base_revision": switch_query["base_revision"],
            "actor": 0,
            "kind": "PLAY_TRAINER",
            "source": switch_group["source"],
            "target": None,
            "payload": switch_group["payload"],
        })
        self.assertTrue(switched["success"], switched)
        switch_event = next(
            event for event in switched["events"]
            if event["event_type"] == "switched"
        )
        self.assertEqual(switch_event["data"]["slot"], "bench_0")
        self.assertEqual(switch_event["data"]["outgoing_card_id"], "svi-chim")
        self.assertEqual(switch_event["data"]["incoming_card_id"], "svi-chim")

    def test_judge_events_keep_physical_player_and_hidden_owner(self):
        fixture = _load_json("godot/tests/fixtures/rules_golden.json")
        snapshot = copy.deepcopy(
            fixture["cases"]["shuffle_draw_supporter"]["initial_state"]
        )
        snapshot["snapshot_version"] = 3
        snapshot["resolution_stack"]["schema_version"] = 3
        snapshot["setup_stage"] = "COMPLETE"
        snapshot["setup_actor_idx"] = -1
        snapshot["players"][0]["hand"] = [
            "sv1-176",
            "svi-chim",
            "sv1-ener-2",
        ]
        snapshot["players"][1]["hand"] = ["sv1-104", "sv1-ener-4"]

        session = ptcg_ai_core.NativeRulesSession()
        session.set_catalog(self.cards)
        loaded = session.load_scenario(
            snapshot,
            0x4A554447,
            {"scenario": "judge_event_ownership"},
        )
        self.assertTrue(loaded["success"], loaded)
        query = session.legal_actions(0)
        group = next(
            row
            for row in query["groups"]
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "sv1-176"
        )
        applied = session.apply_action({
            "schema_version": 4,
            "action_id": "test:judge:event-ownership",
            "base_revision": query["base_revision"],
            "actor": 0,
            "kind": "PLAY_TRAINER",
            "source": group["source"],
            "target": None,
            "payload": group["payload"],
        })
        self.assertTrue(applied["success"], applied)

        returned_hands = [
            event
            for event in applied["events"]
            if event["event_type"] == "card_moved"
            and event["data"].get("source_zone") == "hand"
            and event["data"].get("target_zone") == "deck"
        ]
        self.assertEqual(
            [event["data"]["player"] for event in returned_hands],
            [0, 1],
        )
        for event in returned_hands:
            self.assertEqual(event["visibility"], "owner", event)
            self.assertEqual(
                event["data"]["visibility_owner"],
                event["data"]["player"],
                event,
            )
        shuffled = [
            event
            for event in applied["events"]
            if event["event_type"] == "deck_shuffled"
        ]
        self.assertEqual(
            [(event["actor"], event["data"]["player"]) for event in shuffled],
            [(0, 0), (1, 1)],
        )

    def test_youngster_log_keeps_shuffle_and_five_card_draw_causal(self):
        fixture = _load_json("godot/tests/fixtures/rules_golden.json")
        snapshot = copy.deepcopy(
            fixture["cases"]["shuffle_draw_supporter"]["initial_state"]
        )
        snapshot["snapshot_version"] = 3
        snapshot["resolution_stack"]["schema_version"] = 3
        snapshot["setup_stage"] = "COMPLETE"
        snapshot["setup_actor_idx"] = -1

        session = ptcg_ai_core.NativeRulesSession()
        session.set_catalog(self.cards)
        loaded = session.load_scenario(
            snapshot,
            0x594F554E,
            {"scenario": "youngster_action_log"},
        )
        self.assertTrue(loaded["success"], loaded)
        query = session.legal_actions(0)
        group = next(
            row
            for row in query["groups"]
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "sv2-young"
        )
        applied = session.apply_action({
            "schema_version": 4,
            "action_id": "test:youngster:log",
            "base_revision": query["base_revision"],
            "actor": 0,
            "kind": "PLAY_TRAINER",
            "source": group["source"],
            "target": None,
            "payload": group["payload"],
        })
        self.assertTrue(applied["success"], applied)
        moved = next(
            event for event in applied["events"]
            if event["event_type"] == "card_moved"
            and event["data"].get("source_zone") == "hand"
            and event["data"].get("target_zone") == "deck"
        )
        drawn = next(
            event for event in applied["events"]
            if event["event_type"] == "cards_drawn"
            and event["data"].get("purpose") == "shuffle_then_draw"
        )
        # sv1-ener-2 is both returned and drawn in this deterministic case.
        # Presentation must animate the physical operations, not their smaller
        # card-id multiset delta.
        self.assertIn("sv1-ener-2", moved["data"]["card_ids"])
        self.assertIn("sv1-ener-2", drawn["data"]["card_ids"])
        self.assertEqual(moved["amount"], moved["data"]["count"])
        self.assertEqual(drawn["amount"], drawn["data"]["count"])
        self.assertEqual(moved["amount"], 2)
        self.assertEqual(drawn["amount"], 5)
        logs = session.snapshot()["action_log"]
        trainer_index = next(
            index for index, line in enumerate(logs)
            if "使用了训练家卡 短裤小子" in line
        )
        return_index = next(
            index for index, line in enumerate(logs)
            if "将 2 张手牌放回了牌库" in line
        )
        shuffle_index = next(
            index for index, line in enumerate(logs)
            if "重洗了牌库" in line
        )
        draw_index = next(
            index for index, line in enumerate(logs)
            if "抽取了 5 张卡牌" in line
        )
        self.assertLess(trainer_index, return_index)
        self.assertLess(return_index, shuffle_index)
        self.assertLess(shuffle_index, draw_index)
        self.assertFalse(any("抽取了 3 张卡牌" in line for line in logs))

    def test_discard_then_redraw_same_card_keeps_both_physical_events(self):
        fixture = _load_json("godot/tests/fixtures/rules_golden.json")
        snapshot = copy.deepcopy(
            fixture["cases"]["potion_heal_choice"]["initial_state"]
        )
        snapshot["snapshot_version"] = 3
        snapshot["resolution_stack"]["schema_version"] = 3
        snapshot.update({
            "setup_stage": "COMPLETE",
            "setup_actor_idx": -1,
            "phase": "MAIN",
            "turn_number": 3,
            "active_player_idx": 0,
            "first_player_idx": 1,
        })
        owner = snapshot["players"][0]
        owner["active"].update({
            "card_id": "sv1-109",
            "damage_counters": 0,
            "energy_card_ids": ["sv1-ener-5"],
            "evolution_stack_ids": [],
            "attached_tool_id": "",
            "status_conditions": [],
            "placed_this_turn": False,
            "modifiers": [],
        })
        owner["hand"] = ["svi-chim", "sv1-151"]
        owner["deck"] = ["sv1-ener-1", "sv1-ener-2", "svi-chim"]
        owner["discard"] = []

        session = ptcg_ai_core.NativeRulesSession()
        session.set_catalog(self.cards)
        loaded = session.load_scenario(
            snapshot,
            0x4359434C,
            {"scenario": "same_id_discard_draw"},
        )
        self.assertTrue(loaded["success"], loaded)
        query = session.legal_actions(0)
        group = next(
            row for row in query["groups"]
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"].get("attack_index") == 0
        )
        suspended = session.apply_action({
            "schema_version": 4,
            "action_id": "test:same-id:discard-draw",
            "base_revision": query["base_revision"],
            "actor": 0,
            "kind": "DECLARE_ATTACK",
            "source": group["source"],
            "target": None,
            "payload": group["payload"],
        })
        self.assertTrue(suspended["success"], suspended)
        pending = suspended["pending"]
        self.assertEqual(pending["min_select"], 1)
        self.assertEqual(pending["max_select"], 1)
        resumed = session.apply_choice({
            "request_id": pending["request_id"],
            "option_ids": [pending["options"][0]["option_id"]],
            "cancelled": False,
        })
        self.assertTrue(resumed["success"], resumed)
        discarded = next(
            event for event in resumed["events"]
            if event["event_type"] == "cards_discarded"
        )
        drawn = next(
            event for event in resumed["events"]
            if event["event_type"] == "cards_drawn"
        )
        self.assertEqual(discarded["data"]["card_ids"], ["svi-chim"])
        self.assertEqual(discarded["data"]["source_zone"], "hand")
        self.assertEqual(discarded["data"]["target_zone"], "discard")
        self.assertEqual(discarded["amount"], 1)
        self.assertEqual(discarded["source"]["zone"], "hand")
        self.assertEqual(discarded["target"]["zone"], "discard")
        self.assertEqual(drawn["data"]["card_ids"][0], "svi-chim")
        self.assertEqual(drawn["amount"], 3)
        self.assertEqual(drawn["source"]["zone"], "deck")
        self.assertEqual(drawn["target"]["zone"], "hand")

    def test_professors_research_same_ids_keep_physical_event_endpoints(self):
        fixture = _load_json("godot/tests/fixtures/rules_golden.json")
        snapshot = copy.deepcopy(
            fixture["cases"]["potion_heal_choice"]["initial_state"]
        )
        snapshot["snapshot_version"] = 3
        snapshot["resolution_stack"]["schema_version"] = 3
        snapshot.update({
            "setup_stage": "COMPLETE",
            "setup_actor_idx": -1,
            "phase": "MAIN",
            "turn_number": 3,
            "active_player_idx": 0,
            "first_player_idx": 1,
        })
        owner = snapshot["players"][0]
        owner["hand"] = ["sv1-189", "sv1-ener-2", "svi-chim"]
        owner["deck"] = [
            "sv1-150",
            "sv1-189",
            "sv1-153",
            "sv1-176",
            "sv1-151",
            "sv1-ener-2",
            "svf-potion",
        ]
        owner["discard"] = []

        session = ptcg_ai_core.NativeRulesSession()
        session.set_catalog(self.cards)
        loaded = session.load_scenario(
            snapshot,
            0x50524F46,
            {"scenario": "professors_research_same_ids"},
        )
        self.assertTrue(loaded["success"], loaded)
        query = session.legal_actions(0)
        group = next(
            row for row in query["groups"]
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "sv1-189"
        )
        result = session.apply_action({
            "schema_version": 4,
            "action_id": "test:professors-research:same-ids",
            "base_revision": query["base_revision"],
            "actor": 0,
            "kind": "PLAY_TRAINER",
            "source": group["source"],
            "target": None,
            "payload": group["payload"],
        })
        self.assertTrue(result["success"], result)
        trainer = next(
            event for event in result["events"]
            if event["event_type"] == "trainer_played"
        )
        discarded = next(
            event for event in result["events"]
            if event["event_type"] == "cards_discarded"
        )
        drawn = next(
            event for event in result["events"]
            if event["event_type"] == "cards_drawn"
        )

        self.assertEqual(trainer["card_id"], "sv1-189")
        self.assertEqual(trainer["source"]["zone"], "hand")
        self.assertEqual(trainer["source"]["index"], 0)
        self.assertEqual(trainer["target"]["zone"], "discard")
        self.assertEqual(
            discarded["data"]["card_ids"],
            ["sv1-ener-2", "svi-chim"],
        )
        self.assertEqual(discarded["source"]["zone"], "hand")
        self.assertEqual(discarded["target"]["zone"], "discard")
        self.assertEqual(discarded["amount"], 2)
        self.assertIn("sv1-189", drawn["data"]["card_ids"])
        self.assertIn("sv1-ener-2", drawn["data"]["card_ids"])
        self.assertEqual(drawn["source"]["zone"], "deck")
        self.assertEqual(drawn["target"]["zone"], "hand")
        self.assertEqual(drawn["amount"], 7)

    def test_empty_hand_discard_zone_ability_is_published_and_applies(self):
        fixture = _load_json("godot/tests/fixtures/rules_golden.json")
        snapshot = copy.deepcopy(
            fixture["cases"]["potion_heal_choice"]["initial_state"]
        )
        snapshot["snapshot_version"] = 3
        snapshot["resolution_stack"]["schema_version"] = 3
        snapshot.update({
            "setup_stage": "COMPLETE",
            "setup_actor_idx": -1,
            "phase": "MAIN",
            "turn_number": 3,
            "active_player_idx": 0,
            "first_player_idx": 1,
        })
        owner = snapshot["players"][0]
        owner["hand"] = []
        owner["discard"] = ["sv1-151", "svg2-empo"]
        owner["deck"] = ["sv1-150", "sv1-153", "sv1-176"]
        owner["bench"] = [None, None, None, None, None]

        session = ptcg_ai_core.NativeRulesSession()
        session.set_catalog(self.cards)
        loaded = session.load_scenario(
            snapshot,
            0x454D504F,
            {"scenario": "empoleon_empty_hand"},
        )
        self.assertTrue(loaded["success"], loaded)
        query = session.legal_actions(0)
        group = next(
            row for row in query["groups"]
            if row["kind"] == "USE_ABILITY"
            and row["source"]["card_id"] == "svg2-empo"
            and row["source"]["zone"] == "discard"
        )
        self.assertEqual(group["source"]["index"], 1)
        result = session.apply_action({
            "schema_version": 4,
            "action_id": "test:empoleon:empty-hand",
            "base_revision": query["base_revision"],
            "actor": 0,
            "kind": "USE_ABILITY",
            "source": group["source"],
            "target": None,
            "payload": group["payload"],
        })
        self.assertTrue(result["success"], result)
        final_owner = result["state"]["players"][0]
        self.assertEqual(final_owner["discard"], ["sv1-151"])
        self.assertEqual(final_owner["bench"][0]["card_id"], "svg2-empo")
        self.assertEqual(
            final_owner["hand"],
            ["sv1-176", "sv1-153", "sv1-150"],
        )
        self.assertIn("card_moved", [
            event["event_type"] for event in result["events"]
        ])
        self.assertIn("cards_drawn", [
            event["event_type"] for event in result["events"]
        ])


if __name__ == "__main__":
    unittest.main()
