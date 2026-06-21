class_name ProtocolV3
extends RefCounted

const VERSION := 3
const MAX_MESSAGE_BYTES := 262144

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
	if JSON.stringify(row).to_utf8_buffer().size() > MAX_MESSAGE_BYTES:
		return _invalid("message_too_large", "消息超过大小限制。")
	if int(row.get("protocol_version", -1)) != VERSION:
		return _invalid("protocol_mismatch", "联机协议版本不兼容。")
	var message_type := str(row.get("message_type", ""))
	if message_type not in MESSAGE_TYPES:
		return _invalid("unknown_message_type", "未知消息类型。")
	for field in [
		"room_id", "sender", "sequence", "state_revision",
		"action_id", "request_id", "payload",
	]:
		if not row.has(field):
			return _invalid("missing_field", "消息缺少字段：%s" % field)
	if not row["room_id"] is String or not row["payload"] is Dictionary:
		return _invalid("invalid_field_type", "消息字段类型错误。")
	if (
		not _is_integer_number(row["sender"])
		or not _is_integer_number(row["sequence"])
		or not _is_integer_number(row["state_revision"])
		or not row["action_id"] is String
		or not row["request_id"] is String
	):
		return _invalid("invalid_field_type", "消息字段类型错误。")
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


static func error_payload(code: String, message: String) -> Dictionary:
	return {"code": code, "message": message}


static func _invalid(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}


static func _is_integer_number(value: Variant) -> bool:
	return (
		value is int
		or (value is float and is_equal_approx(value, float(int(value))))
	)
