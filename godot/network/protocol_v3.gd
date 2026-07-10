class_name ProtocolV3
extends RefCounted

const VERSION := 3
const MAX_MESSAGE_BYTES := 262144
const MAX_IDENTIFIER_BYTES := 128
const MAX_TEXT_BYTES := 2048
const MAX_DECK_CARDS := 60
const MAX_PRIZES := 6
const MAX_BENCH_SIZE := 5
const MAX_LEGAL_ACTIONS := 256
const MAX_PRESENTATION_EVENTS := 256
const MAX_CHOICE_OPTIONS := 60
const MAX_ACTION_LOG_ENTRIES := 256
const MAX_GENERIC_CONTAINER_ITEMS := 512
const MAX_JSON_DEPTH := 12

const GAME_PHASES: Array[String] = [
	"SETUP", "DRAW", "MAIN", "ATTACK", "POKEMON_CHECKUP", "GAME_OVER",
]
const GAME_ACTIONS: Array[String] = [
	"PLAY_BASIC", "EVOLVE", "ATTACH_ENERGY", "PLAY_TRAINER",
	"USE_ABILITY", "USE_STADIUM", "RETREAT", "DECLARE_ATTACK",
	"PROMOTE", "SETUP_DONE", "END_TURN",
]
const STATUS_CONDITIONS: Array[String] = [
	"POISONED", "BURNED", "ASLEEP", "PARALYZED", "CONFUSED",
]

const WELCOME := "welcome"
const DECK_SELECT := "deck_select"
const LOBBY_UPDATE := "lobby_update"
const STATE_UPDATE := "state_update"
const ACTION_SUBMIT := "action_submit"
const CHOICE_SUBMIT := "choice_submit"
const RESYNC_REQUEST := "resync_request"
const SURRENDER := "surrender"
const PING := "ping"
const PONG := "pong"
const ERROR := "error"

const MESSAGE_TYPES: Array[String] = [
	WELCOME,
	DECK_SELECT,
	LOBBY_UPDATE,
	STATE_UPDATE,
	ACTION_SUBMIT,
	CHOICE_SUBMIT,
	RESYNC_REQUEST,
	SURRENDER,
	PING,
	PONG,
	ERROR,
]


static func envelope(
	message_type: String,
	room_id: String,
	sender: int,
	sequence: int,
	state_revision: int = -1,
	action_id: String = "",
	request_id: String = "",
	payload: Dictionary = {},
) -> Dictionary:
	return {
		"protocol_version": VERSION,
		"message_type": message_type,
		"room_id": room_id,
		"sender": sender,
		"sequence": sequence,
		"state_revision": state_revision,
		"action_id": action_id,
		"request_id": request_id,
		"payload": payload.duplicate(true),
	}


