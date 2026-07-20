class_name EntityRef
extends RefCounted

var kind: String
var player: int
var zone: String
var slot: String
var index: int
var attachment_type: String
var card_id: String


func _init(
	p_kind: String = "",
	p_player: int = -1,
	p_zone: String = "",
	p_slot: String = "",
	p_index: int = -1,
	p_attachment_type: String = "",
	p_card_id: String = "",
) -> void:
	kind = p_kind
	player = p_player
	zone = p_zone
	slot = p_slot
	index = p_index
	attachment_type = p_attachment_type
	card_id = p_card_id


func to_dict() -> Dictionary:
	match kind:
		"card":
			return {
				"kind": kind,
				"player": player,
				"zone": zone,
				"index": index,
				"card_id": card_id,
			}
		"pokemon":
			return {
				"kind": kind,
				"player": player,
				"slot": slot,
				"card_id": card_id,
			}
		"slot":
			return {"kind": kind, "player": player, "slot": slot}
		"attachment":
			return {
				"kind": kind,
				"player": player,
				"slot": slot,
				"attachment_type": attachment_type,
				"index": index,
				"card_id": card_id,
			}
		_:
			# Legacy-only refs remain serializable for diagnostics, but Protocol v6
			# rejects them at the external boundary.
			return {
				"kind": kind,
				"player": player,
				"zone": zone,
				"slot": slot,
				"index": index,
				"attachment_type": attachment_type,
				"card_id": card_id,
			}


func immutable_copy() -> EntityRef:
	return EntityRef.new(
		kind, player, zone, slot, index, attachment_type, card_id)


func same_identity(other: EntityRef) -> bool:
	return (
		other != null
		and kind == other.kind
		and player == other.player
		and zone == other.zone
		and slot == other.slot
		and index == other.index
		and attachment_type == other.attachment_type
		and card_id == other.card_id
	)


func validation_error() -> String:
	if player not in [0, 1]:
		return "实体引用玩家无效。"
	match kind:
		"card":
			if zone not in ["deck", "hand", "discard", "prizes", "stadium"]:
				return "卡牌引用区域无效。"
			if index < 0 or card_id.is_empty():
				return "卡牌引用字段无效。"
		"pokemon":
			if not _valid_slot(slot) or card_id.is_empty():
				return "宝可梦引用字段无效。"
		"slot":
			if not _valid_slot(slot):
				return "槽位引用字段无效。"
		"attachment":
			if (
				not _valid_slot(slot)
				or attachment_type not in ["energy", "tool"]
				or index < 0
				or card_id.is_empty()
			):
				return "附件引用字段无效。"
		_:
			return "未知实体引用类型。"
	return ""


static func validate_dict(value: Variant) -> String:
	if not value is Dictionary:
		return "实体引用必须是对象。"
	var data: Dictionary = value
	if not data.get("kind") is String or not _is_wire_integer(data.get("player")):
		return "实体引用基础字段无效。"
	var kind_value := str(data["kind"])
	var expected: Array[String]
	match kind_value:
		"card":
			expected = ["kind", "player", "zone", "index", "card_id"]
		"pokemon":
			expected = ["kind", "player", "slot", "card_id"]
		"slot":
			expected = ["kind", "player", "slot"]
		"attachment":
			expected = [
				"kind", "player", "slot", "attachment_type", "index", "card_id",
			]
		_:
			return "未知实体引用类型。"
	if data.size() != expected.size():
		return "实体引用包含缺失或多余字段。"
	for field in expected:
		if not data.has(field):
			return "实体引用缺少字段：%s" % field
	for integer_field in ["index"]:
		if data.has(integer_field) and not _is_wire_integer(data[integer_field]):
			return "实体引用索引类型无效。"
	for string_field in ["zone", "slot", "attachment_type", "card_id"]:
		if data.has(string_field) and not data[string_field] is String:
			return "实体引用字段类型无效。"
	return EntityRef.from_dict(data).validation_error()


static func from_dict(data: Dictionary) -> EntityRef:
	return EntityRef.new(
		str(data.get("kind", "")),
		int(data.get("player", -1)),
		str(data.get("zone", "")),
		str(data.get("slot", "")),
		int(data.get("index", -1)),
		str(data.get("attachment_type", "")),
		str(data.get("card_id", "")),
	)


static func _valid_slot(value: String) -> bool:
	if value == "active":
		return true
	if not value.begins_with("bench_"):
		return false
	var suffix := value.trim_prefix("bench_")
	return suffix.is_valid_int() and int(suffix) >= 0 and int(suffix) < 5


static func _is_wire_integer(value: Variant) -> bool:
	if value is int:
		return true
	return (
		value is float
		and is_finite(value)
		and value >= -2147483648.0
		and value <= 2147483647.0
		and value == floorf(value)
	)
