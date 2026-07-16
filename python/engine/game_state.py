"""GameState - central state management for both players."""
import copy
import random
from dataclasses import dataclass, field
from typing import Optional, Callable, Any
from utils.logger import get_logger

logger = get_logger(__name__)
from engine.enums import TurnPhase, EventType, PlayerAction
from engine.player_state import PlayerState, PokemonInPlay
from engine.events.game_events import GameEventStream
from engine.rules_constants import COIN_FLIP_THRESHOLD, HAND_SIZE_INITIAL, PRIZE_CARDS, MAX_BENCH_SIZE


@dataclass
class ActionRequest:
    """A pending action requiring UI input (search, choice, etc.)."""
    request_type: str  # "search_deck", "select_hand", "select_bench", "coin_flip"
    player: int  # 0 or 1
    prompt: str
    filter_fn: Optional[Callable] = None
    min_select: int = 1
    max_select: int = 1
    from_zone: str = ""
    callback: Optional[Callable] = None  # Called with selected cards/choices
    card_list: list = field(default_factory=list)  # For showing selectable cards
    target_player: str = ""  # For select_bench_targets: "self" or "opponent"
    bench_indices: list[int] = field(default_factory=list)  # For select_bench_targets: allowed bench slots
    allow_duplicates: bool = False  # For select_bench_targets: allow selecting same slot multiple times
    flip_count: int = 1  # For coin_flip: number of coin flips to animate
    until_tails: bool = False  # For coin_flip: keep flipping until tails appears
    pending_card: Optional["Card"] = None  # Card consumed pending action completion (for cancel-to-return)
    # For distribute_energy screen
    distribute_mode: str = ""  # "distribute" (all energy) or "paired" (select N per target)
    target_info: list = field(default_factory=list)  # For distribute_energy: list of {slot, name, bench_idx}
    max_per_target: int = 99  # For paired mode: max energy per target
    source_name: str = ""  # For distribute_energy: source Pokemon name
    request_id: str = ""  # Stable serialized choice request correlation ID
    can_cancel: bool = False
    continuation: dict[str, Any] = field(default_factory=dict)


