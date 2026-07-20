class_name GameState
extends RefCounted

const RULES_PROFILE_ID := "CN_MAINLAND_3_1_0"
const SNAPSHOT_SCHEMA_VERSION := 3
const RESULT_ONGOING := "ONGOING"
const RESULT_WIN := "WIN"
const RESULT_DRAW := "DRAW"
const SETUP_TURN_ORDER := "TURN_ORDER"
const SETUP_INITIAL_PLACEMENT := "INITIAL_PLACEMENT"
const SETUP_BONUS_DRAW := "BONUS_DRAW"
const SETUP_BONUS_PLACEMENT := "BONUS_PLACEMENT"
const SETUP_COMPLETE := "COMPLETE"

var players: Array[PlayerState] = [PlayerState.new("玩家1"), PlayerState.new("玩家2")]
var active_player_idx := 0
var phase := "SETUP"
var turn_number := 0
var first_player_idx := 0
var stadium_card_id := ""
var stadium_owner_idx := -1
var winner := -1
var result_status := RESULT_ONGOING
var result_reason := ""
var result_conditions: Array = [[], []]
var revision := 0
var choice_sequence := 0
var public_deck_keys: Array[String] = ["", ""]
var apply_type_matchups := false
var rules_profile_id := RULES_PROFILE_ID
var rules_options: Dictionary = {"apply_type_matchups": false}
var action_log: Array[String] = []
var mulligan_count: Array[int] = [0, 0]
var extra_draws: Array[int] = [0, 0]
var setup_ready: Array[bool] = [false, false]
var setup_stage := SETUP_TURN_ORDER
var setup_actor_idx := -1
var opening_coin_winner_idx := -1
var mulligan_bonus_max := 0
var setup_bonus_card_ids: Array = [[], []]
var pending_promotions: Array[int] = []
var processed_action_ids: Array[String] = []
var event_stream := GameEventStream.new()
var turn_fact_book: Dictionary = {
	"current_turn": {"knockouts": []},
	"previous_turn": {"knockouts": []},
}
var resolution_stack: Dictionary = {
	"schema_version": 3,
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


func type_matchups_enabled() -> bool:
	# Keep the legacy field as the live value so existing callers that directly
	# assign it continue to work. rules_options is the public wire contract.
	return apply_type_matchups


func set_type_matchups_enabled(enabled: bool) -> void:
	apply_type_matchups = enabled
	rules_options["apply_type_matchups"] = enabled


func is_terminal() -> bool:
	return result_status != RESULT_ONGOING or phase == "GAME_OVER"


func clear_result() -> void:
	winner = -1
	result_status = RESULT_ONGOING
	result_reason = ""
	result_conditions = [[], []]


func set_win(player_idx: int, reason: String, conditions: Array = [[], []]) -> void:
	winner = player_idx
	result_status = RESULT_WIN
	result_reason = reason
	result_conditions = conditions.duplicate(true)
	phase = "GAME_OVER"


func set_draw(reason: String, conditions: Array = [[], []]) -> void:
	winner = -1
	result_status = RESULT_DRAW
	result_reason = reason
	result_conditions = conditions.duplicate(true)
	phase = "GAME_OVER"


func record_knockout(fact: Dictionary) -> void:
	var current: Dictionary = turn_fact_book.get("current_turn", {"knockouts": []})
	var knockouts: Array = current.get("knockouts", [])
	knockouts.append(fact.duplicate(true))
	current["knockouts"] = knockouts
	turn_fact_book["current_turn"] = current


func advance_turn_facts() -> void:
	turn_fact_book["previous_turn"] = Dictionary(turn_fact_book.get(
		"current_turn", {"knockouts": []})).duplicate(true)
	turn_fact_book["current_turn"] = {"knockouts": []}


func had_knockout_last_turn(defeated_player_idx: int) -> bool:
	var previous: Dictionary = turn_fact_book.get("previous_turn", {})
	for fact_value in previous.get("knockouts", []):
		var fact: Dictionary = fact_value
		if int(fact.get("defeated_player", -1)) == defeated_player_idx:
			return true
	return false


func had_attack_knockout_last_turn(defeated_player_idx: int) -> bool:
	var previous: Dictionary = turn_fact_book.get("previous_turn", {})
	for fact_value in previous.get("knockouts", []):
		var fact: Dictionary = fact_value
		if (
			int(fact.get("defeated_player", -1)) == defeated_player_idx
			and int(fact.get("source_player", defeated_player_idx)) != defeated_player_idx
			and str(fact.get("source_kind", "")) == "attack_damage"
			and str(fact.get("cause_kind", "")) == "damage"
		):
			return true
	return false


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
	opening_coin_winner_idx = first_player_idx
	active_player_idx = first_player_idx
	turn_number = 0
	phase = "SETUP"
	clear_result()
	revision = 0
	choice_sequence = 0
	setup_ready = [false, false]
	setup_stage = SETUP_TURN_ORDER
	setup_actor_idx = opening_coin_winner_idx
	mulligan_bonus_max = 0
	setup_bonus_card_ids = [[], []]
	stadium_card_id = ""
	stadium_owner_idx = -1
	turn_fact_book = {
		"current_turn": {"knockouts": []},
		"previous_turn": {"knockouts": []},
	}
	pending_promotions.clear()
	processed_action_ids.clear()
	resolution_stack = {
		"schema_version": 3,
		"frames": [],
		"pending_request": null,
		"sequence": 0,
		"context": {},
	}
	if forced_first in [0, 1]:
		log_action("游戏开始！%s先攻。" % players[first_player_idx].name)
	else:
		log_action("游戏开始！%s赢得开局硬币。" % players[opening_coin_winner_idx].name)


func set_prizes() -> void:
	players[0].set_prizes(6)
	players[1].set_prizes(6)
	log_action("双方各放置6张奖赏卡。")


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
		"stadium_owner_idx": stadium_owner_idx,
		"winner": winner,
		"result_status": result_status,
		"result_reason": result_reason,
		"result_conditions": result_conditions.duplicate(true),
		"revision": revision,
		"choice_sequence": choice_sequence,
		"public_deck_keys": public_deck_keys.duplicate(),
		"apply_type_matchups": apply_type_matchups,
		"rules_profile_id": rules_profile_id,
		"rules_options": rules_options.merged(
			{"apply_type_matchups": apply_type_matchups}, true),
		"action_log": action_log.duplicate(),
		"mulligan_count": mulligan_count.duplicate(),
		"extra_draws": extra_draws.duplicate(),
		"setup_ready": setup_ready.duplicate(),
		"setup_stage": setup_stage,
		"setup_actor_idx": setup_actor_idx,
		"opening_coin_winner_idx": opening_coin_winner_idx,
		"mulligan_bonus_max": mulligan_bonus_max,
		"setup_bonus_card_ids": setup_bonus_card_ids.duplicate(true),
		"pending_promotions": pending_promotions.duplicate(),
		"processed_action_ids": processed_action_ids.duplicate(),
		"resolution_stack": resolution_stack.duplicate(true),
		"turn_fact_book": turn_fact_book.duplicate(true),
	}


