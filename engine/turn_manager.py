"""Turn manager - phase state machine for the game."""
from engine.enums import TurnPhase, PlayerAction
from engine.game_state import GameState, ActionResult, ActionRequest
from engine.action_resolver import ActionResolver
from engine.rules_validator import check_win_condition


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
            self._handle_setup_phase()
        elif current == TurnPhase.DRAW:
            self._handle_draw_phase()
        elif current == TurnPhase.POKEMON_CHECKUP:
            self._handle_checkup_phase()

    def _handle_setup_phase(self):
        """Setup phase: mulligans, place basics, set prizes."""
        # Check both players have placed basics and set prizes
        if self.state.p1.active is None or self.state.p2.active is None:
            # Need to prompt for active placement
            return

        if not self.state.p1.prizes or not self.state.p2.prizes:
            self.state.set_prizes()

        self.setup_complete = True
        # Move to first turn - draw and then main
        self.state.active_player_idx = self.state.first_player_idx
        self.state.phase = TurnPhase.DRAW
        self.state._log(f"准备完成。{self.state.get_active_player().name}的第1回合开始。")
        self._handle_draw_phase()

    def _handle_draw_phase(self):
        """Draw phase: active player draws 1 card.
        Per official PTCG rules, the player who goes first does NOT draw on
        their first turn. The second player draws normally on their first turn."""
        player = self.state.get_active_player()

        if self.state.is_first_turn():
            self.state._log(f"{player.name}先攻第一回合不抽卡。（第1回合）")
        else:
            drawn = player.draw_cards(1)
            if not drawn:
                opponent_idx = 1 - self.state.active_player_idx
                self.state.winner = opponent_idx
                self.state.phase = TurnPhase.GAME_OVER
                self.state._log(f"{player.name}没有卡可抽了！"
                                f"{self.state.get_player(opponent_idx).name}获胜！")
                return
            self.state._log(f"{player.name}抽了1张卡。（第{self.state.turn_number}回合）")

        self.state.phase = TurnPhase.MAIN

    def _handle_checkup_phase(self):
        """Pokemon Checkup: status conditions, KO checks between turns."""
        self.resolver.resolve_checkup()

        # Check win after checkup
        if self.state.phase == TurnPhase.GAME_OVER:
            return

        # Clear attack locks. The outgoing player (whose turn just ended):
        # - attack_locked (bool): set by opponent, prevented attacks this turn.
        #   It served its purpose — clear it now.
        # - attack_locked_names (dict): self-imposed per-attack locks (e.g.
        #   岩窟冲撞). These must persist through the opponent's turn AND the
        #   player's own next turn, so only clear entries applied 2+ turns ago.
        outgoing = self.state.get_active_player()
        for _, poke in outgoing.get_all_pokemon():
            if poke:
                poke.attack_locked = False
                expired = [n for n, t in poke.attack_locked_names.items()
                           if self.state.turn_number >= t + 2]
                for name in expired:
                    del poke.attack_locked_names[name]

        # Switch active player for next turn
        self.state.active_player_idx = 1 - self.state.active_player_idx
        self.state.turn_number += 1

        # Reset turn flags
        self.state.get_active_player().reset_turn_flags()

        # If the new active player has no active Pokemon, pause before draw
        # so they can promote from bench first
        player = self.state.get_active_player()
        self.state.phase = TurnPhase.DRAW
        self.state._log(f"—— {player.name}的回合 ——")
        if player.active is None and self.state.pending_promotion_player >= 0:
            # Pause: promotion needed before draw
            return
        self._handle_draw_phase()

    # ---- Action Handling ----

    def perform_action(self, action: PlayerAction, player_idx: int,
                       **params) -> ActionResult:
        """Validate and execute a player action."""
        # During non-setup phases, only the active player may act
        if self.state.phase != TurnPhase.SETUP:
            if player_idx != self.state.active_player_idx:
                return ActionResult(False, "不是你的回合。")

        # During setup, only PLAY_BASIC is allowed
        if self.state.phase == TurnPhase.SETUP and action != PlayerAction.PLAY_BASIC:
            return ActionResult(False, "Only place Basics during Setup.")

        result = self.resolver.resolve(action, player_idx=player_idx, **params)

        # After attack, stay in ATTACK phase until player clicks End Turn.
        # A final KO may already have moved the game to GAME_OVER.
        if action == PlayerAction.DECLARE_ATTACK and result.success:
            if self.state.winner is None and self.state.phase != TurnPhase.GAME_OVER:
                self.state.phase = TurnPhase.ATTACK

        elif action == PlayerAction.END_TURN and result.success:
            if self.state.phase in (TurnPhase.MAIN, TurnPhase.ATTACK):
                self.state.phase = TurnPhase.POKEMON_CHECKUP
                self.advance_phase()

        return result

    def continue_after_promotion(self):
        """Called by UI after bench promotion is complete.
        Turn has already switched — just draw and go to MAIN."""
        self.state.pending_promotion_player = -1
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
        """Finalize setup: set prizes and start the game."""
        if self.state.p1.active is None or self.state.p2.active is None:
            return ActionResult(False, "Both players must place Active Pokemon.")
        # Guard: only set prizes once (may already be set by _handle_setup_phase)
        if not self.state.p1.prizes or not self.state.p2.prizes:
            self.state.set_prizes()
        self.advance_phase()
        return ActionResult(True, "Setup complete. Game begins!")

    # ---- Status queries ----

    def needs_mulligan(self, player_idx: int) -> bool:
        """Check if a player needs to mulligan."""
        player = self.state.get_player(player_idx)
        return not any(c.is_basic_pokemon for c in player.hand)

    def get_available_actions(self, player_idx: int) -> list[PlayerAction]:
        """Get list of currently available actions for a player."""
        available = []

        if self.state.phase == TurnPhase.SETUP:
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
