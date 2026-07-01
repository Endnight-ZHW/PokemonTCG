class_name AIActionEncoder
extends RefCounted

const STATE_NUMERIC_SIZE := 960
const STATE_CARD_SLOTS := 96
const ACTION_NUMERIC_SIZE := 178
const MISSING_CARD_SEMANTIC_SIZE := 48
const PHASES := ["SETUP", "DRAW", "MAIN", "ATTACK", "POKEMON_CHECKUP", "GAME_OVER"]
const DECK_KEYS := [
	"fire", "water", "psychic", "lightning",
	"fighting", "colorless", "dragon", "grass",
]
const ACTION_TYPES := [
	"NOOP", "SETUP_DONE", "PROMOTE", "PLAY_BASIC", "EVOLVE",
	"ATTACH_ENERGY", "PLAY_TRAINER", "USE_ABILITY", "USE_STADIUM",
	"RETREAT", "DECLARE_ATTACK", "END_TURN",
]
const CHOICE_TYPES := [
	"search_deck", "select_hand_to_discard", "select_bench",
	"select_opponent_bench", "select_own_bench_energy", "select_bench_targets",
	"distribute_energy", "confirm",
]
const CHOICE_TYPE_ALIASES := {
	"evolve_skip_stage": "search_deck",
}
const TARGET_SLOTS := ["active", "bench_0", "bench_1", "bench_2", "bench_3", "bench_4"]

var catalog: CardCatalog


func _init(p_catalog: CardCatalog) -> void:
	catalog = p_catalog


func encode_observation(observation: Dictionary, deck_key: String) -> Dictionary:
	var numeric: Array[float] = []
	numeric.append_array(_one_hot(PHASES.find(str(observation["phase"])), PHASES.size()))
	var perspective := int(observation["perspective"])
	var winner: int = (
		int(observation["winner"])
		if observation.get("winner") != null
		else -1
	)
	numeric.append_array([
		_bool(int(observation["active_player"]) == perspective),
		_norm(float(observation["turn_number"]), 20.0),
		_bool(bool(observation["apply_type_matchups"])),
		_bool(winner == perspective),
		_bool(winner == 1 - perspective),
		_norm(observation["own_hand"].size(), 20.0),
		_norm(observation["own_discard"].size(), 60.0),
		_norm(float(observation["own_deck_count"]), 60.0),
		_norm(float(observation["own_prize_count"]), 6.0),
		_norm(float(observation["opponent_hand_count"]), 20.0),
		_norm(observation["opponent_discard"].size(), 60.0),
		_norm(float(observation["opponent_deck_count"]), 60.0),
		_norm(float(observation["opponent_prize_count"]), 6.0),
	])
	numeric.append_array(_one_hot(DECK_KEYS.find(deck_key), DECK_KEYS.size()))

	var card_ids: Array[int] = []
	for row_value in observation["board"]:
		var row: Array = row_value
		var card_id := str(row[2])
		var energy_ids: Array = row[4]
		var statuses: Array = row[5]
		var tool_id := str(row[6])
		numeric.append_array([
			_bool(not card_id.is_empty()),
			_bool(int(row[0]) == perspective),
			_bool(str(row[1]) == "active"),
			_norm(float(row[3]), 30.0),
			_norm(energy_ids.size(), 6.0),
			_norm(statuses.size(), 5.0),
			_bool(not tool_id.is_empty()),
		])
		numeric.append_array(_semantic(card_id))
		card_ids.append(_bucket(card_id))
		for energy_id in energy_ids.slice(0, 4):
			card_ids.append(_bucket(str(energy_id)))
		card_ids.append(_bucket(tool_id))
	for card_id in observation["own_hand"].slice(0, 16):
		card_ids.append(_bucket(str(card_id)))
	for card_id in observation["own_discard"].slice(-12):
		card_ids.append(_bucket(str(card_id)))
	for card_id in observation["opponent_discard"].slice(-12):
		card_ids.append(_bucket(str(card_id)))
	card_ids.append(_bucket(str(observation["stadium_id"])))
	return {
		"numeric": _pad_float(numeric, STATE_NUMERIC_SIZE),
		"card_ids": _pad_int(card_ids, STATE_CARD_SLOTS),
	}


