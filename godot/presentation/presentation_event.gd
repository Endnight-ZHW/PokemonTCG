class_name PresentationEvent
extends RefCounted

const PUBLIC := "public"
const OWNER := "owner"
const PRIVATE := "private"

const EVENT_TYPE_ALIASES := {
	"card_discarded": "cards_discarded",
}
const SUPPORTED_EVENT_TYPES: Array[String] = [
	"attack_declared",
	"card_moved",
	"cards_discarded",
	"cards_drawn",
	"cards_selected",
	"checkup",
	"coin_flip",
	"confusion_failed",
	"damage_counters_placed",
	"damage_dealt",
	"damage_prevented",
	"deck_shuffled",
	"energy_attached",
	"game_over",
	"healed",
	"pokemon_evolved",
	"pokemon_ko",
	"pokemon_played",
	"prize_taken",
	"promoted",
	"retreat",
	"stadium_changed",
	"status_applied",
	"switched",
	"tool_attached",
	"trainer_played",
	"turn_end",
	"turn_start",
]

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
const HIDDEN_INDEX_FIELDS: Array[String] = [
	"source_index",
	"target_index",
]
const HIDDEN_INDEX_LIST_FIELDS: Array[String] = [
	"source_indices",
	"target_indices",
]


static func normalize(
	raw_event: Dictionary,
	revision: int,
	fallback_actor: int = -1,
	event_index: int = 0,
) -> Dictionary:
	var data := _dictionary_or_empty(raw_event.get("data", {})).duplicate(true)
	var actor := int(raw_event.get(
		"actor",
		data.get("player", data.get("actor", fallback_actor)),
	))
	var event_type := canonical_event_type(str(raw_event.get("event_type", "unknown")))
	if (
		event_type == "cards_drawn"
		and data.get("cards", []) is Array
		and not data.has("card_ids")
	):
		data["card_ids"] = Array(data["cards"]).duplicate()
	if event_type == "cards_discarded" and not data.has("card_ids"):
		var discarded_card_id := str(data.get(
			"card_id",
			raw_event.get("card_id", ""),
		))
		if not discarded_card_id.is_empty():
			data["card_ids"] = [discarded_card_id]
	var card_count := 0
	for field in CARD_LIST_FIELDS:
		if data.get(field, []) is Array:
			card_count = max(card_count, Array(data.get(field, [])).size())
	var amount := _normalized_amount(raw_event, data, event_type)
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
	_apply_endpoint_defaults(result, raw_event, data)
	return result


static func canonical_event_type(event_type: String) -> String:
	return str(EVENT_TYPE_ALIASES.get(event_type, event_type))