func snapshot() -> Dictionary:
	# ``to_dict`` already owns every mutable branch it returns (players create
	# fresh rows and the remaining collection fields are duplicated below).
	# Deep-copying the complete payload a second time made every transaction pay
	# for two full snapshots without improving rollback isolation.
	var payload := to_dict()
	payload["action_log"] = action_log.duplicate(true)
	payload["rules_options"] = rules_options.duplicate(true)
	payload["rules_options"]["apply_type_matchups"] = apply_type_matchups
	payload["snapshot_version"] = SNAPSHOT_SCHEMA_VERSION
	return payload


static func from_snapshot(data: Dictionary) -> GameState:
	var compatibility_error := snapshot_compatibility_error(data)
	if not compatibility_error.is_empty():
		var version := int(data.get("snapshot_version", 0))
		push_error(
			"Unsupported GameState snapshot version %d; expected %d. " % [
				version, SNAPSHOT_SCHEMA_VERSION]
			+ "Legacy snapshots are diagnostic-only and are not migrated."
		)
		return null
	return from_dict(data)


static func snapshot_compatibility_error(data: Dictionary) -> String:
	if not data.get("snapshot_version") is int:
		return "incompatible_snapshot"
	return (
		""
		if int(data["snapshot_version"]) == SNAPSHOT_SCHEMA_VERSION
		else "incompatible_snapshot"
	)


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
	result.stadium_owner_idx = stadium_owner_idx
	result.winner = winner
	result.result_status = result_status
	result.result_reason = result_reason
	result.result_conditions = result_conditions.duplicate(true)
	result.revision = revision
	result.choice_sequence = choice_sequence
	result.public_deck_keys = []
	for value in public_deck_keys:
		result.public_deck_keys.append(str(value) if value != null else "")
	while result.public_deck_keys.size() < 2:
		result.public_deck_keys.append("")
	result.public_deck_keys.resize(2)
	result.apply_type_matchups = apply_type_matchups
	result.rules_profile_id = rules_profile_id
	result.rules_options = rules_options.merged(
		{"apply_type_matchups": apply_type_matchups}, true)
	result.action_log.assign(action_log)
	result.mulligan_count.assign(mulligan_count)
	result.extra_draws.assign(extra_draws)
	result.setup_ready.assign(setup_ready)
	result.setup_stage = setup_stage
	result.setup_actor_idx = setup_actor_idx
	result.opening_coin_winner_idx = opening_coin_winner_idx
	result.mulligan_bonus_max = mulligan_bonus_max
	result.setup_bonus_card_ids = setup_bonus_card_ids.duplicate(true)
	result.pending_promotions.assign(pending_promotions)
	result.processed_action_ids.assign(processed_action_ids)
	result.resolution_stack = resolution_stack.duplicate(true)
	result.turn_fact_book = turn_fact_book.duplicate(true)
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
	result.stadium_owner_idx = int(data.get("stadium_owner_idx", -1))
	result.winner = int(data.get("winner", -1))
	result.result_status = str(data.get(
		"result_status", RESULT_WIN if result.winner >= 0 else RESULT_ONGOING))
	result.result_reason = str(data.get("result_reason", ""))
	result.result_conditions = Array(data.get("result_conditions", [[], []])).duplicate(true)
	result.revision = int(data.get("revision", 0))
	result.choice_sequence = int(data.get("choice_sequence", 0))
	result.public_deck_keys = []
	for value in data.get("public_deck_keys", ["", ""]):
		result.public_deck_keys.append(str(value) if value != null else "")
	while result.public_deck_keys.size() < 2:
		result.public_deck_keys.append("")
	result.public_deck_keys.resize(2)
	result.rules_profile_id = str(data.get("rules_profile_id", RULES_PROFILE_ID))
	result.rules_options = Dictionary(data.get("rules_options", {})).duplicate(true)
	result.apply_type_matchups = bool(result.rules_options.get(
		"apply_type_matchups", data.get("apply_type_matchups", false)))
	result.rules_options["apply_type_matchups"] = result.apply_type_matchups
	result.action_log.assign(data.get("action_log", []))
	result.mulligan_count.assign(data.get("mulligan_count", [0, 0]))
	result.extra_draws.assign(data.get("extra_draws", [0, 0]))
	result.setup_ready.assign(data.get("setup_ready", [false, false]))
	result.setup_stage = str(data.get("setup_stage", SETUP_INITIAL_PLACEMENT))
	result.setup_actor_idx = int(data.get("setup_actor_idx", result.first_player_idx))
	result.opening_coin_winner_idx = int(data.get(
		"opening_coin_winner_idx", result.first_player_idx))
	result.mulligan_bonus_max = int(data.get("mulligan_bonus_max", 0))
	result.setup_bonus_card_ids = Array(data.get(
		"setup_bonus_card_ids", [[], []])).duplicate(true)
	result.pending_promotions.assign(data.get("pending_promotions", []))
	result.processed_action_ids.assign(data.get("processed_action_ids", []))
	result.resolution_stack = Dictionary(data.get(
		"resolution_stack",
		{
			"schema_version": 3,
			"frames": [],
			"pending_request": null,
			"sequence": 0,
			"context": {},
		},
	)).duplicate(true)
	result.turn_fact_book = Dictionary(data.get("turn_fact_book", {
		"current_turn": {"knockouts": []},
		"previous_turn": {"knockouts": []},
	})).duplicate(true)
	return result