static func validate(
	message: Variant,
	expected_room: String = "",
	expected_sender: int = -1,
	last_sequence: int = 0,
) -> Dictionary:
	if not message is Dictionary:
		return _invalid("invalid_message", "消息必须是对象。")
	var row: Dictionary = message
	if not _json_tree_is_serializable(row):
		return _invalid("invalid_message", "消息包含无法序列化的内容。")
	if JSON.stringify(row).to_utf8_buffer().size() > MAX_MESSAGE_BYTES:
		return _invalid("message_too_large", "消息超过大小限制。")
	if not _json_tree_is_bounded(row):
		return _invalid("invalid_message", "消息包含过深或过大的嵌套内容。")
	for field in [
		"protocol_version", "message_type", "room_id", "sender", "sequence",
		"state_revision", "action_id", "request_id", "payload",
	]:
		if not row.has(field):
			return _invalid("missing_field", "消息缺少字段：%s" % field)
	if not _is_integer_number(row["protocol_version"]):
		return _invalid("invalid_field_type", "协议版本字段类型错误。")
	if int(row.get("protocol_version", -1)) != VERSION:
		return _invalid("protocol_mismatch", "联机协议版本不兼容。")
	if not row["message_type"] is String:
		return _invalid("invalid_field_type", "消息类型字段类型错误。")
	var message_type: String = row["message_type"]
	if message_type not in MESSAGE_TYPES:
		return _invalid("unknown_message_type", "未知消息类型。")
	if not row["room_id"] is String or not row["payload"] is Dictionary:
		return _invalid("invalid_field_type", "消息字段类型错误。")
	if (
		not _bounded_string(row["room_id"], MAX_IDENTIFIER_BYTES)
		or not _bounded_string(row["action_id"], MAX_IDENTIFIER_BYTES)
		or not _bounded_string(row["request_id"], MAX_IDENTIFIER_BYTES)
	):
		return _invalid("invalid_field_value", "消息标识符过长。")
	if (
		not _is_integer_number(row["sender"])
		or not _is_integer_number(row["sequence"])
		or not _is_integer_number(row["state_revision"])
		or not row["action_id"] is String
		or not row["request_id"] is String
	):
		return _invalid("invalid_field_type", "消息字段类型错误。")
	if int(row["sender"]) not in [0, 1]:
		return _invalid("invalid_field_value", "消息发送方编号无效。")
	if (
		int(row["sequence"]) <= 0
		or int(row["sequence"]) > 2147483647
		or int(row["state_revision"]) < -1
		or int(row["state_revision"]) > 2147483647
	):
		return _invalid("invalid_field_value", "消息序号或局面版本无效。")
	if not expected_room.is_empty() and str(row["room_id"]) != expected_room:
		return _invalid("wrong_room", "消息房间号不匹配。")
	if expected_sender >= 0 and int(row["sender"]) != expected_sender:
		return _invalid("wrong_sender", "消息发送方不匹配。")
	var sequence := int(row["sequence"])
	if sequence <= last_sequence:
		return _invalid("stale_sequence", "消息序号重复或回退。")
	if sequence != last_sequence + 1:
		return _invalid("sequence_gap", "消息序号不连续。")
	return {"ok": true, "sequence": sequence}


static func validate_payload(message_type: String, payload: Dictionary) -> Dictionary:
	if not _json_tree_is_bounded(payload):
		return _invalid("invalid_payload", "消息内容包含过深或过大的嵌套数据。")
	match message_type:
		WELCOME:
			if (
				not _bounded_int(payload, "player_idx", 0, 1)
				or not _bounded_int(payload, "rules_version", 1, 2147483647)
				or not _bounded_int(payload, "action_version", 1, 2147483647)
			):
				return _invalid("invalid_payload", "欢迎消息缺少玩家编号。")
			return {"ok": true}
		DECK_SELECT:
			if (
				not _bounded_string(payload.get("deck_key"), MAX_IDENTIFIER_BYTES)
				or str(payload.get("deck_key", "")).is_empty()
				or not _bounded_int(payload, "rules_version", 1, 2147483647)
				or not _bounded_int(payload, "action_version", 1, 2147483647)
			):
				return _invalid("invalid_payload", "牌组选择消息缺少牌组。")
			return {"ok": true}
		ACTION_SUBMIT:
			if not payload.get("action") is Dictionary:
				return _invalid("invalid_payload", "动作提交消息缺少动作对象。")
			return _validate_action(payload["action"], true)
		CHOICE_SUBMIT:
			if not payload.get("response") is Dictionary:
				return _invalid("invalid_payload", "选择提交消息缺少响应对象。")
			return _validate_choice_response(payload["response"])
		STATE_UPDATE:
			return _validate_state_update_payload(payload)
		ERROR:
			if (
				(payload.has("code") and not _bounded_string(
					payload["code"], MAX_IDENTIFIER_BYTES))
				or (payload.has("message") and not _bounded_string(
					payload["message"], MAX_TEXT_BYTES))
			):
				return _invalid("invalid_payload", "错误消息字段类型错误。")
			return {"ok": true}
		RESYNC_REQUEST, SURRENDER, PING, PONG:
			if not payload.is_empty():
				return _invalid("invalid_payload", "该消息不接受额外内容。")
			return {"ok": true}
		_:
			return {"ok": true}


static func error_payload(code: String, message: String) -> Dictionary:
	return {"code": code, "message": message}


static func _invalid(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}


static func _is_integer_number(value: Variant) -> bool:
	if value is int:
		return true
	return (
		value is float
		and is_finite(value)
		and value >= -2147483648.0
		and value <= 2147483647.0
		and value == floorf(value)
	)


static func _has_integer(row: Dictionary, field: String) -> bool:
	return row.has(field) and _is_integer_number(row[field])