static func is_supported_event_type(event_type: String) -> bool:
	return canonical_event_type(event_type) in SUPPORTED_EVENT_TYPES


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
	var data := _dictionary_or_empty(result.get("data", {}))
	var owner := int(result.get(
		"actor",
		data.get("player", -1),
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
	var data := _dictionary_or_empty(event.get("data", {}))
	for field in CARD_ID_FIELDS:
		if data.has(field):
			data[field] = ""
	for field in CARD_LIST_FIELDS:
		if data.has(field):
			data[field] = []
	for field in HIDDEN_INDEX_FIELDS:
		if data.has(field):
			data[field] = -1
	for field in HIDDEN_INDEX_LIST_FIELDS:
		if data.has(field):
			data[field] = []
	for endpoint_name in ["source", "target"]:
		var endpoint := _dictionary_or_empty(event.get(endpoint_name, {})).duplicate(true)
		endpoint["index"] = -1
		event[endpoint_name] = endpoint
	event["data"] = data


static func _apply_endpoint_defaults(
	event: Dictionary,
	raw_event: Dictionary,
	data: Dictionary,
) -> void:
	var event_type := str(event.get("event_type", ""))
	var actor := int(event.get("actor", data.get("player", -1)))
	var player := int(data.get("player", actor))
	var slot := str(data.get("target_slot", data.get("slot", "")))
	match event_type:
		"cards_drawn":
			_merge_endpoint_defaults(event, "source", player, "deck")
			_merge_endpoint_defaults(event, "target", player, "hand")
		"cards_discarded":
			_merge_endpoint_defaults(event, "source", player, str(data.get("source_zone", "")))
			_merge_endpoint_defaults(event, "target", player, "discard")
			var discard_source: Dictionary = event.get("source", {})
			var discard_target: Dictionary = Dictionary(
				event.get("target", {})
			).duplicate(true)
			# The player causing a discard is not necessarily the card owner.
			# Discard endpoints therefore inherit ownership from the source rather
			# than from actor (for example Crushing Hammer targeting an opponent).
			discard_target["player"] = int(discard_source.get("player", player))
			event["target"] = discard_target
		"cards_selected":
			_merge_endpoint_defaults(event, "source", player, str(data.get("source_zone", "deck")))
			_merge_endpoint_defaults(event, "target", player, str(data.get("target_zone", data.get("destination", "hand"))))
		"card_moved":
			_merge_endpoint_defaults(event, "source", player, str(data.get("source_zone", "")), str(data.get("source_slot", "")), int(data.get("source_index", -1)))
			_merge_endpoint_defaults(event, "target", player, str(data.get("target_zone", "")), str(data.get("target_slot", "")), int(data.get("target_index", -1)))
		"pokemon_played", "pokemon_evolved", "energy_attached", "tool_attached":
			if _has_endpoint_hint(raw_event, data, "source"):
				_merge_endpoint_defaults(event, "source", player, str(data.get("source_zone", "hand")), str(data.get("source_slot", "")), int(data.get("source_index", -1)))
			_merge_endpoint_defaults(event, "target", player, "", slot)
		"trainer_played":
			if _has_endpoint_hint(raw_event, data, "source"):
				_merge_endpoint_defaults(event, "source", player, "hand", "", int(data.get("source_index", -1)))
			_merge_endpoint_defaults(event, "target", player, "discard")
		"stadium_changed":
			if _has_endpoint_hint(raw_event, data, "source"):
				_merge_endpoint_defaults(event, "source", player, "hand", "", int(data.get("source_index", -1)))
			_merge_endpoint_defaults(event, "target", player, "stadium")
		"damage_dealt", "damage_counters_placed", "healed", "status_applied", "damage_prevented":
			_merge_endpoint_defaults(event, "target", player, "", slot if not slot.is_empty() else "active")
		"confusion_failed":
			_merge_endpoint_defaults(event, "source", player, "", "active")
			_merge_endpoint_defaults(event, "target", player, "", "active")
		"retreat", "switched", "promoted":
			var bench_slot := str(data.get("slot", "bench_%d" % int(data.get("bench_idx", -1))))
			_merge_endpoint_defaults(event, "source", player, "", bench_slot)
			_merge_endpoint_defaults(event, "target", player, "", "active")
		"pokemon_ko":
			_merge_endpoint_defaults(event, "source", player, "", str(data.get("slot", "active")))
			_merge_endpoint_defaults(event, "target", player, "discard")
		"prize_taken":
			_merge_endpoint_defaults(event, "source", player, "prizes")
			_merge_endpoint_defaults(event, "target", player, "hand")
		"deck_shuffled":
			_merge_endpoint_defaults(event, "source", player, "deck")
			_merge_endpoint_defaults(event, "target", player, "deck")
		"turn_start", "turn_end":
			_merge_endpoint_defaults(event, "target", player, "", "active")
	if event_type == "energy_attached":
		_set_attachment_endpoint_type(event, "target", "energy")
		var energy_source: Dictionary = event.get("source", {})
		if (
			not str(energy_source.get("slot", "")).is_empty()
			and str(energy_source.get("zone", "")).is_empty()
		):
			_set_attachment_endpoint_type(event, "source", "energy")
	elif event_type == "tool_attached":
		_set_attachment_endpoint_type(event, "target", "tool")


static func _set_attachment_endpoint_type(
	event: Dictionary,
	key: String,
	attachment_type: String,
) -> void:
	var endpoint := _dictionary_or_empty(event.get(key, {})).duplicate(true)
	if (
		not str(endpoint.get("slot", "")).is_empty()
		and str(endpoint.get("attachment_type", "")).is_empty()
	):
		endpoint["attachment_type"] = attachment_type
		event[key] = endpoint


static func _merge_endpoint_defaults(
	event: Dictionary,
	key: String,
	player: int,
	zone: String = "",
	slot: String = "",
	index: int = -1,
) -> void:
	var endpoint := _dictionary_or_empty(event.get(key, {})).duplicate(true)
	if int(endpoint.get("player", -1)) < 0:
		endpoint["player"] = player
	if str(endpoint.get("zone", "")).is_empty() and not zone.is_empty():
		endpoint["zone"] = zone
	if str(endpoint.get("slot", "")).is_empty() and not slot.is_empty():
		endpoint["slot"] = slot
	if int(endpoint.get("index", -1)) < 0 and index >= 0:
		endpoint["index"] = index
	event[key] = endpoint


static func _has_endpoint_hint(
	raw_event: Dictionary,
	data: Dictionary,
	key: String,
) -> bool:
	var explicit: Variant = raw_event.get(key, {})
	if explicit is Dictionary and not Dictionary(explicit).is_empty():
		return true
	return (
		data.has("%s_zone" % key)
		or data.has("%s_slot" % key)
		or data.has("%s_index" % key)
	)


static func _endpoint(
	explicit_value: Variant,
	data: Dictionary,
	actor: int,
	source: bool,
) -> Dictionary:
	var endpoint: Dictionary = {
		"player": int(data.get(
			"source_player" if source else "target_player",
			data.get("player", actor),
		)),
		"zone": "",
		"slot": "",
		"index": -1,
	}
	if explicit_value is Dictionary and not explicit_value.is_empty():
		for key in Dictionary(explicit_value):
			endpoint[key] = explicit_value[key]
		return endpoint
	endpoint["zone"] = str(data.get(
		"source_zone" if source else "target_zone",
		"",
	))
	endpoint["slot"] = str(data.get(
		"source_slot" if source else "target_slot",
		"" if source else data.get("slot", ""),
	))
	endpoint["index"] = int(data.get(
		"source_index" if source else "target_index",
		-1,
	))
	return endpoint


static func _normalized_amount(
	raw_event: Dictionary,
	data: Dictionary,
	event_type: String,
) -> int:
	if event_type == "damage_counters_placed":
		var counter_count := int(data.get("counter_count", data.get("count", 0)))
		var amount := int(raw_event.get("amount", data.get("amount", 0)))
		if counter_count <= 0 and amount > 0:
			counter_count = ceili(float(amount) / 10.0)
		if amount <= 0:
			amount = counter_count * 10
		data["counter_count"] = counter_count
		return amount
	return int(raw_event.get(
		"amount",
		data.get("amount", data.get("count", 0)),
	))


static func _dictionary_or_empty(value: Variant) -> Dictionary:
	if value is Dictionary:
		return Dictionary(value)
	return {}
