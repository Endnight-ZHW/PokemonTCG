class_name ProtocolV6
extends "res://network/protocol_v6_state_validator.gd"

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
				or (payload.has("core_fingerprint") and not _valid_sha256(
					payload["core_fingerprint"]))
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
				or (payload.has("core_fingerprint") and not _valid_sha256(
					payload["core_fingerprint"]))
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
