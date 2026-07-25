class_name AIActionEncoder
extends RefCounted

const STATE_NUMERIC_SIZE := 960
const STATE_CARD_SLOTS := 128
const ACTION_NUMERIC_SIZE := 178
const CARD_SEMANTIC_SIZE := 53
const ENCODER_SCHEMA_VERSION := 6
const OWN_HAND_TOKEN_COUNT := 16
const DISCARD_TOKEN_COUNT := 12
const STADIUM_TOKEN_INDEX := 112
const RESERVED_TOKEN_START := 113
const PHASES := ["SETUP", "DRAW", "MAIN", "ATTACK", "POKEMON_CHECKUP", "GAME_OVER"]
const DECK_KEYS := [
	"fire", "water", "psychic", "lightning",
	"fighting", "colorless", "dragon", "grass",
	"steel", "darkness",
]
const CHOICE_TYPES := [
	"select_card", "select_pokemon", "select_attachment", "distribute_energy",
	"confirm", "select_prize", "setup", "coin_flip", "order",
]
const CHOICE_TYPE_ALIASES := {
	"arven": "select_card",
	"clara": "select_card",
	"discard_cards": "select_card",
	"discard_then_draw": "select_card",
	"evolve_skip_stage": "select_card",
	"hand_bottom_draw": "select_card",
	"houb": "select_card",
	"look_top": "select_card",
	"look_top_attach_energy": "select_card",
	"resolve_empty": "select_card",
	"search": "select_card",
	"search_deck": "select_card",
	"search_move": "select_card",
	"select": "select_card",
	"select_card": "select_card",
	"select_hand_to_discard": "select_card",
	"shuffle_from_discard": "select_card",
	"zinnia": "select_card",
	"bench_damage_target": "select_pokemon",
	"damage_target": "select_pokemon",
	"place_counters_self_discard": "select_pokemon",
	"select_bench": "select_pokemon",
	"select_bench_targets": "select_pokemon",
	"select_energy_source": "select_pokemon",
	"select_energy_target": "select_pokemon",
	"select_heal_target": "select_pokemon",
	"select_opponent_bench": "select_pokemon",
	"select_own_bench_energy": "select_pokemon",
	"select_attachment": "select_attachment",
	"select_retreat_payment": "select_attachment",
	"distribute_energy": "distribute_energy",
	"confirm": "confirm",
	"confirm_trigger": "confirm",
	"select_prize": "select_prize",
	"choose_mulligan_draw_count": "setup",
	"choose_turn_order": "setup",
	"coin_flip": "coin_flip",
	"choose_trigger_order": "order",
}
const TARGET_SLOTS := ["active", "bench_0", "bench_1", "bench_2", "bench_3", "bench_4"]
const REF_KINDS := ["card", "pokemon", "slot", "attachment"]
const REF_ZONES := [
	"hand", "deck", "discard", "prizes", "active", "bench", "field", "stadium",
]
const ATTACHMENT_TYPES := ["energy", "tool"]

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
	numeric.append_array([
		_norm(
			maxi(0, observation["own_hand"].size() - OWN_HAND_TOKEN_COUNT),
			20.0,
		),
		_norm(
			maxi(0, observation["own_discard"].size() - DISCARD_TOKEN_COUNT),
			60.0,
		),
		_norm(
			maxi(
				0,
				observation["opponent_discard"].size() - DISCARD_TOKEN_COUNT,
			),
			60.0,
		),
	])

	var card_ids: Array[int] = []
	for row_value in _ordered_board(observation):
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
		for energy_index in range(4):
			card_ids.append(
				_bucket(str(energy_ids[energy_index]))
				if energy_index < energy_ids.size()
				else 0
			)
		card_ids.append(_bucket(tool_id))
	card_ids.append_array(_fixed_zone_indices(
		observation["own_hand"],
		OWN_HAND_TOKEN_COUNT,
		false,
	))
	card_ids.append_array(_fixed_zone_indices(
		observation["own_discard"],
		DISCARD_TOKEN_COUNT,
		true,
	))
	card_ids.append_array(_fixed_zone_indices(
		observation["opponent_discard"],
		DISCARD_TOKEN_COUNT,
		true,
	))
	card_ids.append(_bucket(str(observation["stadium_id"])))
	if card_ids.size() != RESERVED_TOKEN_START:
		return {"error": "encoder_v6_card_layout:%d" % card_ids.size()}
	return {
		"numeric": _pad_float(numeric, STATE_NUMERIC_SIZE),
		"card_ids": _pad_int(card_ids, STATE_CARD_SLOTS),
	}