static func _validate_state_update_payload(payload: Dictionary) -> Dictionary:
	if not payload.get("state") is Dictionary:
		return _invalid("invalid_payload", "状态同步消息缺少局面对象。")
	if payload.has("legal_actions") and not payload["legal_actions"] is Array:
		return _invalid("invalid_payload", "合法动作列表类型错误。")
	if payload.has("presentation_events") and not payload["presentation_events"] is Array:
		return _invalid("invalid_payload", "表现事件列表类型错误。")
	if payload.has("choice_request") and payload["choice_request"] != null:
		if not payload["choice_request"] is Dictionary:
			return _invalid("invalid_payload", "选择请求类型错误。")
	var state: Dictionary = payload["state"]
	if not _bounded_int(state, "revision", 0, 2147483647):
		return _invalid("invalid_payload", "状态同步消息缺少版本号。")
	if not state.get("your") is Dictionary or not state.get("opponent") is Dictionary:
		return _invalid("invalid_payload", "状态同步消息缺少玩家视图。")
	var state_validation := _validate_state_payload(state)
	if not bool(state_validation.get("ok", false)):
		return state_validation
	var legal_actions: Array = payload.get("legal_actions", [])
	if legal_actions.size() > MAX_LEGAL_ACTIONS:
		return _invalid("invalid_payload", "合法动作数量超过限制。")
	for action_value in legal_actions:
		if not action_value is Dictionary:
			return _invalid("invalid_payload", "合法动作必须是对象。")
		var action_validation := _validate_action(action_value, false)
		if not bool(action_validation.get("ok", false)):
			return action_validation
	var presentation_events: Array = payload.get("presentation_events", [])
	if presentation_events.size() > MAX_PRESENTATION_EVENTS:
		return _invalid("invalid_payload", "表现事件数量超过限制。")
	for event_value in presentation_events:
		if not _validate_presentation_event(event_value):
			return _invalid("invalid_payload", "表现事件格式无效。")
	if payload.get("choice_request") != null:
		var choice_validation := _validate_choice_request(payload["choice_request"])
		if not bool(choice_validation.get("ok", false)):
			return choice_validation
	return {"ok": true}


static func _validate_state_payload(state: Dictionary) -> Dictionary:
	if (
		not _bounded_string(state.get("phase"), 32)
		or str(state.get("phase", "")) not in GAME_PHASES
		or not _bounded_int(state, "turn_number", 0, 2147483647)
		or not _bounded_int(state, "active_player_idx", 0, 1)
		or not _bounded_int(state, "first_player_idx", 0, 1)
		or not _bounded_int(state, "winner", -1, 1)
	):
		return _invalid("invalid_payload", "局面基础字段无效。")
	var terminal_phase := str(state["phase"]) == "GAME_OVER"
	var has_winner := int(state["winner"]) >= 0
	if terminal_phase != has_winner:
		return _invalid("invalid_payload", "终局阶段与胜者字段不一致。")
	if (
		not _bounded_string(state.get("stadium_card_id", ""), MAX_IDENTIFIER_BYTES)
		or not state.get("apply_type_matchups", false) is bool
	):
		return _invalid("invalid_payload", "局面字段类型无效。")
	if not _fixed_string_array(state.get("public_deck_keys"), 2, MAX_IDENTIFIER_BYTES):
		return _invalid("invalid_payload", "公开牌组列表无效。")
	if not _bounded_string_array(
		state.get("action_log"), MAX_ACTION_LOG_ENTRIES, MAX_TEXT_BYTES
	):
		return _invalid("invalid_payload", "动作日志无效或超过限制。")
	if (
		not _fixed_int_array(state.get("mulligan_count"), 2, 0, MAX_DECK_CARDS)
		or not _fixed_int_array(state.get("extra_draws"), 2, 0, MAX_DECK_CARDS)
		or not _fixed_bool_array(state.get("setup_ready"), 2)
		or not _bounded_player_index_array(state.get("pending_promotions"), 2)
	):
		return _invalid("invalid_payload", "局面玩家数组无效。")
	var own_validation := _validate_player_payload(state["your"], true)
	if not bool(own_validation.get("ok", false)):
		return own_validation
	return _validate_player_payload(state["opponent"], false)


