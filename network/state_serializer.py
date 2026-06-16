"""GameState ↔ JSON serialization with per-player hidden-info filtering."""
from typing import Optional
from engine.enums import TurnPhase, StatusType
from engine.game_state import GameState, ActionRequest
from engine.player_state import PlayerState, PokemonInPlay
from data.card_registry import CardRegistry
from utils.logger import get_logger

logger = get_logger(__name__)


def _card_id(card) -> Optional[str]:
    """Get card api_id, or None if card is None."""
    if card is None:
        return None
    return getattr(card, 'api_id', None) or getattr(card, 'id', None)


def _get_card(card_id: str):
    """Reconstruct Card object from api_id."""
    if not card_id:
        return None
    card = CardRegistry.get(card_id)
    if card is None:
        logger.warning("Card ID not found in registry: %s — card will be dropped", card_id)
    return card


def serialize_pokemon(p: PokemonInPlay) -> dict:
    return {
        "card_id": _card_id(p.card),
        "damage_counters": p.damage_counters,
        "energy_card_ids": [c.api_id for c in p.energy_cards],
        "attached_tool": _card_id(p.attached_tool),
        "status_conditions": [s.name for s in p.status_conditions],
        "evolution_stack": [_card_id(c) for c in p.evolution_stack],
        "can_evolve_this_turn": p.can_evolve_this_turn,
        "placed_this_turn": p.placed_this_turn,
        "used_abilities": sorted(p.used_abilities),
        "attack_locked": p.attack_locked,
        "attack_locked_names": [[n, t] for n, t in p.attack_locked_names.items()] if p.attack_locked_names else [],
        "dazzled": p.dazzled,
        "paralyzed_since_turn": p.paralyzed_since_turn,
        "damage_prevented_next_turn": p.damage_prevented_next_turn,
        "all_prevented_next_turn": p.all_prevented_next_turn,
    }


def deserialize_pokemon(data: dict) -> Optional[PokemonInPlay]:
    if data is None:
        return None
    card = _get_card(data["card_id"])
    if card is None:
        return None
    p = PokemonInPlay(card=card)
    p.damage_counters = data.get("damage_counters", 0)
    p.energy_cards = [
        c for cid in data.get("energy_card_ids", [])
        if (c := _get_card(cid))
    ]
    p.attached_tool = _get_card(data.get("attached_tool")) if data.get("attached_tool") else None
    p.status_conditions = {StatusType[s] for s in data.get("status_conditions", [])}
    p.evolution_stack = [
        c for cid in data.get("evolution_stack", [])
        if (c := _get_card(cid))
    ]
    p.can_evolve_this_turn = data.get("can_evolve_this_turn", True)
    p.placed_this_turn = data.get("placed_this_turn", True)
    p.used_abilities = set(data.get("used_abilities", []))
    p.attack_locked = data.get("attack_locked", False)
    p.attack_locked_names = dict(data.get("attack_locked_names", []))
    p.dazzled = data.get("dazzled", False)
    p.paralyzed_since_turn = data.get("paralyzed_since_turn", 0)
    p.damage_prevented_next_turn = data.get("damage_prevented_next_turn", False)
    p.all_prevented_next_turn = data.get("all_prevented_next_turn", False)
    return p


def serialize_player_state(ps: PlayerState, hide_hand: bool) -> dict:
    data = {
        "name": ps.name,
        "hand": [] if hide_hand else [_card_id(c) for c in ps.hand],
        "hand_count": len(ps.hand),
        "hand_hidden": hide_hand,
        "discard": [_card_id(c) for c in ps.discard],
        "active": serialize_pokemon(ps.active) if ps.active else None,
        "bench": [serialize_pokemon(p) if p else None for p in ps.bench],
        "supporter_used": ps.supporter_played_this_turn,
        "energy_attached": ps.energy_attached_this_turn,
        "retreated": ps.retreated_this_turn,
        "stadium_played": ps.stadium_played_this_turn,
        "stadium_used": ps.stadium_used_this_turn,
        "vstar_used": ps.vstar_power_used,
    }
    # Own player: send full deck/prize card IDs for local game logic.
    # Opponent: send only counts (hidden information).
    if hide_hand:
        data["deck_count"] = len(ps.deck)
        data["prize_count"] = len(ps.prizes)
    else:
        data["deck"] = [_card_id(c) for c in ps.deck]
        data["prizes"] = [_card_id(c) for c in ps.prizes]
    return data


def deserialize_player_state(data: dict) -> PlayerState:
    ps = PlayerState(data.get("name", ""))
    ps._hand_count = data.get("hand_count", 0)
    ps._hand_hidden = data.get("hand_hidden", False)
    ps.hand = [
        c for cid in data.get("hand", [])
        if (c := _get_card(cid))
    ]
    ps.discard = [
        c for cid in data.get("discard", [])
        if (c := _get_card(cid))
    ]
    # Own player: full card lists. Opponent: count placeholders only.
    if "deck" in data:
        ps.deck = [c for cid in data["deck"] if (c := _get_card(cid))]
    else:
        ps.deck = [None] * data.get("deck_count", 0)
    if "prizes" in data:
        ps.prizes = [c for cid in data["prizes"] if (c := _get_card(cid))]
    else:
        ps.prizes = [None] * data.get("prize_count", 0)
    ps.active = deserialize_pokemon(data["active"]) if data.get("active") else None
    ps.bench = [deserialize_pokemon(p) if p else None for p in data.get("bench", [])]
    ps.supporter_played_this_turn = data.get("supporter_used", False)
    ps.energy_attached_this_turn = data.get("energy_attached", False)
    ps.retreated_this_turn = data.get("retreated", False)
    ps.stadium_played_this_turn = data.get("stadium_played", False)
    ps.stadium_used_this_turn = data.get("stadium_used", False)
    ps.vstar_power_used = data.get("vstar_used", False)
    return ps


