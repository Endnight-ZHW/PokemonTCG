class_name ProtocolV6
extends RefCounted

const VERSION := 6
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
const STATUS_CONDITIONS: Array[String] = [
	"POISONED", "BURNED", "ASLEEP", "PARALYZED", "CONFUSED",
]
const SETUP_STAGES: Array[String] = [
	"TURN_ORDER", "INITIAL_PLACEMENT", "BONUS_DRAW", "BONUS_PLACEMENT", "COMPLETE",
]
const RESULT_STATUSES: Array[String] = ["ONGOING", "WIN", "DRAW"]
const RULES_PROFILE_ID := "CN_MAINLAND_3_1_0"

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
		var received := int(row.get("protocol_version", -1))
		var legacy_hint := "；旧 v5 房间不能恢复" if received == 5 else ""
		return _invalid(
			"protocol_mismatch",
			"联机协议 v%d 与当前 v%d 不兼容%s。" % [
				received, VERSION, legacy_hint,
			],
		)
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
				or (payload.has("resume") and not payload["resume"] is bool)
				or str(payload.get("rules_profile_id", "")) != RULES_PROFILE_ID
				or not _validate_rules_options(payload.get("rules_options", {}))
			):
				return _invalid("invalid_payload", "欢迎消息缺少玩家编号。")
			return {"ok": true}
		DECK_SELECT:
			if (
				not _bounded_string(payload.get("deck_key"), MAX_IDENTIFIER_BYTES)
				or str(payload.get("deck_key", "")).is_empty()
				or not _bounded_int(payload, "rules_version", 1, 2147483647)
				or not _bounded_int(payload, "action_version", 1, 2147483647)
				or (payload.has("resume") and not payload["resume"] is bool)
				or str(payload.get("rules_profile_id", "")) != RULES_PROFILE_ID
				or not _validate_rules_options(payload.get("rules_options", {}))
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
	if payload.has("legal_actions"):
		return _invalid("invalid_payload", "Protocol v6 不接受展开式合法动作。")
	if not payload.get("legal_action_groups", []) is Array:
		return _invalid("invalid_payload", "合法动作分组类型错误。")
	if not _bounded_string(
		payload.get("legal_action_error", ""), MAX_IDENTIFIER_BYTES
	):
		return _invalid("invalid_payload", "合法动作错误码无效。")
	if payload.has("presentation_events") and not payload["presentation_events"] is Array:
		return _invalid("invalid_payload", "表现事件列表类型错误。")
	if payload.has("choice_request") and payload["choice_request"] != null:
		if not payload["choice_request"] is Dictionary:
			return _invalid("invalid_payload", "选择请求类型错误。")
	if payload.has("wait_context") and payload["wait_context"] != null:
		if not _validate_wait_context(payload["wait_context"]):
			return _invalid("invalid_payload", "等待上下文格式无效。")
	var state: Dictionary = payload["state"]
	if not _bounded_int(state, "revision", 0, 2147483647):
		return _invalid("invalid_payload", "状态同步消息缺少版本号。")
	if not state.get("your") is Dictionary or not state.get("opponent") is Dictionary:
		return _invalid("invalid_payload", "状态同步消息缺少玩家视图。")
	var state_validation := _validate_state_payload(state)
	if not bool(state_validation.get("ok", false)):
		return state_validation
	var legal_groups: Array = payload.get("legal_action_groups", [])
	if legal_groups.size() > MAX_LEGAL_ACTIONS:
		return _invalid("invalid_payload", "合法动作数量超过限制。")
	for group_value in legal_groups:
		var group_validation := _validate_legal_action_group(group_value)
		if not bool(group_validation.get("ok", false)):
			return group_validation
		if int(Dictionary(group_value).get("base_revision", -1)) != int(state["revision"]):
			return _invalid("invalid_payload", "合法动作分组版本与局面不一致。")
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
		if int(Dictionary(payload["choice_request"]).get(
			"base_revision", -1)) != int(state["revision"]):
			return _invalid("invalid_payload", "选择视图版本与局面不一致。")
	return {"ok": true}


static func _validate_wait_context(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var context: Dictionary = value
	return (
		context.size() == 2
		and _bounded_int(context, "waiting_for_player", 0, 1)
		and _bounded_string(context.get("choice_kind", ""), 32)
		and str(context.get("choice_kind", "")) in [
			"attachment", "energy", "coin", "choice", "setup", "prize", "trigger",
		]
	)


static func _validate_state_payload(state: Dictionary) -> Dictionary:
	if (
		not _bounded_string(state.get("phase"), 32)
		or str(state.get("phase", "")) not in GAME_PHASES
		or not _bounded_int(state, "turn_number", 0, 2147483647)
		or not _bounded_int(state, "active_player_idx", 0, 1)
		or not _bounded_int(state, "first_player_idx", 0, 1)
		or not _bounded_int(state, "winner", -1, 1)
		or not _bounded_string(state.get("rules_profile_id", ""), 64)
		or str(state.get("rules_profile_id", "")) != RULES_PROFILE_ID
		or not _validate_rules_options(state.get("rules_options", {}))
		or not _bounded_string(state.get("setup_stage", ""), 32)
		or str(state.get("setup_stage", "")) not in SETUP_STAGES
		or not _bounded_int(state, "setup_actor_idx", -1, 1)
		or not _bounded_int(state, "opening_coin_winner_idx", -1, 1)
		or not _bounded_int(state, "mulligan_bonus_max", 0, MAX_DECK_CARDS)
		or not _bounded_string(state.get("result_status", ""), 16)
		or str(state.get("result_status", "")) not in RESULT_STATUSES
		or not _bounded_string(state.get("result_reason", ""), MAX_TEXT_BYTES)
		or not _bounded_int(state, "stadium_owner_idx", -1, 1)
	):
		return _invalid("invalid_payload", "局面基础字段无效。")
	var terminal_phase := str(state["phase"]) == "GAME_OVER"
	var result_status := str(state["result_status"])
	if terminal_phase != (result_status != "ONGOING"):
		return _invalid("invalid_payload", "终局阶段与结果状态不一致。")
	if (
		(result_status == "ONGOING" and int(state["winner"]) != -1)
		or (result_status == "WIN" and int(state["winner"]) not in [0, 1])
		or (result_status == "DRAW" and int(state["winner"]) != -1)
	):
		return _invalid("invalid_payload", "结果状态与胜者字段不一致。")
	if not _validate_result_conditions(state.get("result_conditions", [])):
		return _invalid("invalid_payload", "胜负条件记录无效。")
	if (
		not _bounded_string(state.get("stadium_card_id", ""), MAX_IDENTIFIER_BYTES)
		or not state.get("apply_type_matchups", false) is bool
		or bool(state.get("apply_type_matchups", false)) != bool(
			Dictionary(state["rules_options"]).get("apply_type_matchups", false)
		)
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
	var setup_board_hidden := str(state["setup_stage"]) != "COMPLETE"
	var own_validation := _validate_player_payload(state["your"], true, false)
	if not bool(own_validation.get("ok", false)):
		return own_validation
	return _validate_player_payload(
		state["opponent"],
		false,
		setup_board_hidden,
	)


static func _validate_player_payload(
	payload: Dictionary,
	show_hand: bool,
	require_hidden_board: bool,
) -> Dictionary:
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
	if payload.get("active") != null and not (
		_validate_hidden_pokemon(payload["active"])
		if require_hidden_board
		else _validate_pokemon(payload["active"])
	):
		return _invalid("invalid_payload", "战斗宝可梦数据无效。")
	for pokemon_value in payload["bench"]:
		if pokemon_value != null and not (
			_validate_hidden_pokemon(pokemon_value)
			if require_hidden_board
			else _validate_pokemon(pokemon_value)
		):
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
	var allowed_fields := [
		"card_id", "damage_counters", "energy_card_ids", "attached_tool_id",
		"status_conditions", "evolution_stack_ids", "can_evolve_this_turn",
		"placed_this_turn", "used_abilities", "healed_this_turn",
		"paralyzed_since_turn", "modifiers",
	]
	for key_value in pokemon.keys():
		if str(key_value) not in allowed_fields:
			return false
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
	if not pokemon.get("modifiers", []) is Array or Array(pokemon.get("modifiers", [])).size() > 32:
		return false
	for modifier_value in pokemon.get("modifiers", []):
		if (
			not modifier_value is Dictionary
			or not _json_tree_is_bounded(modifier_value)
			or not PokemonState.modifier_wire_validation_error(
				modifier_value).is_empty()
		):
			return false
	for flag in [
		"can_evolve_this_turn", "placed_this_turn", "healed_this_turn",
	]:
		if pokemon.has(flag) and not pokemon[flag] is bool:
			return false
	for integer_field in ["paralyzed_since_turn"]:
		if pokemon.has(integer_field) and not _is_integer_number(pokemon[integer_field]):
			return false
	return true


static func _validate_action(value: Variant, require_action_id: bool) -> Dictionary:
	if value is Dictionary:
		var action: Dictionary = value
		if (
			not _bounded_string(action.get("action_id", ""), MAX_IDENTIFIER_BYTES)
			or not _bounded_string(action.get("kind", ""), 64)
		):
			return _invalid("invalid_payload", "动作标识字段无效。")
	var validation := GameAction.validate_wire_dict(value, require_action_id)
	if not bool(validation.get("ok", false)):
		return _invalid(
			str(validation.get("code", "invalid_payload")),
			str(validation.get("message", "动作字段无效。")),
		)
	return {"ok": true}


static func _validate_legal_action_group(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _invalid("invalid_payload", "合法动作分组必须是对象。")
	var group: Dictionary = value
	var fields := [
		"group_id", "base_revision", "actor", "kind", "source", "payload", "targets",
	]
	if group.size() != fields.size():
		return _invalid("invalid_payload", "合法动作分组包含缺失或多余字段。")
	for field in fields:
		if not group.has(field):
			return _invalid("invalid_payload", "合法动作分组缺少字段。")
	if (
		not _bounded_string(group.get("group_id", ""), MAX_IDENTIFIER_BYTES)
		or str(group.get("group_id", "")).is_empty()
		or not _bounded_int(group, "base_revision", 0, 2147483647)
		or not _bounded_int(group, "actor", 0, 1)
		or not _bounded_string(group.get("kind", ""), 64)
		or not group.get("payload") is Dictionary
		or not group.get("targets") is Array
		or Array(group["targets"]).size() > MAX_CHOICE_OPTIONS
	):
		return _invalid("invalid_payload", "合法动作分组字段无效。")
	if group["source"] != null and not _validate_entity_ref(group["source"]):
		return _invalid("invalid_payload", "合法动作来源引用无效。")
	var targets: Array = group["targets"]
	var probe_targets: Array = targets if not targets.is_empty() else [null]
	var seen_targets: Dictionary = {}
	for target_value in probe_targets:
		if target_value != null:
			if not _validate_entity_ref(target_value):
				return _invalid("invalid_payload", "合法动作目标引用无效。")
			var signature := JSON.stringify(target_value)
			if seen_targets.has(signature):
				return _invalid("invalid_payload", "合法动作目标重复。")
			seen_targets[signature] = true
		var action := GameAction.create(
			str(group["kind"]),
			Dictionary(group["payload"]),
			int(group["actor"]),
			EntityRef.from_dict(group["source"]) if group["source"] is Dictionary else null,
			EntityRef.from_dict(target_value) if target_value is Dictionary else null,
			"",
			int(group["base_revision"]),
		)
		var action_validation := GameAction.validate_instance(action, true)
		if not bool(action_validation.get("ok", false)):
			return _invalid(
				str(action_validation.get("code", "invalid_payload")),
				str(action_validation.get("message", "合法动作分组无效。")),
			)
	return {"ok": true}


static func _validate_entity_ref(value: Variant) -> bool:
	return EntityRef.validate_dict(value).is_empty()


static func _validate_choice_response(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _invalid("invalid_payload", "选择响应必须是对象。")
	var response: Dictionary = value
	if response.size() != 3 or not (
		response.has("request_id")
		and response.has("option_ids")
		and response.has("cancelled")
	):
		return _invalid("invalid_payload", "选择响应包含缺失或多余字段。")
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
	var required_fields: Array[String] = [
		"schema_version", "request_id", "base_revision", "player",
		"request_type", "prompt", "options", "min_select", "max_select",
		"allow_duplicates", "can_cancel", "presentation",
	]
	if request.size() != required_fields.size():
		return _invalid("invalid_payload", "ChoiceView 包含缺失或多余字段。")
	for field in required_fields:
		if not request.has(field):
			return _invalid("invalid_payload", "ChoiceView 缺少字段：%s" % field)
	if (
		not _bounded_int(request, "schema_version", ChoiceView.SCHEMA_VERSION, ChoiceView.SCHEMA_VERSION)
		or not _bounded_string(request.get("request_id"), MAX_IDENTIFIER_BYTES)
		or str(request.get("request_id", "")).is_empty()
		or not _bounded_int(request, "base_revision", 0, 2147483647)
		or not _bounded_string(request.get("request_type"), 64)
		or str(request.get("request_type", "")).is_empty()
		or not _bounded_int(request, "player", 0, 1)
		or not _bounded_string(request.get("prompt", ""), MAX_TEXT_BYTES)
		or not _bounded_int(request, "min_select", 0, MAX_CHOICE_OPTIONS)
		or not _bounded_int(request, "max_select", 0, MAX_CHOICE_OPTIONS)
		or not request.get("allow_duplicates") is bool
		or not request.get("can_cancel") is bool
		or not request.get("options") is Array
		or not request.get("presentation") is Dictionary
	):
		return _invalid("invalid_payload", "ChoiceView 字段无效。")
	if int(request["min_select"]) > int(request["max_select"]):
		return _invalid("invalid_payload", "选择数量范围无效。")
	if not _validate_choice_presentation(request["presentation"]):
		return _invalid("invalid_payload", "ChoiceView presentation 字段无效。")
	var is_hidden_prize_choice := str(request["request_type"]) == "select_prize"
	if is_hidden_prize_choice:
		var prize_presentation: Dictionary = request["presentation"]
		for identity_field in [
			"card_ids", "revealed_card_ids", "top_card_id", "attachment_refs",
			"source_card_id", "card_id", "labels",
		]:
			if prize_presentation.has(identity_field):
				return _invalid(
					"invalid_payload",
					"Prize ChoiceView 不得公开卡牌身份。",
				)
	var options: Array = request["options"]
	if options.size() > MAX_CHOICE_OPTIONS:
		return _invalid("invalid_payload", "选择项数量超过限制。")
	for option_value in options:
		if not option_value is Dictionary:
			return _invalid("invalid_payload", "选择项必须是对象。")
		var option: Dictionary = option_value
		if option.size() not in [2, 3] or not option.has("option_id") or not option.has("label"):
			return _invalid("invalid_payload", "选择项包含缺失或多余字段。")
		for option_field in option:
			if option_field not in ["option_id", "label", "ref"]:
				return _invalid("invalid_payload", "选择项包含非公开字段。")
		if (
			not _bounded_string(option.get("option_id"), MAX_IDENTIFIER_BYTES)
			or str(option.get("option_id", "")).is_empty()
			or not _bounded_string(option.get("label", ""), MAX_TEXT_BYTES)
			or not _json_tree_is_bounded(option)
		):
			return _invalid("invalid_payload", "选择项字段无效。")
		if option.has("ref") and option["ref"] != null:
			if is_hidden_prize_choice:
				return _invalid(
					"invalid_payload",
					"Prize ChoiceView 不得公开实体引用。",
				)
			if not _validate_entity_ref(option["ref"]):
				return _invalid("invalid_payload", "选择项实体引用无效。")
	return {"ok": true}


static func _validate_choice_presentation(presentation: Dictionary) -> bool:
	if not _json_tree_is_bounded(presentation):
		return false
	for field in presentation:
		if not field is String or str(field) not in ChoiceView.PRESENTATION_FIELDS:
			return false
	if presentation.has("max_per_target") and not _bounded_int(
		presentation, "max_per_target", 0, 2147483647
	):
		return false
	for field in ["domain", "purpose", "decision_mode", "cancel_mode", "hook"]:
		if presentation.has(field) and not _bounded_string(
			presentation[field], 64
		):
			return false
	for field in ["source_player", "target_player", "owner"]:
		if presentation.has(field) and not _bounded_int(
			presentation, field, -1, 1
		):
			return false
	for source_field in ["source_slot", "source_zone", "target_slot", "energy_type"]:
		if presentation.has(source_field) and not _bounded_string(
			presentation[source_field], MAX_IDENTIFIER_BYTES
		):
			return false
	for flag in ["same_source", "same_target", "cancels_action"]:
		if presentation.has(flag) and not presentation[flag] is bool:
			return false
	for count_field in [
		"required_units", "pokemon_count", "energy_count", "amount", "count",
	]:
		if presentation.has(count_field) and not _bounded_int(
			presentation, count_field, 0, 2147483647
		):
			return false
	for id_field in ["top_card_id", "source_card_id", "card_id", "trigger_id"]:
		if presentation.has(id_field) and not _bounded_string(
			presentation[id_field], MAX_IDENTIFIER_BYTES
		):
			return false
	for ids_field in [
		"card_ids", "revealed_card_ids", "target_slots", "trigger_ids", "labels",
	]:
		if presentation.has(ids_field) and not _bounded_string_array(
			presentation[ids_field], MAX_CHOICE_OPTIONS, MAX_TEXT_BYTES
		):
			return false
	if presentation.has("attachment_refs"):
		var refs: Variant = presentation["attachment_refs"]
		if not refs is Array or Array(refs).size() > MAX_CHOICE_OPTIONS:
			return false
		for ref in refs:
			if not _validate_entity_ref(ref):
				return false
	if presentation.has("predetermined_flips"):
		var flips: Variant = presentation["predetermined_flips"]
		if not flips is Array or Array(flips).size() > MAX_CHOICE_OPTIONS:
			return false
		for flip in flips:
			if not flip is bool:
				return false
	if presentation.has("category_limits"):
		if not presentation["category_limits"] is Dictionary:
			return false
		var limits: Dictionary = presentation["category_limits"]
		if limits.size() > MAX_CHOICE_OPTIONS:
			return false
		for category in limits:
			if (
				not category is String
				or not _bounded_string(category, MAX_IDENTIFIER_BYTES)
				or not _is_integer_number(limits[category])
				or int(limits[category]) < 0
				or int(limits[category]) > MAX_CHOICE_OPTIONS
			):
				return false
	if presentation.has("selection_mode") and not _bounded_string(
		presentation["selection_mode"], 64
	):
		return false
	return true
static func _validate_presentation_event(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var event: Dictionary = value
	if (
		not _bounded_string(event.get("event_id", ""), MAX_IDENTIFIER_BYTES)
		or not _bounded_string(event.get("event_type", ""), MAX_IDENTIFIER_BYTES)
		or not PresentationEvent.is_supported_event_type(str(event.get("event_type", "")))
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
	if (
		str(event.get("event_type", "")) == "cards_revealed"
		and not _validate_cards_revealed_data(event["data"])
	):
		return false
	if (
		str(event.get("event_type", "")) == "turn_order_chosen"
		and not _validate_turn_order_chosen_data(event["data"])
	):
		return false
	if (
		str(event.get("event_type", "")) == "setup_revealed"
		and not _validate_setup_revealed_data(event["data"])
	):
		return false
	return (
		_validate_presentation_endpoint(event["source"])
		and _validate_presentation_endpoint(event["target"])
		and _validate_presentation_data(event["data"])
		and _json_tree_is_bounded(event)
	)


static func _validate_cards_revealed_data(data: Dictionary) -> bool:
	if not data.has("cards") or not _validate_presentation_cards(data["cards"]):
		return false
	if str(data.get("purpose", "")) == "mulligan":
		return (
			_bounded_int(data, "player", 0, 1)
			and _bounded_int(data, "round", 1, 64)
			and _bounded_string_array(
				data.get("card_ids", []), MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES)
			and Array(data["cards"]) == Array(data["card_ids"])
			and Array(data["cards"]).size() == 7
		)
	var summary_value: Variant = data.get("summary")
	if not summary_value is Dictionary:
		return false
	var summary: Dictionary = summary_value
	if (
		not _bounded_string(summary.get("kind"), 64)
		or str(summary.get("kind", "")).is_empty()
		or not _bounded_int(summary, "matched_count", 0, MAX_DECK_CARDS)
		or not _bounded_int(summary, "amount", 0, 2147483647)
	):
		return false
	return int(summary["matched_count"]) <= Array(data["cards"]).size()


static func _validate_turn_order_chosen_data(data: Dictionary) -> bool:
	return (
		data.size() == 2
		and _bounded_int(data, "coin_winner", 0, 1)
		and _bounded_int(data, "first_player", 0, 1)
	)


static func _validate_setup_revealed_data(data: Dictionary) -> bool:
	if not _bounded_int(data, "first_player", 0, 1):
		return false
	var players_value: Variant = data.get("players")
	if not players_value is Array or Array(players_value).size() != 2:
		return false
	for player_value in Array(players_value):
		if not player_value is Dictionary:
			return false
		var player: Dictionary = player_value
		if (
			player.size() != 2
			or not _bounded_string(player.get("active", ""), MAX_IDENTIFIER_BYTES)
			or str(player.get("active", "")).is_empty()
			or not _bounded_string_array(
				player.get("bench", []), MAX_BENCH_SIZE, MAX_IDENTIFIER_BYTES)
		):
			return false
	return true


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
	for field in [
		"player", "actor", "source_player", "target_player", "winner",
		"loser", "first_player", "coin_winner",
	]:
		if data.has(field) and not _bounded_int(data, field, -1, 1):
			return false
	for field_and_bounds in [
		["bench_idx", -1, MAX_BENCH_SIZE - 1],
		["source_index", -1, MAX_DECK_CARDS],
		["count", 0, MAX_DECK_CARDS],
		["amount", 0, 2147483647],
		["turn", 0, 2147483647],
		["round", 0, 64],
	]:
		var field := str(field_and_bounds[0])
		if data.has(field) and not _bounded_int(
			data, field, int(field_and_bounds[1]), int(field_and_bounds[2])
		):
			return false
	for field in [
		"slot", "source_slot", "target_slot", "source_zone", "target_zone",
		"card_id", "source_card_id", "target_card_id", "status", "purpose",
		"reason",
	]:
		if data.has(field) and not _bounded_string(data[field], MAX_TEXT_BYTES):
			return false
	for field in ["card_ids", "selected_card_ids"]:
		if data.has(field) and not _bounded_string_array(
			data[field], MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES
		):
			return false
	if data.has("cards") and not _validate_presentation_cards(data["cards"]):
		return false
	if data.has("results"):
		var results: Variant = data["results"]
		if not results is Array or Array(results).size() > MAX_CHOICE_OPTIONS:
			return false
		for result in results:
			if not result is bool:
				return false
	return true


static func _validate_hidden_pokemon(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var row: Dictionary = value
	return (
		row.size() == 1
		and row.get("hidden") is bool
		and bool(row["hidden"])
	)


static func _validate_rules_options(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var options: Dictionary = value
	return (
		options.size() == 1
		and options.has("apply_type_matchups")
		and options["apply_type_matchups"] is bool
	)


static func _validate_result_conditions(value: Variant) -> bool:
	if not value is Array or Array(value).size() != 2:
		return false
	for player_conditions in Array(value):
		if not _bounded_string_array(player_conditions, 8, 64):
			return false
	return true


static func _validate_presentation_cards(value: Variant) -> bool:
	if _bounded_string_array(value, MAX_DECK_CARDS, MAX_IDENTIFIER_BYTES):
		return true
	if not value is Array or Array(value).size() > MAX_DECK_CARDS:
		return false
	for row_value in Array(value):
		if not row_value is Dictionary:
			return false
		var row: Dictionary = row_value
		if (
			row.size() != 3
			or not _bounded_string(row.get("card_id", ""), MAX_IDENTIFIER_BYTES)
			or not row.get("matched") is bool
			or not _validate_presentation_endpoint(row.get("destination", {}))
		):
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
