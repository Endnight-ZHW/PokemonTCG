"""Remote multiplayer synchronization for GameScreen."""
from __future__ import annotations

from config import CARD_HEIGHT, SCREEN_WIDTH
from engine.actions import GameAction
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import ActionRequest, ActionResult
from network.message_protocol import (
    MSG_ACTION,
    MSG_CHOICE_RESPONSE,
    MSG_SEQ_FIELD,
    MSG_STATE_UPDATE,
)
from ui.audio_manager import get_audio
from ui.colors import UI_HIGHLIGHT
from ui.components.game_layout import (
    FIELD_ACTIVE_H,
    HAND_Y,
    OPP_ACTIVE_Y,
    PLAY_AREA_W,
    SLOT_OPP_ACTIVE,
    SLOT_PLAYER_ACTIVE,
)
from ui.particles import attack_impact, energy_spark, evolution_glow, ko_burst


class GameScreenNetworkMixin:
    """Owns online input blocking, outbound actions, and inbound state updates."""

    def _should_block_remote_input(self) -> bool:
        if self._is_remote_client:
            if self.state.phase == TurnPhase.SETUP:
                return self.setup_player_idx != self.my_player_idx
            return self.state.active_player_idx != self.my_player_idx
        if self._is_remote_host:
            if self.state.phase == TurnPhase.SETUP:
                return self.setup_player_idx != self.my_player_idx
            return self.state.active_player_idx != self.my_player_idx
        return False

    def _ensure_request_id(self, action_req: ActionRequest | None) -> str:
        if action_req is None:
            return ""
        if not getattr(action_req, "request_id", ""):
            self._remote_request_counter += 1
            action_req.request_id = f"req-{self._remote_request_counter}"
        return action_req.request_id

    def _send_client_action(self, action, params: dict | None = None):
        if not self.network_manager:
            return
        self.network_manager.send({
            "type": MSG_ACTION,
            "action": action,
            "params": params or {},
        })

    def _send_choice_response(self, payload: dict):
        if not self.network_manager:
            return
        self.network_manager.send({
            "type": MSG_CHOICE_RESPONSE,
            **payload,
        })

    def _build_result_payload(self, result, action=None, attacker_player_idx=None) -> dict:
        from network.message_protocol import ACTION_TO_STRING
        from network.state_serializer import serialize_action_request

        payload = {
            "success": result.success,
            "log_message": result.log_message,
            "damage_dealt": result.damage_dealt,
            "pokemon_ko": result.pokemon_ko,
            "status_applied": result.status_applied,
            "prize_taken": result.prize_taken,
            "cards_drawn": len(result.cards_drawn),
            "cards_discarded": result.cards_discarded,
        }
        if attacker_player_idx is not None:
            payload["attacker_player_idx"] = attacker_player_idx
        if action is not None:
            payload["action"] = ACTION_TO_STRING.get(action, str(action))
        if result.success:
            desc = self._build_action_desc(result)
            if desc:
                payload["action_desc"] = desc
        if result.pending_action:
            self._ensure_request_id(result.pending_action)
            payload["pending_action"] = serialize_action_request(result.pending_action)
        return payload

    def _broadcast_state(self):
        self._broadcast_update()

    def _broadcast_update(
        self,
        result=None,
        action=None,
        attacker_player_idx=None,
        pending_action: ActionRequest | None = None,
    ):
        if not self.network_manager or not self._is_remote_host:
            return
        import random
        from network.state_serializer import serialize_action_request, serialize_game_state

        remote_idx = 1 - self.my_player_idx
        msg = {
            "type": MSG_STATE_UPDATE,
            "state": serialize_game_state(self.state, for_player_idx=remote_idx),
            "setup_player_idx": getattr(self, "setup_player_idx", 0),
        }
        if result is not None:
            msg["result"] = self._build_result_payload(
                result,
                action=action,
                attacker_player_idx=attacker_player_idx,
            )
            if result.pending_action:
                pending_action = result.pending_action
        if pending_action is not None:
            self._ensure_request_id(pending_action)
            pending_payload = serialize_action_request(pending_action)
            # Host generates coin results to prevent client cheating
            if pending_action.request_type == "coin_flip":
                if getattr(pending_action, 'until_tails', False):
                    flips = []
                    while True:
                        flips.append(random.random() >= 0.5)
                        if not flips[-1]:
                            break
                    pending_payload["predetermined_flips"] = flips
                else:
                    fc = getattr(pending_action, 'flip_count', 1)
                    pending_payload["predetermined_flips"] = [
                        random.random() >= 0.5 for _ in range(max(1, fc))
                    ]
                # Store on the action request for later resolution
                setattr(pending_action, "_host_coin_results", pending_payload["predetermined_flips"])
            msg["pending_action"] = pending_payload
        self.network_manager.send(msg)

    def _broadcast_result(self, result, action=None, attacker_player_idx=None):
        self._broadcast_update(result, action=action, attacker_player_idx=attacker_player_idx)

    def _handle_remote_result_payload(self, msg: dict):
        msg_pending = msg.get("pending_action")
        if msg_pending:
            from network.state_serializer import deserialize_action_request
            self._resolving_remote_pending = True
            pending = deserialize_action_request(msg_pending)
            self._handle_pending_action(pending)
        else:
            msg_attacker = msg.get("attacker_player_idx")
            is_self_action = msg_attacker is not None and msg_attacker == self.my_player_idx
            if is_self_action:
                damage_slot = SLOT_OPP_ACTIVE
                shake_slot = SLOT_PLAYER_ACTIVE
                damage_rect = self._opp_active_rect()
                action_rect = self._player_active_rect()
            else:
                damage_slot = SLOT_PLAYER_ACTIVE
                shake_slot = SLOT_OPP_ACTIVE
                damage_rect = self._player_active_rect()
                action_rect = self._opp_active_rect()

            if msg.get("damage_dealt", 0) > 0:
                self.damage_flash.trigger(damage_slot)
                self.attack_shake.trigger(shake_slot)
                get_audio().play("attack_hit")
                if damage_rect:
                    self.particles.spawn_particles(
                        attack_impact(
                            damage_rect.x + damage_rect.w // 2,
                            damage_rect.y + damage_rect.h // 2,
                        )
                    )
            if msg.get("pokemon_ko"):
                self.ko_fade.trigger(damage_slot)
                get_audio().play("pokemon_ko")
                if damage_rect:
                    self.particles.spawn_particles(
                        ko_burst(
                            damage_rect.x + damage_rect.w // 2,
                            damage_rect.y + damage_rect.h // 2,
                        )
                    )

            action_str = msg.get("action", "")
            if not self._suppress_action_particles:
                if action_str == "EVOLVE":
                    if action_rect:
                        self.particles.spawn_particles(
                            evolution_glow(
                                action_rect.x + action_rect.w // 2,
                                action_rect.y + action_rect.h // 2,
                            )
                        )
                    get_audio().play("evolution")
                elif action_str == "ATTACH_ENERGY":
                    if action_rect:
                        self.particles.spawn_particles(
                            energy_spark(
                                action_rect.x + action_rect.w // 2,
                                action_rect.y + action_rect.h // 2,
                            )
                        )
            self._suppress_action_particles = False

        action_desc = msg.get("action_desc", "")
        if action_desc:
            self.floating_text.show(
                action_desc,
                SCREEN_WIDTH // 2,
                OPP_ACTIVE_Y + FIELD_ACTIVE_H // 2,
                color=UI_HIGHLIGHT,
                duration=1.5,
            )

    def _process_network_message(self, msg: dict):
        msg_type = msg.get("type", "")

        if msg_type == MSG_STATE_UPDATE:
            if not self._is_remote_client:
                return
            update_seq = msg.get(MSG_SEQ_FIELD, 0)
            if msg_type == MSG_STATE_UPDATE and isinstance(update_seq, int):
                if update_seq <= self._last_state_update_seq:
                    return
                self._last_state_update_seq = update_seq
            from network.state_serializer import deserialize_game_state

            old_player = self.state.get_player(self.my_player_idx)
            old_hand = len(old_player.hand) if old_player else 0
            old_discard = len(old_player.discard) if old_player else 0
            old_deck = len(old_player.deck) if old_player else 0

            prev_snap = self._snapshot_field_state()
            self.state = deserialize_game_state(
                msg["state"],
                for_player_idx=self.my_player_idx,
            )
            if "setup_player_idx" in msg:
                self.setup_player_idx = msg["setup_player_idx"]
            self._build_action_buttons()
            self._turn_ending = False
            self._waiting_remote = False
            self._resolving_remote_pending = False
            self._remote_update_fade = 0.0

            new_player = self.state.get_player(self.my_player_idx)
            new_hand = len(new_player.hand) if new_player else 0
            new_discard = len(new_player.discard) if new_player else 0
            new_deck = len(new_player.deck) if new_player else 0

            if new_hand > old_hand and new_deck < old_deck:
                drawn = min(new_hand - old_hand, old_deck - new_deck)
                for _ in range(drawn):
                    self._animate_draw(self.my_player_idx)

            if new_discard > old_discard:
                source = self._last_action_source_for(self.my_player_idx)
                if source:
                    discarded = new_discard - old_discard
                    src_x, src_y = source
                    card_name = self._last_action_card_name
                    card_obj = self._last_action_card_obj
                    self._clear_last_action_context()
                    for _ in range(discarded):
                        self._animate_discard(
                            self.my_player_idx,
                            src_x,
                            src_y,
                            card_name,
                            card_obj,
                        )
                elif new_hand < old_hand:
                    discarded = min(new_discard - old_discard, old_hand - new_hand)
                    src_x = PLAY_AREA_W // 2
                    src_y = HAND_Y + CARD_HEIGHT // 2
                    for _ in range(discarded):
                        self._animate_discard(self.my_player_idx, src_x, src_y)

            self._sync_tracking_counts()
            self._remote_update_just_arrived = True
            self._suppress_action_particles = True
            self._detect_field_changes(prev_snap)

            result_payload = msg.get("result")
            pending_payload = msg.get("pending_action")
            if pending_payload:
                result_payload = dict(result_payload or {})
                result_payload["pending_action"] = pending_payload
            if result_payload:
                self._handle_remote_result_payload(result_payload)

        elif msg_type == "action":
            if not self._is_remote_host or not self.tm:
                return
            self._waiting_remote = False
            action_str = msg.get("action", "")
            params = msg.get("params", {})

            from network.message_protocol import STRING_TO_ACTION
            action = STRING_TO_ACTION.get(action_str, action_str)

            if action == "SETUP_DONE":
                self._remote_setup_done(params.get("player_idx", 1))
                return

            prev_snap = self._snapshot_field_state()
            remote_idx = params.get("player_idx", self.state.active_player_idx)

            if self.state.phase != TurnPhase.SETUP and remote_idx != self.state.active_player_idx:
                self.state._log("忽略非当前回合玩家的操作。")
                return

            if action == PlayerAction.END_TURN:
                result = self.tm.perform_action(
                    PlayerAction.END_TURN,
                    player_idx=remote_idx,
                )
            elif action == PlayerAction.DECLARE_ATTACK:
                attack_idx = params.get("attack_idx", 0)
                step = self.game_engine.apply_action(
                    self.state,
                    GameAction(
                        PlayerAction.DECLARE_ATTACK,
                        {"attack_idx": attack_idx},
                        terminal=True,
                        actor=remote_idx,
                    ),
                    auto_resolve=False,
                    auto_finish_attack=True,
                )
                result = step.action_result or ActionResult(step.success, step.message)
            elif action == PlayerAction.RETREAT:
                result = self.tm.perform_action(
                    PlayerAction.RETREAT,
                    player_idx=remote_idx,
                    bench_idx=params.get("bench_idx", 0),
                )
            elif action == PlayerAction.PLAY_BASIC:
                result = self.tm.perform_action(
                    PlayerAction.PLAY_BASIC,
                    player_idx=remote_idx,
                    hand_idx=params.get("hand_idx", 0),
                    target=params.get("target", "bench_0"),
                )
            elif action == PlayerAction.EVOLVE:
                result = self.tm.perform_action(
                    PlayerAction.EVOLVE,
                    player_idx=remote_idx,
                    hand_idx=params.get("hand_idx", 0),
                    slot=params.get("slot", "active"),
                )
            elif action == PlayerAction.ATTACH_ENERGY:
                result = self.tm.perform_action(
                    PlayerAction.ATTACH_ENERGY,
                    player_idx=remote_idx,
                    hand_idx=params.get("hand_idx", 0),
                    target_slot=params.get("target_slot", "active"),
                )
            elif action == PlayerAction.PLAY_TRAINER:
                result = self.tm.perform_action(
                    PlayerAction.PLAY_TRAINER,
                    player_idx=remote_idx,
                    hand_idx=params.get("hand_idx", 0),
                    target_slot=params.get("target_slot"),
                )
            elif action == PlayerAction.USE_ABILITY:
                result = self.tm.perform_action(
                    PlayerAction.USE_ABILITY,
                    player_idx=remote_idx,
                    slot=params.get("slot", "active"),
                    ability_name=params.get("ability_name", ""),
                )
            elif action == PlayerAction.USE_STADIUM:
                result = self.tm.perform_action(
                    PlayerAction.USE_STADIUM,
                    player_idx=remote_idx,
                )
            else:
                return

            self._show_result(result, attacker_player_idx=remote_idx, action=action)

            if action == PlayerAction.PLAY_TRAINER and result.success and result.pending_action:
                self._pending_trainer_card = result.pending_action.pending_card
            elif action == PlayerAction.PLAY_TRAINER and not result.pending_action:
                self._pending_trainer_card = None

            if result.success and action == PlayerAction.END_TURN:
                self._handle_turn_end()
            self._clear_selection()
            if result.success:
                if self.state.phase == TurnPhase.SETUP:
                    self._refresh_interaction_controls()
                elif action == PlayerAction.DECLARE_ATTACK:
                    self._waiting_remote = self.state.active_player_idx != self.my_player_idx
                    self._build_action_buttons()
                self._detect_field_changes(prev_snap)

        elif msg_type == MSG_CHOICE_RESPONSE:
            if not self._is_remote_host:
                return
            self._resolve_remote_pending(msg)

        elif msg_type == "game_over":
            self.state.winner = msg.get("winner")
            self.state.phase = TurnPhase.GAME_OVER
            self._show_end_screen(custom_reason=msg.get("reason"))

        elif msg_type == "opponent_disconnected":
            self.state._log("对手断开连接！")
            self._waiting_remote = False
            from ui.screens.title_screen import TitleScreen
            self.manager.clear_to(TitleScreen(self.manager))

        elif msg_type == "connection_failed":
            self.state._log(f"连接失败: {msg.get('error', '未知错误')}")
            from ui.screens.title_screen import TitleScreen
            self.manager.clear_to(TitleScreen(self.manager))

        elif msg_type == "error":
            self.state._log(msg.get("message", "联机协议错误。"))

    def _remote_setup_done(self, player_idx: int):
        if not self._is_remote_host:
            return
        player = self.state.get_player(player_idx)
        if player.active is None:
            return

        self.setup_pass_done[player_idx] = True
        self.state._log(f"玩家{player_idx + 1}准备好了。")

        if self.setup_pass_done[0] and self.setup_pass_done[1]:
            result = self.tm.setup_finalize()
            if result.success:
                self.state._log(result.log_message)
                self._refresh_interaction_controls()
                self._waiting_remote = self.state.active_player_idx != self.my_player_idx
                self._broadcast_state()
        else:
            other = 1 - player_idx
            self.setup_player_idx = other
            self._clear_selection()
            self._refresh_interaction_controls()
            self._waiting_remote = False
            self._broadcast_state()

    def _resolve_remote_pending(self, msg: dict):
        if not self._pending_remote_action:
            return
        pending = self._pending_remote_action
        expected_request_id = getattr(pending, "request_id", "")
        if expected_request_id and msg.get("request_id") not in ("", None, expected_request_id):
            self.state._log("忽略过期的远程选择响应。")
            return
        self._pending_remote_action = None

        if msg.get("cancelled"):
            if self._pending_trainer_card:
                player = self.state.get_player(pending.player)
                card = self._pending_trainer_card
                player.hand.append(card)
                if card.is_trainer_supporter:
                    player.supporter_played_this_turn = False
                self._pending_trainer_card = None
                self._animating_action = False
                self._animating_hand_idx = None
                self.state._log("对手取消了操作，卡牌返回手牌。")
            self._broadcast_state()
            return

        def resolve(payload):
            structured = self.game_engine.choice_request(self.state, pending)
            response = self.game_engine.choice_response_from_legacy(
                structured,
                payload,
            )
            step = self.game_engine.apply_choice(self.state, structured, response)
            return step.action_result

        if pending.request_type in ("search_deck", "select_hand_to_discard"):
            selected = msg.get("selected_indices", [])
            card_list_len = len(pending.card_list)
            # Validate selection count and bounds
            min_sel = getattr(pending, 'min_select', 0)
            max_sel = getattr(pending, 'max_select', 1)
            valid_selected = [i for i in selected if isinstance(i, int) and 0 <= i < card_list_len]
            if len(valid_selected) != len(selected):
                self.state._log("警告：远程选择包含无效索引。")
            if len(valid_selected) < min_sel:
                self.state._log(f"警告：远程选择不足，需要至少{min_sel}项。")
                self._broadcast_state()
                return
            if len(valid_selected) > max_sel:
                valid_selected = valid_selected[:max_sel]
            cards = [pending.card_list[i] for i in valid_selected]
            from data.card_registry import CardRegistry
            card_objects = [CardRegistry.get(c) if isinstance(c, str) else c for c in cards]
            result = resolve(card_objects)
            self._handle_remote_resolve_result(result, pending)
        elif pending.request_type in ("select_bench", "select_opponent_bench", "select_own_bench_energy"):
            selected = msg.get("selected_bench_slot", 0)
            # Validate bench slot is a valid integer
            if not isinstance(selected, int) or selected < 0:
                self.state._log("警告：远程选择了无效的备战区位置。")
                self._broadcast_state()
                return
            bench_indices = getattr(pending, 'bench_indices', [])
            if bench_indices and selected not in bench_indices:
                self.state._log("警告：远程选择了不允许的备战区位置。")
                self._broadcast_state()
                return
            result = resolve(selected)
            self._handle_remote_resolve_result(result, pending)
        elif pending.request_type == "coin_flip":
            # Use host-generated results (server authority), ignore client input
            host_results = getattr(pending, '_host_coin_results', None)
            if host_results:
                result = resolve(list(host_results))
            else:
                # Fallback: validate client results
                results = msg.get("coin_results", [])
                if not isinstance(results, list) or not all(isinstance(r, bool) for r in results):
                    self.state._log("警告：远程硬币结果格式无效。")
                    self._broadcast_state()
                    return
                result = resolve(results)
            self._handle_remote_resolve_result(result, pending)
        elif pending.request_type == "select_bench_targets":
            selected = msg.get("selected_bench_targets", [])
            max_sel = getattr(pending, 'max_select', 1)
            # Validate: must be ints, within allowed bench_indices, no duplicates unless allowed
            if not isinstance(selected, list):
                self.state._log("警告：远程备战目标格式无效。")
                self._broadcast_state()
                return
            valid_targets = [t for t in selected if isinstance(t, int) and t >= 0]
            allowed = getattr(pending, 'bench_indices', [])
            if allowed:
                valid_targets = [t for t in valid_targets if t in allowed]
            if not getattr(pending, 'allow_duplicates', False):
                seen = set()
                valid_targets = [t for t in valid_targets if t not in seen and not seen.add(t)]
            valid_targets = valid_targets[:max_sel]
            result = resolve(valid_targets)
            self._handle_remote_resolve_result(result, pending)
        elif pending.request_type == "confirm":
            result = resolve(bool(msg.get("confirmed", False)))
            self._handle_remote_resolve_result(result, pending)
        elif pending.request_type == "distribute_energy":
            assignments = msg.get("assignments", [])
            max_per = getattr(pending, 'max_per_target', 99)
            # Validate: each assignment should be a valid (energy_idx, target_slot) pair
            if not isinstance(assignments, list):
                self.state._log("警告：远程能量分配格式无效。")
                self._broadcast_state()
                return
            valid_assignments = []
            energy_count = len(pending.card_list)
            target_slots = set(t["slot"] for t in getattr(pending, 'target_info', []))
            for a in assignments:
                if not isinstance(a, (list, tuple)) or len(a) != 2:
                    continue
                ei, tgt = a
                if not isinstance(ei, int) or ei < 0 or ei >= energy_count:
                    continue
                if tgt not in target_slots:
                    continue
                valid_assignments.append([ei, tgt])
            if len(valid_assignments) > energy_count:
                valid_assignments = valid_assignments[:energy_count]
            result = resolve(valid_assignments)
            self._handle_remote_resolve_result(result, pending)

    def _handle_remote_resolve_result(self, result, pending):
        if result is None:
            if self._pending_trainer_card:
                player = self.state.get_player(pending.player)
                player.discard.append(self._pending_trainer_card)
                self._pending_trainer_card = None
                self._animating_action = False
                self._animating_hand_idx = None
            self._broadcast_state()
            return

        from engine.game_state import ActionRequest as AR

        chain_pending = None
        if isinstance(result, AR):
            chain_pending = result
        elif hasattr(result, "pending_action") and result.pending_action:
            chain_pending = result.pending_action

        if chain_pending:
            self._pending_remote_action = chain_pending
            self._broadcast_update(pending_action=chain_pending)
            return

        if self._pending_trainer_card:
            player = self.state.get_player(pending.player)
            player.discard.append(self._pending_trainer_card)
            self._pending_trainer_card = None
            self._animating_action = False
            self._animating_hand_idx = None

        self._show_result(result)
