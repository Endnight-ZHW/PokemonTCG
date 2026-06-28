"""Game enumerations: turn phases, status types, action types, events."""
from enum import Enum, auto


class TurnPhase(Enum):
    SETUP = auto()            # Initial mulligan, place basics, set prizes
    DRAW = auto()             # Draw 1 card for turn
    MAIN = auto()             # Play cards, evolve, attach energy, use abilities
    ATTACK = auto()           # Declare attack, resolve effects
    POKEMON_CHECKUP = auto()  # Between turns: status checks, KO checks
    GAME_OVER = auto()


class StatusType(Enum):
    POISONED = auto()   # 1 damage counter per checkup, persists
    BURNED = auto()     # 2 damage counters per checkup, coin flip to cure
    ASLEEP = auto()     # Cannot attack/retreat, coin flip between turns to wake
    PARALYZED = auto()  # Cannot attack/retreat, auto-cures at next checkup
    CONFUSED = auto()   # Coin flip on attack: tails = 3 counters on self + attack fails


class PlayerAction(Enum):
    PLAY_BASIC = auto()       # Hand -> bench/active
    EVOLVE = auto()           # Hand -> bench/active pokemon
    ATTACH_ENERGY = auto()    # Hand -> pokemon
    PLAY_TRAINER = auto()     # Item, Supporter, Stadium, Tool
    USE_ABILITY = auto()      # Activate an ability
    USE_STADIUM = auto()      # Activate stadium card effect
    RETREAT = auto()          # Pay retreat cost, swap active with bench
    DECLARE_ATTACK = auto()   # Pick and attack with active Pokemon
    END_TURN = auto()         # Skip attack (if in MAIN), end turn


class EventType(Enum):
    GAME_START = auto()
    TURN_START = auto()
    TURN_END = auto()
    CARD_PLAYED = auto()
    POKEMON_PLACED = auto()
    POKEMON_EVOLVED = auto()
    ENERGY_ATTACHED = auto()
    BEFORE_ATTACK = auto()
    AFTER_ATTACK = auto()
    DAMAGE_ABOUT_TO_BE_DEALT = auto()
    DAMAGE_DEALT = auto()
    CAN_RETREAT = auto()
    POKEMON_KO = auto()
    CHECKUP_START = auto()
    RETREAT = auto()
    ON_ENTER_PLAY = auto()
    ON_KO = auto()