func _ordered_board(observation: Dictionary) -> Array:
	var rows_by_key := {}
	for row_value in observation["board"]:
		var row: Array = row_value
		rows_by_key["%d:%s" % [int(row[0]), str(row[1])]] = row
	var ordered: Array = []
	var perspective := int(observation["perspective"])
	for player_idx in [perspective, 1 - perspective]:
		for slot in TARGET_SLOTS:
			var key := "%d:%s" % [player_idx, slot]
			ordered.append(rows_by_key.get(
				key,
				[player_idx, slot, "", 0, [], [], ""],
			))
	return ordered


func _fixed_zone_indices(
	values: Array,
	width: int,
	take_last: bool,
) -> Array[int]:
	var result: Array[int] = []
	var start := maxi(0, values.size() - width) if take_last else 0
	var stop := mini(values.size(), start + width)
	for index in range(start, stop):
		result.append(_bucket(str(values[index])))
	return _pad_int(result, width)


func encode_action(
	observation: Dictionary,
	action: GameAction,
	deck_key: String,
) -> Dictionary:
	var action_data := action.to_dict()
	var action_kind := str(action_data.get("kind", action_data.get("action", "")))
	if not GameAction.is_known_kind(action_kind):
		return {"error": "unknown_action_type:%s" % action_kind}
	var action_types := GameAction.encoder_kinds()
	var action_index := GameAction.encoding_index(action_kind)
	if action_index < 0 or action_index >= action_types.size():
		return {"error": "action_not_encodable:%s" % action_kind}
	var payload := Dictionary(
		action_data.get("payload", action_data.get("params", {}))).duplicate(true)
	var actor := int(action_data.get("actor", -1))
	var source := _ref_dictionary(action_data.get("source"))
	var target := _ref_dictionary(action_data.get("target"))
	var numeric: Array[float] = []
	numeric.append_array(_one_hot(action_index, action_types.size()))
	numeric.append_array([
		_bool(GameAction.is_terminal_kind(action_kind)),
		_bool(actor < 0 or actor == int(observation["perspective"])),
	])
	var slot_name := str(target.get("slot", ""))
	if slot_name.is_empty():
		slot_name = str(payload.get(
			"target_slot",
			payload.get("target", payload.get("slot", "")),
		))
	numeric.append_array(_one_hot(TARGET_SLOTS.find(slot_name), TARGET_SLOTS.size()))
	var hand_idx: Variant = payload.get("hand_idx")
	if hand_idx == null and str(source.get("zone", "")) == "hand":
		hand_idx = source.get("index")
	var attack_idx: Variant = payload.get("attack_index", payload.get("attack_idx"))
	var bench_idx: Variant = payload.get("bench_idx")
	if bench_idx == null and slot_name.begins_with("bench_"):
		bench_idx = slot_name.trim_prefix("bench_").to_int()
	var energy_indices: Array = payload.get("energy_indices", [])
	if energy_indices.is_empty():
		for ref_value in payload.get("attachments", payload.get("payment", [])):
			var attachment_ref := _ref_dictionary(ref_value)
			if attachment_ref.has("index"):
				energy_indices.append(int(attachment_ref["index"]))
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
	var card_id := str(source.get("card_id", ""))
	if card_id.is_empty() and _is_number(hand_idx):
		var hand: Array = observation["own_hand"]
		if int(hand_idx) >= 0 and int(hand_idx) < hand.size():
			card_id = str(hand[int(hand_idx)])
	numeric.append_array(_semantic(card_id))
	numeric.append_array(_one_hot(DECK_KEYS.find(deck_key), DECK_KEYS.size()))
	numeric.append_array(_ref_features(target, int(observation["perspective"])))
	numeric.append_array(_ref_features(source, int(observation["perspective"])))
	for index in range(4):
		numeric.append(
			_norm(int(energy_indices[index]) + 1, 64.0)
			if index < energy_indices.size() and _is_number(energy_indices[index])
			else 0.0
		)
	return {
		"numeric": _pad_float(numeric, ACTION_NUMERIC_SIZE),
		"card_id": _bucket(card_id),
	}