func encode_action(
	observation: Dictionary,
	action: GameAction,
	deck_key: String,
) -> Dictionary:
	var numeric: Array[float] = []
	numeric.append_array(_one_hot(ACTION_TYPES.find(action.action), ACTION_TYPES.size()))
	numeric.append_array([
		_bool(action.terminal),
		_bool(action.actor < 0 or action.actor == int(observation["perspective"])),
	])
	var slot_name := ""
	if action.target:
		slot_name = action.target.slot
	if slot_name.is_empty():
		slot_name = str(action.params.get(
			"target_slot",
			action.params.get("target", action.params.get("slot", "")),
		))
	numeric.append_array(_one_hot(TARGET_SLOTS.find(slot_name), TARGET_SLOTS.size()))
	var hand_idx: Variant = action.params.get("hand_idx")
	var attack_idx: Variant = action.params.get("attack_idx")
	var bench_idx: Variant = action.params.get("bench_idx")
	var energy_indices: Array = action.params.get("energy_indices", [])
	var occupied := 0
	var opponent_occupied := 0
	for row in observation["board"]:
		if not str(row[2]).is_empty():
			occupied += 1
			if int(row[0]) != int(observation["perspective"]):
				opponent_occupied += 1
	numeric.append_array([
		_norm(int(hand_idx) + 1 if _is_number(hand_idx) else 0, 12.0),
		_norm(int(attack_idx) + 1 if _is_number(attack_idx) else 0, 4.0),
		_norm(int(bench_idx) + 1 if _is_number(bench_idx) else 0, 5.0),
		_norm(energy_indices.size(), 6.0),
		_norm(occupied, 12.0),
		_norm(opponent_occupied, 6.0),
	])
	var card_id := action.source.card_id if action.source else ""
	if card_id.is_empty() and _is_number(hand_idx):
		var hand: Array = observation["own_hand"]
		if int(hand_idx) >= 0 and int(hand_idx) < hand.size():
			card_id = str(hand[int(hand_idx)])
	numeric.append_array(_semantic(card_id))
	numeric.append_array(_one_hot(DECK_KEYS.find(deck_key), DECK_KEYS.size()))
	return {
		"numeric": _pad_float(numeric, ACTION_NUMERIC_SIZE),
		"card_id": _bucket(card_id),
	}


func encode_choice(
	observation: Dictionary,
	request: ChoiceRequest,
	option: Dictionary,
	index: int,
) -> Dictionary:
	var numeric: Array[float] = []
	numeric.append_array(_one_hot(_choice_type_index(request.request_type), CHOICE_TYPES.size()))
	var ref: Dictionary = option.get("ref", {})
	var kind := str(ref.get("kind", ""))
	numeric.append_array([
		_norm(index + 1, 64.0),
		_bool(kind == "card"),
		_bool(kind == "pokemon"),
		_bool(kind == "attachment"),
		_bool(int(ref.get("player", observation["perspective"])) == int(observation["perspective"])),
	])
	numeric.append_array(_one_hot(TARGET_SLOTS.find(str(ref.get("slot", ""))), TARGET_SLOTS.size()))
	var card_id := str(ref.get("card_id", ""))
	if card_id.is_empty():
		var value: Dictionary = option.get("value", {})
		card_id = str(value.get("card_id", ""))
	numeric.append_array(_semantic(card_id))
	return {
		"numeric": _pad_float(numeric, ACTION_NUMERIC_SIZE),
		"card_id": _bucket(card_id),
	}


func _semantic(card_id: String) -> Array[float]:
	if card_id.is_empty():
		var missing: Array[float] = []
		missing.resize(MISSING_CARD_SEMANTIC_SIZE)
		missing.fill(0.0)
		return missing
	var values: Array[float] = []
	for value in catalog.get_card(card_id).get("ai_semantic_features", []):
		values.append(float(value))
	return values


func _bucket(card_id: String) -> int:
	if card_id.is_empty():
		return 0
	return int(catalog.get_card(card_id).get("card_bucket", 0))


static func _bool(value: bool) -> float:
	return 1.0 if value else 0.0


static func _is_number(value: Variant) -> bool:
	return value is int or value is float


static func _norm(value: float, divisor: float) -> float:
	return clampf(value / divisor, -4.0, 4.0) if divisor > 0.0 else 0.0


static func _one_hot(index: int, size: int) -> Array[float]:
	var values: Array[float] = []
	values.resize(size)
	values.fill(0.0)
	if index >= 0 and index < size:
		values[index] = 1.0
	return values


static func _choice_type_index(request_type: String) -> int:
	var encoded_type := str(CHOICE_TYPE_ALIASES.get(request_type, request_type))
	return CHOICE_TYPES.find(encoded_type)


static func _pad_float(values: Array[float], size: int) -> Array[float]:
	var result := values.slice(0, size)
	result.resize(size)
	for index in range(values.size(), size):
		result[index] = 0.0
	return result


static func _pad_int(values: Array[int], size: int) -> Array[int]:
	var result := values.slice(0, size)
	result.resize(size)
	for index in range(values.size(), size):
		result[index] = 0
	return result
