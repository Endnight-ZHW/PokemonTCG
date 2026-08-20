"""Read/query game-state projection populated by ``ptcg_core``."""
import copy
from typing import Optional, Any
from engine.enums import TurnPhase
from engine.player_state import PlayerState
from engine.rules_constants import PRIZE_CARDS

class GameState:
    """Master game state tracking both players and turn flow."""

    def __init__(self):
        self.p1: PlayerState = PlayerState("玩家1")
        self.p2: PlayerState = PlayerState("玩家2")
        self.active_player_idx: int = 0  # 0 = p1, 1 = p2
        self.phase: TurnPhase = TurnPhase.SETUP
        self.turn_number: int = 0
        self.first_player_idx: int = 0
        self.stadium_card: Optional["Card"] = None
        self.stadium_owner_idx: int = -1
        self.winner: Optional[int] = None
        self.result_status: str = "ONGOING"
        self.result_reason: str = "NONE"
        self.result_conditions: list[list[str]] = [[], []]
        self.rules_profile_id: str = "CN_MAINLAND_3_1_0"
        self.rules_options: dict[str, Any] = {"apply_type_matchups": False}
        self.rules_options_locked: bool = False
        self.setup_stage: str = "TURN_ORDER"
        self.setup_actor_idx: int = -1
        self.opening_coin_winner_idx: int = -1
        self.mulligan_bonus_max: tuple[int, int] = (0, 0)
        self.setup_initial_done: tuple[bool, bool] = (False, False)
        self.setup_bonus_draw_done: tuple[bool, bool] = (False, False)
        self.setup_bonus_placement_done: tuple[bool, bool] = (False, False)
        self.setup_bonus_draw_count: tuple[int, int] = (0, 0)
        # Private setup-only identities.  These belong in authoritative
        # snapshots but never in a player-facing observation.
        self.setup_bonus_card_ids: tuple[list[str], list[str]] = ([], [])
        self.starting_prize_count: int = PRIZE_CARDS
        self.revision: int = 0
        self.choice_sequence: int = 0
        # Deck identities are public when the surrounding game mode explicitly
        # records both selections (local debug, challenge, or training). Search
        # may use these keys as priors, but must never inspect hidden-zone card
        # identities.
        self.public_deck_keys: tuple[str | None, str | None] = (None, None)
        self.apply_type_matchups: bool = False
        self.action_log: list[str] = []
        self.mulligan_count: tuple[int, int] = (0, 0)  # (p1_mulligans, p2_mulligans)
        self.extra_draws: tuple[int, int] = (0, 0)  # Extra draws from opponent mulligans
        # Immutable history facts used by "during your opponent's previous
        # turn" card text.  Entries are appended only after a KO is confirmed.
        self.turn_knockout_facts: list[dict[str, Any]] = []
        self.turn_fact_book: dict[str, Any] = {
            "version": 1,
            "current": {
                "turn_number": 0,
                "turn_player": None,
                "knockouts": [],
            },
            "previous": {
                "turn_number": -1,
                "turn_player": None,
                "knockouts": [],
            },
        }
        self.pending_promotions: list[int] = []  # Queue of player_idx who need to promote a bench Pokemon (supports simultaneous KOs)
        self.resolution_stack: dict[str, Any] = {
            "frames": [],
            "pending_request": None,
            "sequence": 0,
            "context": {},
        }
        self._ko_from_attack: bool = False  # Flag set when a KO is from attack damage
        self._mulligan_bonus_given: set[int] = set()
        self.random_source = None
        self._native_processed_action_ids: list[str] = []
        self._native_rng_state: int = 0x6D2B79F5

    def previous_opponent_turn_knockouts(
        self,
        player_idx: int,
        *,
        causes: set[str] | frozenset[str] | None = None,
    ) -> tuple[dict[str, Any], ...]:
        """Return a read-only view of KOs from this player's last opponent turn."""
        if player_idx not in (0, 1):
            return ()
        previous = self.turn_fact_book.get("previous", {})
        if not isinstance(previous, dict) or previous.get("turn_player") != 1 - player_idx:
            return ()
        allowed = {str(cause) for cause in causes} if causes is not None else None
        return tuple(
            copy.deepcopy(fact)
            for fact in list(previous.get("knockouts", []) or [])
            if isinstance(fact, dict)
            and int(fact.get("owner", -1)) == player_idx
            and (
                fact.get("source_player") is None
                or int(fact.get("source_player", -1)) >= 0
            )
            and (allowed is None or str(fact.get("cause", "")) in allowed)
        )

    def had_knockout_last_opponent_turn(
        self,
        player_idx: int,
        *,
        causes: set[str] | frozenset[str] | None = None,
    ) -> bool:
        facts = self.previous_opponent_turn_knockouts(player_idx, causes=causes)
        if facts:
            return True
        # Hand-built AI/test projections may omit a previous fact window. The
        # projected summary flags remain a read-only fallback in that case.
        previous = self.turn_fact_book.get("previous", {})
        if isinstance(previous, dict) and previous.get("turn_player") is None:
            player = self.get_player(player_idx)
            if causes is not None and {str(cause) for cause in causes} == {"attack_damage"}:
                return bool(player.was_ko_by_attack)
            if causes is None:
                return bool(player.was_ko_last_turn or player.was_ko_by_attack)
        return False

    def get_player(self, idx: int) -> PlayerState:
        if type(idx) is not int:
            raise ValueError(f"Invalid player index: {idx!r}")
        if idx == 0:
            return self.p1
        if idx == 1:
            return self.p2
        raise ValueError(f"Invalid player index: {idx!r}")

    def is_terminal(self) -> bool:
        """Return whether the authoritative result has ended the game.

        A draw deliberately keeps ``winner == -1``.  Callers must therefore
        not use winner truthiness as a terminal-state test.
        """
        return self.result_status in {"WIN", "DRAW"} or self.phase == TurnPhase.GAME_OVER

    def set_result(
        self,
        status: str,
        *,
        winner: int = -1,
        reason: str = "RULE_CONDITIONS",
        conditions: list[list[str]] | None = None,
    ) -> None:
        """Commit one normalized terminal result."""
        normalized = str(status or "").upper()
        if normalized not in {"WIN", "DRAW"}:
            raise ValueError(f"Invalid terminal result status: {status!r}")
        if normalized == "WIN" and winner not in (0, 1):
            raise ValueError("A win must identify player 0 or 1.")
        if normalized == "DRAW":
            winner = -1
        self.result_status = normalized
        self.winner = int(winner)
        self.result_reason = str(reason or "RULE_CONDITIONS")
        self.result_conditions = (
            [list(row) for row in conditions]
            if conditions is not None
            else [[], []]
        )
        self.phase = TurnPhase.GAME_OVER