static func _validate_player_payload(payload: Dictionary, show_hand: bool) -> Dictionary:
	if payload.has("deck") or payload.has("prizes") or (not show_hand and payload.has("hand")):
		return _invalid("invalid_payload", "局面泄露了隐藏牌身份。")
	if not _bounded_string(payload.get("name", ""), MAX_IDENTIFIER_BYTES):
		return _invalid("invalid_payload", "玩家名称无效。")
	if (
		not _bounded_int(payload, "deck_count", 0, MAX_DECK_CARDS)
		or not _bounded_int(payload, "hand_count", 0, MAX_DECK_CARDS)
		or not _bounded_int(payload, "prize_count", 0, MAX_PRIZES)
	):
		return _invalid("invalid_payload", "牌区数量无效或超过限制。")
	if show_hand:
		if not _bounded_string_array(payload.get("hand"), MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES):
			return _invalid("invalid_payload", "手牌列表无效或超过限制。")
		if int(payload["hand_count"]) != Array(payload["hand"]).size():
			return _invalid("invalid_payload", "手牌数量与列表不一致。")
	if not _bounded_string_array(
		payload.get("discard"), MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES
	):
		return _invalid("invalid_payload", "弃牌区无效或超过限制。")
	if not payload.get("bench") is Array or Array(payload["bench"]).size() > MAX_BENCH_SIZE:
		return _invalid("invalid_payload", "备战区无效或超过限制。")
	if payload.get("active") != null and not _validate_pokemon(payload["active"]):
		return _invalid("invalid_payload", "战斗宝可梦数据无效。")
	for pokemon_value in payload["bench"]:
		if pokemon_value != null and not _validate_pokemon(pokemon_value):
			return _invalid("invalid_payload", "备战宝可梦数据无效。")
	for flag in [
		"supporter_played_this_turn", "energy_attached_this_turn",
		"retreated_this_turn", "stadium_played_this_turn",
		"stadium_used_this_turn", "healed_this_turn", "vstar_power_used",
		"was_ko_by_attack",
	]:
		if payload.has(flag) and not payload[flag] is bool:
			return _invalid("invalid_payload", "玩家状态标记类型无效。")
	return {"ok": true}