def serialize_game_state(state: GameState, for_player_idx: int) -> dict:
    """Serialize full game state, filtering hidden info for the given player."""
    your_state = state.get_player(for_player_idx)
    opp_state = state.get_player(1 - for_player_idx)

    return {
        "phase": state.phase.name,
        "turn_number": state.turn_number,
        "active_player_idx": state.active_player_idx,
        "first_player_idx": state.first_player_idx,
        "stadium_card": _card_id(state.stadium_card) if state.stadium_card else None,
        "winner": state.winner,
        "apply_type_matchups": getattr(state, "apply_type_matchups", False),
        "action_log": state.action_log[-50:],
        "mulligan_count": list(state.mulligan_count),
        "extra_draws": list(state.extra_draws),
        "pending_promotion_player": state.pending_promotion_player,
        "your": serialize_player_state(your_state, hide_hand=False),
        "opponent": serialize_player_state(opp_state, hide_hand=True),
    }


def deserialize_game_state(data: dict, for_player_idx: int) -> GameState:
    """Deserialize game state from host, mapping your/opponent to p1/p2."""
    state = GameState()
    state.is_network_view = True
    state.phase = TurnPhase[data["phase"]]
    state.turn_number = data["turn_number"]
    state.active_player_idx = data["active_player_idx"]
    state.first_player_idx = data.get("first_player_idx", 0)
    state.winner = data.get("winner")
    state.apply_type_matchups = data.get("apply_type_matchups", False)
    state.action_log = data.get("action_log", [])
    state.mulligan_count = tuple(data.get("mulligan_count", [0, 0]))
    state.extra_draws = tuple(data.get("extra_draws", [0, 0]))
    state.pending_promotion_player = data.get("pending_promotion_player", -1)

    if data.get("stadium_card"):
        state.stadium_card = _get_card(data["stadium_card"])

    if for_player_idx == 0:
        state.p1 = deserialize_player_state(data["your"])
        state.p2 = deserialize_player_state(data["opponent"])
    else:
        state.p1 = deserialize_player_state(data["opponent"])
        state.p2 = deserialize_player_state(data["your"])

    return state


def serialize_action_request(req: ActionRequest) -> dict:
    """Serialize a pending ActionRequest for network transmission."""
    return {
        "request_type": req.request_type,
        "player": req.player,
        "prompt": req.prompt,
        "min_select": req.min_select,
        "max_select": req.max_select,
        "from_zone": req.from_zone,
        "card_list": [
            _card_id(c) if hasattr(c, 'api_id') else c
            for c in req.card_list
        ],
        "target_player": req.target_player or "",
        "bench_indices": req.bench_indices,
        "allow_duplicates": req.allow_duplicates,
        "flip_count": req.flip_count,
        "until_tails": req.until_tails,
        "predetermined_flips": getattr(req, "predetermined_flips", None),
        "distribute_mode": req.distribute_mode,
        "target_info": list(req.target_info),
        "max_per_target": req.max_per_target,
        "source_name": req.source_name,
        "request_id": req.request_id,
        "pending_card_id": _card_id(req.pending_card) if req.pending_card else None,
    }


def deserialize_action_request(data: dict) -> ActionRequest:
    """Deserialize an ActionRequest from network."""
    # Convert string card IDs back to Card objects for card_list
    card_list_raw = data.get("card_list", [])
    card_list = []
    for c in card_list_raw:
        if isinstance(c, str):
            card = _get_card(c)
            if card:
                card_list.append(card)
        else:
            card_list.append(c)

    ar = ActionRequest(
        request_type=data["request_type"],
        player=data.get("player", 0),
        prompt=data["prompt"],
        min_select=data.get("min_select", 1),
        max_select=data.get("max_select", 1),
        from_zone=data.get("from_zone", ""),
        card_list=card_list,
        target_player=data.get("target_player", ""),
        bench_indices=data.get("bench_indices", []),
        allow_duplicates=data.get("allow_duplicates", False),
        flip_count=data.get("flip_count", 1),
        until_tails=data.get("until_tails", False),
        distribute_mode=data.get("distribute_mode", ""),
        target_info=data.get("target_info", []),
        max_per_target=data.get("max_per_target", 99),
        source_name=data.get("source_name", ""),
        request_id=data.get("request_id", ""),
    )
    # Propagate host-generated coin results for server-authoritative flips
    predetermined = data.get("predetermined_flips")
    if predetermined is not None:
        setattr(ar, "predetermined_flips", list(predetermined))

    pending_card_id = data.get("pending_card_id")
    if pending_card_id:
        ar.pending_card = _get_card(pending_card_id)

    return ar
