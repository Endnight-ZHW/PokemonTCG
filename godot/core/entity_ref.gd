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
	return {
		"kind": kind,
		"player": player,
		"zone": zone,
		"slot": slot,
		"index": index,
		"attachment_type": attachment_type,
		"card_id": card_id,
	}


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
