class_name GameState
extends RefCounted

var players: Array[PlayerState] = [PlayerState.new("玩家1"), PlayerState.new("玩家2")]
var active_player_idx := 0
var phase := "SETUP"
var turn_number := 0
var first_player_idx := 0
var stadium_card_id := ""
var winner := -1
var revision := 0
var choice_sequence := 0
var public_deck_keys: Array[String] = ["", ""]
var apply_type_matchups := false
var action_log: Array[String] = []
var mulligan_count: Array[int] = [0, 0]
var extra_draws: Array[int] = [0, 0]
var setup_ready: Array[bool] = [false, false]
var pending_promotions: Array[int] = []
var processed_action_ids: Array[String] = []
var event_stream := GameEventStream.new()
var resolution_stack: Dictionary = {
	"frames": [],
	"pending_request": null,
	"sequence": 0,
	"context": {},
}


func get_player(index: int) -> PlayerState:
	return players[index]


func get_opponent(index: int = active_player_idx) -> PlayerState:
	return players[1 - index]


func log_action(message: String) -> void:
	action_log.append(message)
	if action_log.size() > 100:
		action_log.pop_front()


func is_first_turn() -> bool:
	return turn_number == 1


func is_player_first_turn(player_idx: int) -> bool:
	if player_idx == first_player_idx:
		return turn_number == 1
	return turn_number == 2


func setup_game(
	deck_one: Array[String],
	deck_two: Array[String],
	rng: PortableRandomSource,
	forced_first: int = -1,
) -> void:
	players = [PlayerState.new("玩家1"), PlayerState.new("玩家2")]
	players[0].deck = deck_one.duplicate()
	players[1].deck = deck_two.duplicate()
	rng.shuffle(players[0].deck)
	rng.shuffle(players[1].deck)
	first_player_idx = forced_first if forced_first in [0, 1] else (0 if rng.coin() else 1)
	active_player_idx = first_player_idx
	turn_number = 1
	players[0].draw_cards(7)
	players[1].draw_cards(7)
	phase = "SETUP"
	winner = -1
	revision = 0
	choice_sequence = 0
	setup_ready = [false, false]
	pending_promotions.clear()
	processed_action_ids.clear()
	resolution_stack = {
		"frames": [],
		"pending_request": null,
		"sequence": 0,
		"context": {},
	}
	log_action("游戏开始！%s先攻。" % players[first_player_idx].name)


func set_prizes() -> void:
	players[0].set_prizes(6)
	players[1].set_prizes(6)
	log_action("双方各放置6张奖品卡。")


func discard_pokemon(player_idx: int, slot: String) -> PokemonState:
	var player := players[player_idx]
	var pokemon := player.get_pokemon(slot)
	if pokemon == null:
		return null
	player.discard.append(pokemon.card_id)
	player.discard.append_array(pokemon.evolution_stack_ids)
	if not pokemon.attached_tool_id.is_empty():
		player.discard.append(pokemon.attached_tool_id)
	player.discard.append_array(pokemon.energy_card_ids)
	if slot == "active":
		player.active = null
	elif slot.begins_with("bench_"):
		var index := slot.trim_prefix("bench_").to_int()
		if index >= 0 and index < player.bench.size():
			player.bench[index] = null
	return pokemon


func to_dict() -> Dictionary:
	return {
		"players": [players[0].to_dict(), players[1].to_dict()],
		"active_player_idx": active_player_idx,
		"phase": phase,
		"turn_number": turn_number,
		"first_player_idx": first_player_idx,
		"stadium_card_id": stadium_card_id,
		"winner": winner,
		"revision": revision,
		"choice_sequence": choice_sequence,
		"public_deck_keys": public_deck_keys.duplicate(),
		"apply_type_matchups": apply_type_matchups,
		"action_log": action_log.duplicate(),
		"mulligan_count": mulligan_count.duplicate(),
		"extra_draws": extra_draws.duplicate(),
		"setup_ready": setup_ready.duplicate(),
		"pending_promotions": pending_promotions.duplicate(),
		"processed_action_ids": processed_action_ids.duplicate(),
		"resolution_stack": resolution_stack.duplicate(true),
	}


func snapshot() -> Dictionary:
	return to_dict().duplicate(true)


func clone_state() -> GameState:
	var result := GameState.new()
	if players.size() == 2:
		result.players = [
			players[0].clone_state(),
			players[1].clone_state(),
		]
	result.active_player_idx = active_player_idx
	result.phase = phase
	result.turn_number = turn_number
	result.first_player_idx = first_player_idx
	result.stadium_card_id = stadium_card_id
	result.winner = winner
	result.revision = revision
	result.choice_sequence = choice_sequence
	result.public_deck_keys = []
	for value in public_deck_keys:
		result.public_deck_keys.append(str(value) if value != null else "")
	while result.public_deck_keys.size() < 2:
		result.public_deck_keys.append("")
	result.public_deck_keys.resize(2)
	result.apply_type_matchups = apply_type_matchups
	result.action_log.assign(action_log)
	result.mulligan_count.assign(mulligan_count)
	result.extra_draws.assign(extra_draws)
	result.setup_ready.assign(setup_ready)
	result.pending_promotions.assign(pending_promotions)
	result.processed_action_ids.assign(processed_action_ids)
	result.resolution_stack = resolution_stack.duplicate(true)
	result.event_stream = GameEventStream.new()
	return result


static func from_dict(data: Dictionary) -> GameState:
	var result := GameState.new()
	var player_rows: Array = data.get("players", [])
	if player_rows.size() == 2:
		result.players = [
			PlayerState.from_dict(player_rows[0]),
			PlayerState.from_dict(player_rows[1]),
		]
	result.active_player_idx = int(data.get("active_player_idx", 0))
	result.phase = str(data.get("phase", "SETUP"))
	result.turn_number = int(data.get("turn_number", 0))
	result.first_player_idx = int(data.get("first_player_idx", 0))
	result.stadium_card_id = str(data.get("stadium_card_id", ""))
	result.winner = int(data.get("winner", -1))
	result.revision = int(data.get("revision", 0))
	result.choice_sequence = int(data.get("choice_sequence", 0))
	result.public_deck_keys = []
	for value in data.get("public_deck_keys", ["", ""]):
		result.public_deck_keys.append(str(value) if value != null else "")
	while result.public_deck_keys.size() < 2:
		result.public_deck_keys.append("")
	result.public_deck_keys.resize(2)
	result.apply_type_matchups = bool(data.get("apply_type_matchups", false))
	result.action_log.assign(data.get("action_log", []))
	result.mulligan_count.assign(data.get("mulligan_count", [0, 0]))
	result.extra_draws.assign(data.get("extra_draws", [0, 0]))
	result.setup_ready.assign(data.get("setup_ready", [false, false]))
	result.pending_promotions.assign(data.get("pending_promotions", []))
	result.processed_action_ids.assign(data.get("processed_action_ids", []))
	result.resolution_stack = Dictionary(data.get(
		"resolution_stack",
		{"frames": [], "pending_request": null, "sequence": 0, "context": {}},
	)).duplicate(true)
	return result