static func _validate_pokemon(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var pokemon: Dictionary = value
	if (
		not _bounded_string(pokemon.get("card_id"), MAX_IDENTIFIER_BYTES)
		or str(pokemon.get("card_id", "")).is_empty()
		or not _bounded_int(pokemon, "damage_counters", 0, 10000)
		or not _bounded_string(pokemon.get("attached_tool_id", ""), MAX_IDENTIFIER_BYTES)
	):
		return false
	if (
		not _bounded_string_array(
			pokemon.get("energy_card_ids", []), MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES)
		or not _bounded_string_array(
			pokemon.get("evolution_stack_ids", []), MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES)
		or not _bounded_string_array(
			pokemon.get("used_abilities", []), 32, MAX_IDENTIFIER_BYTES)
	):
		return false
	var statuses: Variant = pokemon.get("status_conditions", [])
	if not statuses is Array or Array(statuses).size() > STATUS_CONDITIONS.size():
		return false
	for status_value in statuses:
		if not status_value is String or str(status_value) not in STATUS_CONDITIONS:
			return false
	if not pokemon.get("attack_locked_names", {}) is Dictionary:
		return false
	if Dictionary(pokemon.get("attack_locked_names", {})).size() > 32:
		return false
	if not pokemon.get("modifiers", []) is Array or Array(pokemon.get("modifiers", [])).size() > 32:
		return false
	for modifier_value in pokemon.get("modifiers", []):
		if not modifier_value is Dictionary or not _json_tree_is_bounded(modifier_value):
			return false
	for flag in [
		"can_evolve_this_turn", "placed_this_turn", "damage_prevented_next_turn",
		"all_prevented_next_turn", "attack_locked", "dazzled",
	]:
		if pokemon.has(flag) and not pokemon[flag] is bool:
			return false
	for integer_field in [
		"outgoing_damage_reduction_next_turn", "paralyzed_since_turn",
	]:
		if pokemon.has(integer_field) and not _is_integer_number(pokemon[integer_field]):
			return false
	return true


static func _validate_action(value: Variant, require_action_id: bool) -> Dictionary:
	if not value is Dictionary:
		return _invalid("invalid_payload", "动作必须是对象。")
	var action: Dictionary = value
	if (
		not _bounded_string(action.get("action"), 64)
		or str(action.get("action", "")) not in GAME_ACTIONS
		or not action.get("params") is Dictionary
		or not action.get("terminal") is bool
		or not _bounded_int(action, "actor", 0, 1)
		or not _bounded_string(action.get("action_id", ""), MAX_IDENTIFIER_BYTES)
	):
		return _invalid("invalid_payload", "动作字段无效。")
	if require_action_id and str(action.get("action_id", "")).is_empty():
		return _invalid("invalid_payload", "动作缺少唯一 ID。")
	if not _json_tree_is_bounded(action["params"]):
		return _invalid("invalid_payload", "动作参数无效。")
	if not _validate_action_params(action["params"]):
		return _invalid("invalid_payload", "动作参数字段类型无效。")
	for ref_field in ["source", "target"]:
		var ref_value: Variant = action.get(ref_field)
		if ref_value != null and not _validate_entity_ref(ref_value):
			return _invalid("invalid_payload", "动作实体引用无效。")
	return {"ok": true}


static func _validate_action_params(params: Dictionary) -> bool:
	for field_and_maximum in [
		["hand_idx", MAX_DECK_CARDS - 1],
		["bench_idx", MAX_BENCH_SIZE - 1],
		["attack_idx", 31],
	]:
		var field := str(field_and_maximum[0])
		if params.has(field) and not _bounded_int(
			params, field, 0, int(field_and_maximum[1])
		):
			return false
	for field in ["slot", "target", "target_slot", "ability_name"]:
		if params.has(field) and not _bounded_string(params[field], MAX_IDENTIFIER_BYTES):
			return false
	if params.has("energy_indices"):
		var indices: Variant = params["energy_indices"]
		if not indices is Array or Array(indices).size() > MAX_DECK_CARDS:
			return false
		for index_value in indices:
			if (
				not _is_integer_number(index_value)
				or int(index_value) < 0
				or int(index_value) >= MAX_DECK_CARDS
			):
				return false
	return true


static func _validate_entity_ref(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var ref: Dictionary = value
	return (
		_bounded_string(ref.get("kind", ""), 32)
		and _bounded_int(ref, "player", -1, 1)
		and _bounded_string(ref.get("zone", ""), 32)
		and _bounded_string(ref.get("slot", ""), 32)
		and _bounded_int(ref, "index", -1, MAX_DECK_CARDS)
		and _bounded_string(ref.get("attachment_type", ""), 32)
		and _bounded_string(ref.get("card_id", ""), MAX_IDENTIFIER_BYTES)
	)


static func _validate_choice_response(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _invalid("invalid_payload", "选择响应必须是对象。")
	var response: Dictionary = value
	if (
		not _bounded_string(response.get("request_id"), MAX_IDENTIFIER_BYTES)
		or str(response.get("request_id", "")).is_empty()
		or not _bounded_string_array(
			response.get("option_ids"), MAX_CHOICE_OPTIONS, MAX_IDENTIFIER_BYTES)
		or not response.get("cancelled") is bool
	):
		return _invalid("invalid_payload", "选择响应字段无效。")
	return {"ok": true}


static func _validate_choice_request(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _invalid("invalid_payload", "选择请求必须是对象。")
	var request: Dictionary = value
	if (
		not _bounded_string(request.get("request_id"), MAX_IDENTIFIER_BYTES)
		or str(request.get("request_id", "")).is_empty()
		or not _bounded_string(request.get("request_type"), 64)
		or not _bounded_int(request, "player", 0, 1)
		or not _bounded_string(request.get("prompt", ""), MAX_TEXT_BYTES)
		or not _bounded_int(request, "min_select", 0, MAX_CHOICE_OPTIONS)
		or not _bounded_int(request, "max_select", 0, MAX_CHOICE_OPTIONS)
		or not request.get("allow_duplicates") is bool
		or not request.get("can_cancel") is bool
		or not request.get("options") is Array
		or not request.get("metadata", {}) is Dictionary
	):
		return _invalid("invalid_payload", "选择请求字段无效。")
	if int(request["min_select"]) > int(request["max_select"]):
		return _invalid("invalid_payload", "选择数量范围无效。")
	if not _validate_choice_metadata(request.get("metadata", {})):
		return _invalid("invalid_payload", "选择请求 metadata 字段无效。")
	var options: Array = request["options"]
	if options.size() > MAX_CHOICE_OPTIONS:
		return _invalid("invalid_payload", "选择项数量超过限制。")
	for option_value in options:
		if not option_value is Dictionary:
			return _invalid("invalid_payload", "选择项必须是对象。")
		var option: Dictionary = option_value
		if (
			not _bounded_string(option.get("option_id"), MAX_IDENTIFIER_BYTES)
			or str(option.get("option_id", "")).is_empty()
			or not _bounded_string(option.get("label", ""), MAX_TEXT_BYTES)
			or not _json_tree_is_bounded(option)
		):
			return _invalid("invalid_payload", "选择项字段无效。")
		if option.has("ref") and option["ref"] != null:
			if not _validate_entity_ref(option["ref"]):
				return _invalid("invalid_payload", "选择项实体引用无效。")
		if option.has("value") and not _validate_choice_option_value(option["value"]):
			return _invalid("invalid_payload", "选择项 value 字段无效。")
	return {"ok": true}


static func _validate_choice_metadata(metadata: Dictionary) -> bool:
	if metadata.has("revision") and not _bounded_int(
		metadata, "revision", 0, 2147483647
	):
		return false
	if metadata.has("max_per_target") and not _bounded_int(
		metadata, "max_per_target", 0, 2147483647
	):
		return false
	if metadata.has("top_card_id") and not _bounded_string(
		metadata["top_card_id"], MAX_IDENTIFIER_BYTES
	):
		return false
	if metadata.has("revealed_card_ids") and not _bounded_string_array(
		metadata["revealed_card_ids"], MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES
	):
		return false
	if metadata.has("predetermined_flips"):
		var flips: Variant = metadata["predetermined_flips"]
		if not flips is Array or Array(flips).size() > MAX_CHOICE_OPTIONS:
			return false
		for flip in flips:
			if not flip is bool:
				return false
	return true


static func _validate_choice_option_value(value: Variant) -> bool:
	if not value is Dictionary:
		return (
			value == null
			or value is bool
			or value is int
			or (value is float and is_finite(value))
			or value is String
		)
	var row: Dictionary = value
	if row.has("index") and not _bounded_int(row, "index", -1, MAX_DECK_CARDS):
		return false
	for field in ["player", "target_player"]:
		if row.has(field) and not _bounded_int(row, field, -1, 1):
			return false
	for field in ["slot", "card_id", "attachment_type"]:
		if row.has(field) and not _bounded_string(row[field], MAX_IDENTIFIER_BYTES):
			return false
	for field in ["base_name", "evolution_name"]:
		if row.has(field) and not _bounded_string(row[field], MAX_TEXT_BYTES):
			return false
	return true


static func _validate_presentation_event(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var event: Dictionary = value
	if (
		not _bounded_string(event.get("event_id", ""), MAX_IDENTIFIER_BYTES)
		or not _bounded_string(event.get("event_type", ""), MAX_IDENTIFIER_BYTES)
		or not _bounded_int(event, "revision", 0, 2147483647)
		or not _bounded_int(event, "actor", -1, 1)
		or not _bounded_string(event.get("card_id", ""), MAX_IDENTIFIER_BYTES)
		or not _bounded_int(event, "amount", 0, 2147483647)
		or not _bounded_string(event.get("visibility", "public"), 16)
		or str(event.get("visibility", "public")) not in ["public", "owner", "private"]
		or not event.get("data", {}) is Dictionary
		or not event.get("source", {}) is Dictionary
		or not event.get("target", {}) is Dictionary
	):
		return false
	return (
		_validate_presentation_endpoint(event["source"])
		and _validate_presentation_endpoint(event["target"])
		and _validate_presentation_data(event["data"])
		and _json_tree_is_bounded(event)
	)


static func _validate_presentation_endpoint(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var endpoint: Dictionary = value
	if not _bounded_int(endpoint, "player", -1, 1):
		return false
	for field in ["zone", "slot"]:
		if endpoint.has(field) and not _bounded_string(
			endpoint[field], MAX_IDENTIFIER_BYTES
		):
			return false
	if endpoint.has("index") and not _bounded_int(
		endpoint, "index", -1, MAX_DECK_CARDS
	):
		return false
	return true


static func _validate_presentation_data(data: Dictionary) -> bool:
	for field in ["player", "actor", "source_player", "target_player", "winner"]:
		if data.has(field) and not _bounded_int(data, field, -1, 1):
			return false
	for field_and_bounds in [
		["bench_idx", -1, MAX_BENCH_SIZE - 1],
		["source_index", -1, MAX_DECK_CARDS],
		["count", 0, MAX_DECK_CARDS],
		["amount", 0, 2147483647],
		["turn", 0, 2147483647],
	]:
		var field := str(field_and_bounds[0])
		if data.has(field) and not _bounded_int(
			data, field, int(field_and_bounds[1]), int(field_and_bounds[2])
		):
			return false
	for field in [
		"slot", "source_slot", "target_slot", "source_zone", "target_zone",
		"card_id", "source_card_id", "target_card_id", "status",
	]:
		if data.has(field) and not _bounded_string(data[field], MAX_TEXT_BYTES):
			return false
	for field in ["card_ids", "cards", "selected_card_ids"]:
		if data.has(field) and not _bounded_string_array(
			data[field], MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES
		):
			return false
	if data.has("results"):
		var results: Variant = data["results"]
		if not results is Array or Array(results).size() > MAX_CHOICE_OPTIONS:
			return false
		for result in results:
			if not result is bool:
				return false
	return true


static func _bounded_string(value: Variant, max_bytes: int) -> bool:
	return value is String and value.to_utf8_buffer().size() <= max_bytes


static func _bounded_int(
	row: Dictionary,
	field: String,
	minimum: int,
	maximum: int,
) -> bool:
	return (
		_has_integer(row, field)
		and int(row[field]) >= minimum
		and int(row[field]) <= maximum
	)


static func _bounded_string_array(
	value: Variant,
	max_items: int,
	max_string_bytes: int,
) -> bool:
	if not value is Array or Array(value).size() > max_items:
		return false
	for item in value:
		if not _bounded_string(item, max_string_bytes):
			return false
	return true


static func _fixed_string_array(
	value: Variant,
	expected_items: int,
	max_string_bytes: int,
) -> bool:
	return (
		value is Array
		and Array(value).size() == expected_items
		and _bounded_string_array(value, expected_items, max_string_bytes)
	)


static func _fixed_int_array(
	value: Variant,
	expected_items: int,
	minimum: int,
	maximum: int,
) -> bool:
	if not value is Array or Array(value).size() != expected_items:
		return false
	for item in value:
		if not _is_integer_number(item) or int(item) < minimum or int(item) > maximum:
			return false
	return true


static func _fixed_bool_array(value: Variant, expected_items: int) -> bool:
	if not value is Array or Array(value).size() != expected_items:
		return false
	for item in value:
		if not item is bool:
			return false
	return true


static func _bounded_player_index_array(value: Variant, max_items: int) -> bool:
	if not value is Array or Array(value).size() > max_items:
		return false
	for item in value:
		if not _is_integer_number(item) or int(item) not in [0, 1]:
			return false
	return true


static func _json_tree_is_bounded(value: Variant, depth: int = 0) -> bool:
	if depth > MAX_JSON_DEPTH:
		return false
	if value == null or value is bool or value is int:
		return true
	if value is float:
		return is_finite(value)
	if value is String:
		return _bounded_string(value, MAX_TEXT_BYTES * 4)
	if value is Array:
		var values: Array = value
		if values.size() > MAX_GENERIC_CONTAINER_ITEMS:
			return false
		for item in values:
			if not _json_tree_is_bounded(item, depth + 1):
				return false
		return true
	if value is Dictionary:
		var row: Dictionary = value
		if row.size() > MAX_GENERIC_CONTAINER_ITEMS:
			return false
		for key_value in row.keys():
			if (
				not _bounded_string(key_value, MAX_IDENTIFIER_BYTES)
				or not _json_tree_is_bounded(row[key_value], depth + 1)
			):
				return false
		return true
	return false


static func _json_tree_is_serializable(value: Variant, depth: int = 0) -> bool:
	if depth > MAX_JSON_DEPTH:
		return false
	if value == null or value is bool or value is int or value is String:
		return true
	if value is float:
		return is_finite(value)
	if value is Array:
		for item in value:
			if not _json_tree_is_serializable(item, depth + 1):
				return false
		return true
	if value is Dictionary:
		var row: Dictionary = value
		for key_value in row:
			if (
				not key_value is String
				or not _json_tree_is_serializable(row[key_value], depth + 1)
			):
				return false
		return true
	return false