@dataclass
class ActionResult:
    """Result of executing a game action."""
    success: bool
    log_message: str = ""
    damage_dealt: int = 0
    cards_drawn: list = field(default_factory=list)
    cards_discarded: int = 0
    pokemon_ko: list[str] = field(default_factory=list)
    status_applied: list[str] = field(default_factory=list)
    prize_taken: bool = False
    pending_action: Optional[ActionRequest] = None
    attack_failed: bool = False  # For 跳一下 type effects where coin flip tails = attack fails


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
        # Ephemeral compatibility bridge for old callback-only requests.  It
        # is intentionally excluded from snapshots; VM continuations rebuild
        # from ``resolution_stack`` instead.
        self._pending_choice_runtime = None
        self._ko_from_attack: bool = False  # Flag set when a KO is from attack damage
        self._mulligan_bonus_given: set[int] = set()
        self.random_source = None
        self.event_stream: GameEventStream = GameEventStream()
        from engine.effects.event_bus import EventBus
        from engine.effects.modifier_manager import ModifierManager
        self.event_bus = EventBus()
        self.modifier_manager = ModifierManager(self.event_bus)

    def record_knockout_fact(
        self,
        *,
        owner: int,
        cause: str,
        source_player: int | None = None,
        card_id: str = "",
        slot: str = "",
    ) -> None:
        """Record a confirmed KO without consuming earlier history facts."""
        fact = {
            "turn_number": int(self.turn_number),
            "turn_player": (
                int(self.active_player_idx)
                if self.active_player_idx in (0, 1)
                else None
            ),
            "owner": int(owner),
            "cause": str(cause or "rule"),
            "source_player": (
                int(source_player) if source_player in (0, 1) else None
            ),
            "card_id": str(card_id or ""),
            "slot": str(slot or ""),
        }
        self.turn_knockout_facts.append(fact)
        current = self.turn_fact_book.get("current", {})
        if not isinstance(current, dict):
            current = {}
        if (
            current.get("turn_number") != int(self.turn_number)
            or current.get("turn_player") != fact["turn_player"]
        ):
            # Manually constructed scenarios may not have called the normal
            # turn boundary yet.  Preserve a non-empty window as previous;
            # otherwise initialize it in place.
            if list(current.get("knockouts", []) or []):
                self.turn_fact_book["previous"] = copy.deepcopy(current)
            current = {
                "turn_number": int(self.turn_number),
                "turn_player": fact["turn_player"],
                "knockouts": [],
            }
            self.turn_fact_book["current"] = current
        current.setdefault("knockouts", []).append(copy.deepcopy(fact))
        # Keep a bounded, snapshot-friendly history.  No released effect needs
        # facts older than the immediately preceding pair of turns.
        if len(self.turn_knockout_facts) > 64:
            del self.turn_knockout_facts[:-64]

    def begin_turn_fact_window(self, player_idx: int, turn_number: int) -> None:
        """Rotate immutable previous-turn facts and open a new turn window."""
        if player_idx not in (0, 1):
            raise ValueError(f"Invalid turn-fact player: {player_idx!r}")
        current = self.turn_fact_book.get("current", {})
        if not isinstance(current, dict):
            current = {}
        # Hand-built/editor states from before TurnFactBook only carry the
        # per-player booleans.  At a boundary, the incoming player's marker
        # describes a KO during the just-finished opponent turn; the outgoing
        # player's older marker expires.  Capture that one-time migration
        # before replacing the compatibility mirrors below.
        legacy_window = current.get("turn_player") not in (0, 1)
        legacy_markers = {
            owner: (
                bool(self.get_player(owner).was_ko_last_turn),
                bool(self.get_player(owner).was_ko_by_attack),
            )
            for owner in (0, 1)
        }
        current_turn = current.get("turn_number", -1)
        current_turn = current_turn if type(current_turn) is int else -1
        if current_turn == int(turn_number) and current.get("turn_player") == player_idx:
            return
        self.turn_fact_book["previous"] = copy.deepcopy({
            "turn_number": int(current_turn),
            "turn_player": current.get("turn_player"),
            "knockouts": list(current.get("knockouts", []) or []),
        })
        self.turn_fact_book["current"] = {
            "turn_number": int(turn_number),
            "turn_player": int(player_idx),
            "knockouts": [],
        }
        # Compatibility booleans mirror (but never consume) TurnFactBook.
        for owner in (0, 1):
            player = self.get_player(owner)
            if legacy_window:
                player.was_ko_last_turn = (
                    legacy_markers[owner][0] if owner == player_idx else False
                )
                player.was_ko_by_attack = (
                    legacy_markers[owner][1] if owner == player_idx else False
                )
            else:
                player.was_ko_last_turn = self.had_knockout_last_opponent_turn(owner)
                player.was_ko_by_attack = self.had_knockout_last_opponent_turn(
                    owner,
                    causes={"attack_damage"},
                )

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
        # Compatibility for old snapshots and hand-built test/editor states
        # which predate TurnFactBook.  Once a real previous window exists it
        # is authoritative and these booleans can never extend/consume it.
        previous = self.turn_fact_book.get("previous", {})
        if isinstance(previous, dict) and previous.get("turn_player") is None:
            player = self.get_player(player_idx)
            if causes is not None and {str(cause) for cause in causes} == {"attack_damage"}:
                return bool(player.was_ko_by_attack)
            if causes is None:
                return bool(player.was_ko_last_turn or player.was_ko_by_attack)
        return False

    def get_active_player(self) -> PlayerState:
        return self.p1 if self.active_player_idx == 0 else self.p2

    def get_opponent(self) -> PlayerState:
        return self.p2 if self.active_player_idx == 0 else self.p1

    @property
    def pending_promotion_player(self) -> int:
        """Backward-compatible accessor — returns the first pending promotion or -1."""
        return self.pending_promotions[0] if self.pending_promotions else -1

    @pending_promotion_player.setter
    def pending_promotion_player(self, value: int):
        """Backward-compatible setter — queues a promotion or clears all."""
        if value < 0:
            self.pending_promotions.clear()
        elif value not in self.pending_promotions:
            self.pending_promotions.append(value)

    def pop_pending_promotion(self) -> int:
        """Pop the next pending promotion from the queue. Returns -1 if empty."""
        return self.pending_promotions.pop(0) if self.pending_promotions else -1

    def get_player(self, idx: int) -> PlayerState:
        if type(idx) is not int:
            raise ValueError(f"Invalid player index: {idx!r}")
        if idx == 0:
            return self.p1
        if idx == 1:
            return self.p2
        raise ValueError(f"Invalid player index: {idx!r}")

    def player_index(self, player: PlayerState) -> int:
        if player is self.p1:
            return 0
        if player is self.p2:
            return 1
        raise ValueError("PlayerState does not belong to this game.")

    def is_first_turn(self) -> bool:
        return self.turn_number == 1

    def is_player_first_turn(self, player_idx: int) -> bool:
        """Return True during the first turn taken by the given player."""
        if player_idx == self.first_player_idx:
            return self.turn_number == 1
        return self.turn_number == 2

    def is_going_second_first_turn(self, player_idx: int) -> bool:
        """Return True during the second player's own first turn."""
        return (
            player_idx != self.first_player_idx
            and player_idx == self.active_player_idx
            and self.is_player_first_turn(player_idx)
        )

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

    def configure_rules(self, *, apply_type_matchups: bool = False) -> None:
        """Set lobby rules before setup; setup locks them for the match."""
        if self.rules_options_locked:
            raise ValueError("规则配置已锁定，开局后不能修改。")
        enabled = bool(apply_type_matchups)
        self.rules_options = {"apply_type_matchups": enabled}
        self.apply_type_matchups = enabled

    # ---- Game Setup ----

    def setup_game(self, deck1: list[str], deck2: list[str], rng=None) -> ActionRequest:
        """Initialize decks and request turn order before either hand is seen.

        The coin winner chooses first/second.  Opening hands, mulligans and
        placement start only after that serialized choice resolves.
        """
        from data.card_registry import CardRegistry

        unknown_ids = sorted({
            str(card_id)
            for card_id in [*deck1, *deck2]
            if CardRegistry.get(str(card_id)) is None
        })
        if unknown_ids:
            raise ValueError(f"卡组包含未知卡牌 ID：{', '.join(unknown_ids)}")

        # Build deck Card objects from IDs
        def build_deck(deck_ids: list[str]) -> list:
            cards = []
            for cid in deck_ids:
                card = CardRegistry.get(cid)
                if card:
                    cards.append(card)
                else:  # guarded above; retained as a defensive invariant
                    raise ValueError(f"卡组包含未知卡牌 ID：{cid}")
            return cards

        self.p1.deck = build_deck(deck1)
        self.p2.deck = build_deck(deck2)

        # Validate both decks
        from engine.rules_validator import validate_deck
        for name, deck_obj in [("玩家1", self.p1.deck), ("玩家2", self.p2.deck)]:
            valid, msg = validate_deck(deck_obj, name)
            if not valid:
                logger.error("Deck validation failed: %s", msg)
                raise ValueError(msg)

        # Shuffle both decks
        if rng is not None:
            rng.shuffle(self.p1.deck)
            rng.shuffle(self.p2.deck)
        else:
            self.p1.shuffle_deck()
            self.p2.shuffle_deck()

        # The option is locked as soon as setup begins.  The opening coin only
        # identifies who chooses; it does not directly determine first player.
        self.rules_options_locked = True
        first_flip = rng.random() if rng is not None else random.random()
        self.opening_coin_winner_idx = (
            0 if first_flip < COIN_FLIP_THRESHOLD else 1
        )
        self.first_player_idx = -1
        self.active_player_idx = self.opening_coin_winner_idx
        self.turn_number = 0
        self.phase = TurnPhase.SETUP
        self.setup_stage = "TURN_ORDER"
        self.setup_actor_idx = self.opening_coin_winner_idx
        self.setup_initial_done = (False, False)
        self.setup_bonus_draw_done = (False, False)
        self.setup_bonus_placement_done = (False, False)
        self.setup_bonus_draw_count = (0, 0)
        self.mulligan_count = (0, 0)
        self.mulligan_bonus_max = (0, 0)
        self.extra_draws = (0, 0)
        self.setup_bonus_card_ids = ([], [])
        self._mulligan_bonus_given.clear()
        self._log(
            f"开局硬币结果已确定：{self.get_player(self.opening_coin_winner_idx).name}"
            "选择先攻或后攻。"
        )

        from engine.commands.setup_continuations import make_turn_order_request

        return make_turn_order_request(self)

    def set_prizes(self):
        """Set prize cards for both players."""
        self.p1.set_prizes(PRIZE_CARDS)
        self.p2.set_prizes(PRIZE_CARDS)
        self._log(f"双方各放置{PRIZE_CARDS}张奖赏卡。")

    def do_mulligan(self, player_idx: int) -> bool:
        """Legacy one-hand redraw helper without awarding an automatic card.

        Official setup uses the simultaneous round resolver in
        ``setup_continuations`` so mutual mulligans cancel and the opponent
        later chooses 0..N bonus cards after prizes are set.
        """
        player = self.get_player(player_idx)

        # Check if player has a Basic Pokemon in hand
        has_basic = any(c.is_basic_pokemon for c in player.hand)
        if has_basic:
            return False

        # Mulligan: shuffle hand back into deck, draw a new starting hand.
        player.deck.extend(player.hand)
        player.hand.clear()
        player.shuffle_deck()
        player.draw_cards(HAND_SIZE_INITIAL)

        counts = list(self.mulligan_count)
        counts[player_idx] += 1
        self.mulligan_count = tuple(counts)
        self._log(f"{player.name}再战！")

        return True

    def can_end_setup(self) -> bool:
        """Check if both players have placed their Active Pokemon."""
        return (
            self.setup_stage == "COMPLETE"
            and self.p1.active is not None
            and self.p2.active is not None
            and bool(self.p1.prizes)
            and bool(self.p2.prizes)
        )

    # ---- Zone Transfers ----

    def discard_pokemon(self, player_idx: int, slot: str):
        """Send a Pokemon and all attached cards to discard."""
        player = self.get_player(player_idx)
        pokemon = player.get_pokemon(slot)
        if pokemon is None:
            return

        # Discard Pokemon card
        player.discard.append(pokemon.card)

        # Discard evolution stack
        for evo_card in pokemon.evolution_stack:
            player.discard.append(evo_card)

        # Discard tool
        if pokemon.attached_tool:
            player.discard.append(pokemon.attached_tool)

        # Discard energy cards
        for ec in pokemon.energy_cards:
            player.discard.append(ec)
        pokemon.energy_cards.clear()

        # Clear the slot
        if slot == "active":
            player.active = None
        elif slot.startswith("bench_"):
            try:
                idx = int(slot.split("_")[1])
            except (ValueError, IndexError):
                return
            if 0 <= idx < MAX_BENCH_SIZE:
                player.bench[idx] = None

    def move_active_to_bench(self, player_idx: int, bench_idx: int):
        """Move Active Pokemon to a bench slot (for retreat / switch effects)."""
        from engine.rules_constants import MAX_BENCH_SIZE
        if bench_idx < 0 or bench_idx >= MAX_BENCH_SIZE:
            return
        player = self.get_player(player_idx)
        if player.active is None or player.bench[bench_idx] is None:
            return
        player.switch_active_to_bench(bench_idx)

    # ---- Logging ----

    def _log(self, message: str):
        self.action_log.append(message)
        if len(self.action_log) > 100:
            self.action_log.pop(0)

    def log_action(self, message: str):
        self._log(message)
