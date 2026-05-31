"""GameState - central state management for both players."""
import random
from dataclasses import dataclass, field
from typing import Optional, Callable
from utils.logger import get_logger

logger = get_logger(__name__)
from engine.enums import TurnPhase, EventType, PlayerAction
from engine.player_state import PlayerState, PokemonInPlay
from engine.events.game_events import GameEventStream


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
    request_id: str = ""  # Network choice request correlation id


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
        self.winner: Optional[int] = None
        self.apply_type_matchups: bool = False
        self.action_log: list[str] = []
        self.mulligan_count: tuple[int, int] = (0, 0)  # (p1_mulligans, p2_mulligans)
        self.extra_draws: tuple[int, int] = (0, 0)  # Extra draws from opponent mulligans
        self.pending_promotion_player: int = -1  # player_idx who needs to promote a bench Pokemon
        self._piercing_attack: bool = False  # Set during attack resolution for piercing effects
        self._ko_from_attack: bool = False  # Flag set when a KO is from attack damage
        self._mulligan_bonus_given: set[int] = set()
        self.event_stream: GameEventStream = GameEventStream()
        from engine.effects.event_bus import EventBus
        self.event_bus = EventBus()

    def get_active_player(self) -> PlayerState:
        return self.p1 if self.active_player_idx == 0 else self.p2

    def get_opponent(self) -> PlayerState:
        return self.p2 if self.active_player_idx == 0 else self.p1

    def get_player(self, idx: int) -> PlayerState:
        return self.p1 if idx == 0 else self.p2

    def is_first_turn(self) -> bool:
        return self.turn_number == 1

    def is_player_first_turn(self, player_idx: int) -> bool:
        """Return True during the first turn taken by the given player."""
        if player_idx == self.first_player_idx:
            return self.turn_number == 1
        return self.turn_number == 2

    # ---- Game Setup ----

    def setup_game(self, deck1: list[str], deck2: list[str]):
        """Initialize both players with their deck lists (card IDs)."""
        from data.card_registry import CardRegistry

        # Build deck Card objects from IDs
        def build_deck(deck_ids: list[str]) -> list:
            cards = []
            for cid in deck_ids:
                card = CardRegistry.get(cid)
                if card:
                    cards.append(card)
                else:
                    logger.warning("card not found: %s", cid)
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
        self.p1.shuffle_deck()
        self.p2.shuffle_deck()

        # Determine first player (coin flip)
        from config import COIN_FLIP_THRESHOLD
        self.first_player_idx = 0 if random.random() < COIN_FLIP_THRESHOLD else 1
        self.active_player_idx = self.first_player_idx
        self.turn_number = 1

        # Deal 7 cards to each player
        self.p1.draw_cards(7)
        self.p2.draw_cards(7)

        self.phase = TurnPhase.SETUP
        self._log(f"游戏开始！{self.get_active_player().name}先攻。")

    def set_prizes(self):
        """Set prize cards for both players."""
        self.p1.set_prizes(6)
        self.p2.set_prizes(6)
        self._log("双方各放置6张奖品卡。")

    def do_mulligan(self, player_idx: int) -> bool:
        """Perform a mulligan for a player. Returns True if mulligan was done."""
        player = self.get_player(player_idx)
        opponent = self.get_player(1 - player_idx)

        # Check if player has a Basic Pokemon in hand
        has_basic = any(c.is_basic_pokemon for c in player.hand)
        if has_basic:
            return False

        # Mulligan: shuffle hand back into deck, draw 7 new cards
        # Opponent gets 1 extra draw only on the first mulligan
        player.deck.extend(player.hand)
        player.hand.clear()
        player.shuffle_deck()
        player.draw_cards(7)

        if player_idx not in self._mulligan_bonus_given:
            opponent.draw_cards(1)
            self._mulligan_bonus_given.add(player_idx)
            self._log(f"{player.name}再战！{opponent.name}多抽1张卡。")
        else:
            self._log(f"{player.name}再战！")

        return True

    def can_end_setup(self) -> bool:
        """Check if both players have placed their Active Pokemon."""
        return (self.p1.active is not None and self.p2.active is not None and
                self.p1.prizes and self.p2.prizes)

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
            idx = int(slot.split("_")[1])
            player.bench[idx] = None

    def move_active_to_bench(self, player_idx: int, bench_idx: int):
        """Move Active Pokemon to a bench slot (for retreat / switch effects)."""
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
