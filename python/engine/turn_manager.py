"""Turn manager - phase state machine for the game."""
from engine.enums import TurnPhase, PlayerAction
from engine.game_state import GameState, ActionResult, ActionRequest
from engine.action_resolver import ActionResolver
from engine.rules_validator import check_win_condition


FINISH_CHECKUP_AFTER_PROMOTIONS_KEY = "finish_checkup_after_promotions"


def _resolution_stack_context(state: GameState) -> dict:
    stack = getattr(state, "resolution_stack", None)
    if not isinstance(stack, dict):
        stack = {}
        state.resolution_stack = stack
    context = stack.get("context")
    if not isinstance(context, dict):
        context = {}
        stack["context"] = context
    return context


def set_finish_checkup_after_promotions(state: GameState, actor: int) -> None:
    _resolution_stack_context(state)[FINISH_CHECKUP_AFTER_PROMOTIONS_KEY] = int(actor)


def finish_checkup_after_promotions_actor(state: GameState) -> int | None:
    value = _resolution_stack_context(state).get(FINISH_CHECKUP_AFTER_PROMOTIONS_KEY)
    return int(value) if type(value) is int and value in (0, 1) else None


def clear_finish_checkup_after_promotions(state: GameState) -> None:
    _resolution_stack_context(state).pop(FINISH_CHECKUP_AFTER_PROMOTIONS_KEY, None)