func encode_choice(
	observation: Dictionary,
	request: ChoiceView,
	option: Dictionary,
	index: int,
) -> Dictionary:
	if request == null or request.base_revision < 0:
		return {"error": "invalid_choice_view"}
	var choice_type_index := _choice_type_index(request.request_type)
	if choice_type_index < 0:
		return {"error": "unknown_choice_type:%s" % request.request_type}
	var numeric: Array[float] = []
	numeric.append_array(_one_hot(choice_type_index, CHOICE_TYPES.size()))
	var ref := _choice_ref(option)
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
		card_id = _card_id_from_option_id(str(option.get("option_id", "")))
	numeric.append_array(_semantic(card_id))
	numeric.append_array(_ref_features(ref, int(observation["perspective"])))
	numeric.append(_stable_string_feature(str(option.get("option_id", ""))))
	return {
		"numeric": _pad_float(numeric, ACTION_NUMERIC_SIZE),
		"card_id": _bucket(card_id),
	}


static func supports_choice_type(request_type: String) -> bool:
	return _choice_type_index(request_type) >= 0


static func _ref_dictionary(value: Variant) -> Dictionary:
	if value is Dictionary:
		return Dictionary(value).duplicate(true)
	if value is EntityRef:
		return value.to_dict()
	return {}


static func _choice_ref(option: Dictionary) -> Dictionary:
	var ref := _ref_dictionary(option.get("ref"))
	return ref


func _card_id_from_option_id(option_id: String) -> String:
	var parts := option_id.split(":")
	if parts.size() < 2:
		return ""
	var candidate := str(parts[-1])
	return candidate if not catalog.get_card(candidate).is_empty() else ""


static func _ref_features(ref: Dictionary, perspective: int) -> Array[float]:
	var features: Array[float] = []
	var present := not ref.is_empty()
	var player := int(ref.get("player", -1))
	features.append(_bool(present))
	features.append_array([
		_bool(present and player == perspective),
		_bool(present and player in [0, 1] and player != perspective),
		_bool(present and player not in [0, 1]),
	])
	features.append_array(_one_hot(
		REF_KINDS.find(str(ref.get("kind", ""))), REF_KINDS.size()))
	features.append_array(_one_hot(
		REF_ZONES.find(str(ref.get("zone", ""))), REF_ZONES.size()))
	features.append_array(_one_hot(
		TARGET_SLOTS.find(str(ref.get("slot", ""))), TARGET_SLOTS.size()))
	features.append_array(_one_hot(
		ATTACHMENT_TYPES.find(str(ref.get("attachment_type", ""))),
		ATTACHMENT_TYPES.size(),
	))
	features.append(_norm(
		int(ref.get("index", -1)) + 1 if present else 0,
		64.0,
	))
	features.append(_norm(float(_stable_card_identity(str(ref.get("card_id", "")))), 4294967296.0))
	return features


static func _stable_string_feature(value: String) -> float:
	if value.is_empty():
		return 0.0
	return float(AIDecisionSeed.derive(0, 0, 0, "encoder-option", value)) / 4294967296.0


static func _stable_card_identity(card_id: String) -> int:
	if card_id.is_empty():
		return 0
	return AIDecisionSeed.derive(0, 0, 0, "encoder-card", card_id)


func _semantic(card_id: String) -> Array[float]:
	var values: Array[float] = []
	if not card_id.is_empty():
		for value in catalog.get_card(card_id).get("ai_semantic_features", []):
			values.append(float(value))
	return _pad_float(values, CARD_SEMANTIC_SIZE)


func _bucket(card_id: String) -> int:
	if card_id.is_empty():
		return 0
	return int(catalog.get_card(card_id).get("ai_card_index", 1))


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
	if values.size() > size:
		push_error("encoder_numeric_overflow:%d>%d" % [values.size(), size])
		return []
	var result := values.duplicate()
	result.resize(size)
	for index in range(values.size(), size):
		result[index] = 0.0
	return result


static func _pad_int(values: Array[int], size: int) -> Array[int]:
	if values.size() > size:
		push_error("encoder_card_slot_overflow:%d>%d" % [values.size(), size])
		return []
	var result := values.duplicate()
	result.resize(size)
	for index in range(values.size(), size):
		result[index] = 0
	return result
