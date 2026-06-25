class_name PresentationEvent
extends RefCounted

const PUBLIC := "public"
const OWNER := "owner"
const PRIVATE := "private"

const CARD_ID_FIELDS: Array[String] = [
	"card_id",
	"source_card_id",
	"target_card_id",
]
const CARD_LIST_FIELDS: Array[String] = [
	"card_ids",
	"cards",
	"selected_card_ids",
]


static func normalize(
	raw_event: Dictionary,
	revision: int,
	fallback_actor: int = -1,
	event_index: int = 0,
) -> Dictionary:
	var data := Dictionary(raw_event.get("data", {})).duplicate(true)
	var actor := int(raw_event.get(
		"actor",
		data.get("player", data.get("actor", fallback_actor)),
	))
	var event_type := str(raw_event.get("event_type", "unknown"))
	if event_type == "cards_drawn" and data.has("cards") and not data.has("card_ids"):
		data["card_ids"] = Array(data.get("cards", [])).duplicate()
	var card_count := 0
	for field in CARD_LIST_FIELDS:
		if data.get(field, []) is Array:
			card_count = max(card_count, Array(data.get(field, [])).size())
	var amount := int(raw_event.get(
		"amount",
		data.get("amount", data.get("count", 0)),
	))
	if amount <= 0 and card_count > 0:
		amount = card_count
	var result := {
		"event_id": str(raw_event.get(
			"event_id",
			"presentation:%d:%d:%s" % [revision, event_index, event_type],
		)),
		"revision": int(raw_event.get("revision", revision)),
		"event_type": event_type,
		"actor": actor,
		"source": _endpoint(raw_event.get("source", {}), data, actor, true),
		"target": _endpoint(raw_event.get("target", {}), data, actor, false),
		"card_id": str(raw_event.get("card_id", data.get("card_id", ""))),
		"amount": amount,
		"visibility": str(raw_event.get(
			"visibility",
			data.get(
				"visibility",
				OWNER if event_type == "cards_drawn" else PUBLIC,
			),
		)),
		"data": data,
	}
	return result


static func normalize_all(
	raw_events: Array,
	revision: int,
	fallback_actor: int = -1,
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(raw_events.size()):
		if raw_events[index] is Dictionary:
			result.append(normalize(
				raw_events[index],
				revision,
				fallback_actor,
				index,
			))
	return result


static func for_player(event: Dictionary, player_idx: int) -> Dictionary:
	var result := event.duplicate(true)
	var owner := int(result.get(
		"actor",
		result.get("data", {}).get("player", -1),
	))
	var visibility := str(result.get("visibility", PUBLIC))
	if visibility == PRIVATE and owner != player_idx:
		return {}
	if visibility == OWNER and owner != player_idx:
		_strip_hidden_card_identity(result)

	var event_type := str(result.get("event_type", ""))
	if owner != player_idx and event_type in [
		"cards_drawn",
		"prize_taken",
		"cards_selected",
		"hand_revealed",
	]:
		_strip_hidden_card_identity(result)
	return result


static func _strip_hidden_card_identity(event: Dictionary) -> void:
	event["card_id"] = ""
	var data: Dictionary = event.get("data", {})
	for field in CARD_ID_FIELDS:
		if data.has(field):
			data[field] = ""
	for field in CARD_LIST_FIELDS:
		if data.has(field):
			data[field] = []
	event["data"] = data


static func _endpoint(
	explicit_value: Variant,
	data: Dictionary,
	actor: int,
	source: bool,
) -> Dictionary:
	if explicit_value is Dictionary and not explicit_value.is_empty():
		return Dictionary(explicit_value).duplicate(true)
	var player := int(data.get(
		"source_player" if source else "target_player",
		data.get("player", actor),
	))
	var slot := str(data.get(
		"source_slot" if source else "target_slot",
		data.get("slot", ""),
	))
	var zone := str(data.get(
		"source_zone" if source else "target_zone",
		"",
	))
	var index := int(data.get(
		"source_index" if source else "target_index",
		-1,
	))
	return {
		"player": player,
		"zone": zone,
		"slot": slot,
		"index": index,
	}