class TurnManager:
    """Manages turn phases and action validation/execution."""

    def __init__(self, state: GameState):
        self.state = state
        self.resolver = ActionResolver(state)
        self.setup_complete: bool = False

    # ---- Phase Management ----

    def advance_phase(self):
        """Progress to the next phase, handling auto-resolutions.

        Called after END_TURN (phase already set to POKEMON_CHECKUP by
        perform_action) and from setup_finalize (phase is SETUP).
        """
        current = self.state.phase

        if current == TurnPhase.SETUP:
            return self._handle_setup_phase()
        elif current == TurnPhase.DRAW:
            return self._handle_draw_phase()
        elif current == TurnPhase.POKEMON_CHECKUP:
            return self._handle_checkup_phase()
        return None

    def _handle_setup_phase(self):
        """Setup progresses only through explicit player actions/choices."""
        self.setup_complete = self.state.setup_stage == "COMPLETE"

    def _handle_draw_phase(self):
        """Draw one card, including on the first player's first turn."""
        player = self.state.get_active_player()

        drawn = player.draw_cards(1)
        if not drawn:
            opponent_idx = 1 - self.state.active_player_idx
            conditions = [[], []]
            conditions[opponent_idx] = ["OPPONENT_CANNOT_DRAW"]
            self.state.set_result(
                "WIN",
                winner=opponent_idx,
                reason="RULE_CONDITIONS",
                conditions=conditions,
            )
            self.state._log(f"{player.name}没有卡可抽了！"
                            f"{self.state.get_player(opponent_idx).name}获胜！")
            return
        self.state._log(f"{player.name}抽了1张卡。（第{self.state.turn_number}回合）")

        self.state.phase = TurnPhase.MAIN

    def _handle_checkup_phase(self) -> ActionResult:
        """Pokemon Checkup: status conditions, KO checks between turns."""
        _rows, settlement = self.resolver.resolve_checkup()
        # The serialized FinalizeCheckupTurn frame is part of the same stack,
        # so a prize/trigger pause cannot advance the turn early or lose the
        # eventual transition after snapshot recovery.
        return settlement

    def finish_checkup_after_settlement(self, outgoing_actor: int) -> ActionResult:
        """Wait for required promotions, then begin and draw the next turn."""
        if self.state.is_terminal():
            clear_finish_checkup_after_promotions(self.state)
            return ActionResult(True, "")
        if (
            outgoing_actor not in (0, 1)
            or self.state.phase != TurnPhase.POKEMON_CHECKUP
            or self.state.active_player_idx != outgoing_actor
        ):
            return ActionResult(False, "宝可梦检查结算状态无效。")
        if self.state.pending_promotions:
            set_finish_checkup_after_promotions(self.state, outgoing_actor)
            return ActionResult(True, "等待双方完成晋升。")

        clear_finish_checkup_after_promotions(self.state)
        self._complete_checkup_transition()
        return ActionResult(True, "宝可梦检查结算完毕。")

    def _complete_checkup_transition(self) -> None:
        """Begin the incoming turn only after the entire checkup batch."""

        # Clear attack locks. The outgoing player (whose turn just ended):
        # - attack_locked (bool): set by opponent, prevented attacks this turn.
        #   It served its purpose — clear it now.
        # - attack_locked_names (dict): self-imposed per-attack locks (e.g.
        #   岩窟冲撞). These must persist through the opponent's turn AND the
        #   player's own next turn, so only clear entries applied 2+ turns ago.
        outgoing = self.state.get_active_player()
        for _, poke in outgoing.get_all_pokemon():
            if poke:
                poke.outgoing_damage_reduction_next_turn = 0
                poke.dazzled = False
                poke.attack_locked = False
                expired = [n for n, t in poke.attack_locked_names.items()
                           if self.state.turn_number >= t + 2]
                for name in expired:
                    del poke.attack_locked_names[name]
        # Switch active player for next turn
        self.state.active_player_idx = 1 - self.state.active_player_idx
        self.state.turn_number += 1
        self.state.begin_turn_fact_window(
            self.state.active_player_idx,
            self.state.turn_number,
        )

        # Reset turn flags
        self.state.get_active_player().reset_turn_flags()

        # Any checkup KO must be promoted before the next turn draws.  The
        # outgoing player can be KO'd by Poison/Burn even when the incoming
        # player still has an Active Pokemon.
        player = self.state.get_active_player()
        self.state.phase = TurnPhase.DRAW
        self.state._log(f"—— {player.name}的回合 ——")
        self._handle_draw_phase()

    # ---- Action Handling ----

    def perform_action(
        self,
        action: PlayerAction,
        player_idx: int,
        *,
        finish_attack_in_stack: bool = False,
        bump_revision: bool = True,
        **params,
    ) -> ActionResult:
        """Validate and execute a player action."""
        # During non-setup phases, only the active player may act
        if self.state.phase != TurnPhase.SETUP:
            if player_idx != self.state.active_player_idx:
                return ActionResult(False, "不是你的回合。")

        # During setup, placement actions belong to the current setup actor.
        if (
            self.state.phase == TurnPhase.SETUP
            and player_idx != int(getattr(self.state, "setup_actor_idx", -1))
        ):
            return ActionResult(False, "尚未轮到该玩家进行开局放置。")
        if self.state.phase == TurnPhase.SETUP and action != PlayerAction.PLAY_BASIC:
            return ActionResult(False, "Only place Basics during Setup.")

        result = self.resolver.resolve(
            action,
            player_idx=player_idx,
            finish_attack_in_stack=finish_attack_in_stack,
            **params,
        )
        if result.success and bump_revision:
            self.state.revision = getattr(self.state, "revision", 0) + 1

        # TurnManager is still a public execution boundary for the legacy UI,
        # simulations, and a number of rule tests.  Refresh promotion requests
        # after a completed effect can voluntarily remove its own Active
        # Pokemon.  Actual KO triggers, prizes, and terminal checks stay in the
        # transaction settlement layer so failures can still roll back cleanly.
        if (
            result.success
            and result.pending_action is None
            and self.state.phase != TurnPhase.SETUP
            and action not in (PlayerAction.DECLARE_ATTACK, PlayerAction.END_TURN)
        ):
            from engine.commands.attack_frames import refresh_pending_promotions

            refresh_pending_promotions(self.state)

        # After attack, stay in ATTACK phase until player clicks End Turn.
        # A final KO may already have moved the game to GAME_OVER.
        if action == PlayerAction.DECLARE_ATTACK and result.success:
            if (
                not self.state.is_terminal()
                and self.state.phase == TurnPhase.MAIN
                and self.state.active_player_idx == player_idx
            ):
                self.state.phase = TurnPhase.ATTACK

        elif action == PlayerAction.END_TURN and result.success:
            if self.state.phase in (TurnPhase.MAIN, TurnPhase.ATTACK):
                self.state.phase = TurnPhase.POKEMON_CHECKUP
                phase_result = self.advance_phase()
                if isinstance(phase_result, ActionResult):
                    from engine.effect_runner import merge_action_results

                    merge_action_results(result, phase_result)

        return result

    def continue_after_promotion(self):
        """Called by UI after bench promotion is complete.
        Pops the completed promotion and continues if more are pending."""
        self.state.pop_pending_promotion()  # Remove the just-completed promotion
        # If another player still needs to promote, pause again
        if self.state.pending_promotions:
            return
        self._handle_draw_phase()

    def declare_attack(self, player_idx: int, attack_idx: int) -> ActionResult:
        """Shortcut for declaring an attack."""
        return self.perform_action(
            PlayerAction.DECLARE_ATTACK,
            player_idx=player_idx,
            attack_idx=attack_idx
        )

    # ---- Setup Helpers ----

    def setup_place_basic(self, player_idx: int, hand_idx: int,
                          target: str) -> ActionResult:
        """Place a Basic during setup."""
        if self.state.phase != TurnPhase.SETUP:
            return ActionResult(False, "Not in setup phase.")
        return self.perform_action(
            PlayerAction.PLAY_BASIC,
            player_idx=player_idx,
            hand_idx=hand_idx,
            target=target,
        )

    def setup_finalize(self):
        """Compatibility query; official setup cannot be force-finalized."""
        if self.state.setup_stage != "COMPLETE":
            return ActionResult(False, "必须依次完成开局放置与再战奖励选择。")
        return ActionResult(True, "Setup complete. Game begins!")

    def setup_done(self, player_idx: int) -> ActionResult:
        """Commit the current player's initial/bonus placement."""
        if self.state.phase != TurnPhase.SETUP:
            return ActionResult(False, "当前不在开局阶段。")
        if player_idx != int(getattr(self.state, "setup_actor_idx", -1)):
            return ActionResult(False, "尚未轮到该玩家完成开局放置。")

        stage = str(getattr(self.state, "setup_stage", ""))
        if stage == "INITIAL_PLACEMENT":
            player = self.state.get_player(player_idx)
            if player.active is None:
                return ActionResult(False, "必须先放置战斗宝可梦。")
            done = list(self.state.setup_initial_done)
            if done[player_idx]:
                return ActionResult(False, "该玩家已完成初始放置。")
            done[player_idx] = True
            self.state.setup_initial_done = tuple(done)
            self.state.revision = getattr(self.state, "revision", 0) + 1

            other = 1 - player_idx
            if not done[other]:
                self.state.setup_actor_idx = other
                return ActionResult(True, "初始放置完成，交由另一位玩家放置。")

            from engine.commands.setup_continuations import finish_initial_placement

            try:
                pending = finish_initial_placement(self.state)
            except ValueError as exc:
                return ActionResult(False, str(exc))
            return ActionResult(
                True,
                "双方初始放置完成并设置奖赏卡。",
                pending_action=pending,
            )

        if stage == "BONUS_PLACEMENT":
            from engine.commands.setup_continuations import finish_bonus_placement

            try:
                pending = finish_bonus_placement(self.state, player_idx)
            except ValueError as exc:
                return ActionResult(False, str(exc))
            self.state.revision = getattr(self.state, "revision", 0) + 1
            return ActionResult(
                True,
                "再战奖励宝可梦放置完成。",
                pending_action=pending,
            )

        return ActionResult(False, "当前阶段不能结束放置。")

    # ---- Status queries ----

    def needs_mulligan(self, player_idx: int) -> bool:
        """Check if a player needs to mulligan."""
        player = self.state.get_player(player_idx)
        return not any(c.is_basic_pokemon for c in player.hand)

    def get_available_actions(self, player_idx: int) -> list[PlayerAction]:
        """Get list of currently available actions for a player."""
        available = []

        if self.state.phase == TurnPhase.SETUP:
            if player_idx == int(getattr(self.state, "setup_actor_idx", -1)):
                available.append(PlayerAction.PLAY_BASIC)
            return available

        if self.state.phase == TurnPhase.MAIN:
            available.append(PlayerAction.PLAY_BASIC)
            available.append(PlayerAction.EVOLVE)
            available.append(PlayerAction.ATTACH_ENERGY)
            available.append(PlayerAction.PLAY_TRAINER)
            available.append(PlayerAction.USE_ABILITY)
            available.append(PlayerAction.RETREAT)
            available.append(PlayerAction.DECLARE_ATTACK)
            available.append(PlayerAction.END_TURN)

        elif self.state.phase == TurnPhase.ATTACK:
            available.append(PlayerAction.END_TURN)

        return available

    @property
    def current_player_idx(self) -> int:
        return self.state.active_player_idx
