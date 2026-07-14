class_name VMZoneHelpers
extends RefCounted


static func draw(
	state: GameState,
	player_idx: int,
	amount: int,
	events: Array[Dictionary],
) -> Dictionary:
	return draw_available(state, player_idx, amount, events)


static func draw_available(
	state: GameState,
	player_idx: int,
	amount: int,
	events: Array[Dictionary],
) -> Dictionary:
	if amount <= 0:
		return VMResult.ok()
	var player := state.get_player(player_idx)
	var cards := player.draw_cards(min(amount, player.deck.size()))
	if cards.is_empty():
		return VMResult.ok("抽取了0张卡。")
	events.append({
		"event_type": "cards_drawn",
		"actor": player_idx,
		"visibility": "owner",
		"source": {"player": player_idx, "zone": "deck"},
		"target": {"player": player_idx, "zone": "hand"},
		"amount": cards.size(),
		"data": {
			"player": player_idx,
			"count": cards.size(),
			"card_ids": cards.duplicate(),
		},
	})
	return VMResult.ok("抽取了%d张卡。" % cards.size())


static func move_selected_cards(
	state: GameState,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data["player_idx"])
	var player := state.get_player(player_idx)
	var source_zone := str(data["source_zone"])
	var source_indices := selected_source_indices(selected)
	var moved := remove_selected_from_zone(player, source_zone, selected, false)
	var destination := str(data["destination"])
	var movement_events: Array[Dictionary] = []
	match destination:
		"hand":
			player.hand.append_array(moved)
		"bench":
			for moved_index in range(moved.size()):
				var card_id := str(moved[moved_index])
				var source_index := (
					int(source_indices[moved_index])
					if moved_index < source_indices.size()
					else -1
				)
				var source := {"player": player_idx, "zone": source_zone}
				if source_index >= 0:
					source["index"] = source_index
				var slot := player.find_empty_bench_slot()
				if slot >= 0:
					player.place_bench(card_id, slot)
					movement_events.append(card_moved_event(
						player_idx,
						[card_id],
						source,
						{"player": player_idx, "slot": "bench_%d" % slot},
					))
				else:
					var target_index := player.hand.size()
					player.hand.append(card_id)
					movement_events.append(card_moved_event(
						player_idx,
						[card_id],
						source,
						{
							"player": player_idx,
							"zone": "hand",
							"index": target_index,
						},
						"owner",
					))
		_:
			player.hand.append_array(moved)
	if bool(data.get("shuffle", false)):
		rng.shuffle(player.deck)
		events.append({
			"event_type": "deck_shuffled",
			"actor": player_idx,
			"source": {"player": player_idx, "zone": "deck"},
			"target": {"player": player_idx, "zone": "deck"},
			"data": {"player": player_idx},
		})
	# A generic `zone = bench` endpoint has no visual anchor and used to resolve
	# to the centre of the screen, so bench searches use one exact event per slot.
	if destination == "bench":
		events.append_array(movement_events)
	else:
		events.append(cards_selected_event(
			player_idx,
			source_zone,
			destination,
			moved,
			-1,
			source_indices,
		))
	return VMResult.ok()


static func remove_selected_from_zone(
	player: PlayerState,
	zone_name: String,
	selected: Array[Dictionary],
	to_discard: bool,
) -> Array[String]:
	var source_zone := zone(player, zone_name)
	var indices: Array[int] = []
	for option in selected:
		indices.append(int(option.get("value", {}).get("index", -1)))
	indices.sort()
	indices.reverse()
	var removed_reversed: Array[String] = []
	for index in indices:
		if index >= 0 and index < source_zone.size():
			var card_id: String = source_zone.pop_at(index)
			removed_reversed.append(card_id)
			if to_discard:
				player.discard.append(card_id)
	removed_reversed.reverse()
	return removed_reversed


static func discard_event(
	player_idx: int,
	source_zone: String,
	card_ids: Array,
	count: int,
	source_indices: Array = [],
	source_slot: String = "",
	target_index: int = -1,
) -> Dictionary:
	var source_index_list := normalized_indices(source_indices)
	var source := {"player": player_idx, "zone": source_zone}
	if not source_slot.is_empty():
		source["slot"] = source_slot
	if not source_index_list.is_empty():
		source["index"] = source_index_list[0]
	var target := {"player": player_idx, "zone": "discard"}
	if target_index >= 0:
		target["index"] = target_index
	return {
		"event_type": "cards_discarded",
		"actor": player_idx,
		"source": source,
		"target": target,
		"amount": count,
		"data": {
			"player": player_idx,
			"count": count,
			"card_ids": card_ids.duplicate(),
			"source_zone": source_zone,
			"source_slot": source_slot,
			"source_index": (
				source_index_list[0] if not source_index_list.is_empty() else -1
			),
			"source_indices": source_index_list,
			"target_zone": "discard",
			"target_index": target_index,
		},
	}


static func cards_selected_event(
	player_idx: int,
	source_zone: String,
	target_zone: String,
	card_ids: Array,
	count: int = -1,
	source_indices: Array = [],
	target_indices: Array = [],
) -> Dictionary:
	var selected_count := card_ids.size() if count < 0 else count
	var normalized_source_indices := normalized_indices(source_indices)
	var normalized_target_indices := normalized_indices(target_indices)
	var source := {"player": player_idx, "zone": source_zone}
	if not normalized_source_indices.is_empty():
		source["index"] = normalized_source_indices[0]
	var target := {"player": player_idx, "zone": target_zone}
	if not normalized_target_indices.is_empty():
		target["index"] = normalized_target_indices[0]
	return {
		"event_type": "cards_selected",
		"actor": player_idx,
		"visibility": "owner",
		"source": source,
		"target": target,
		"amount": selected_count,
		"data": {
			"player": player_idx,
			"source_zone": source_zone,
			"target_zone": target_zone,
			"count": selected_count,
			"card_ids": card_ids.duplicate(),
			"source_index": (
				normalized_source_indices[0]
				if not normalized_source_indices.is_empty()
				else -1
			),
			"source_indices": normalized_source_indices,
			"target_index": (
				normalized_target_indices[0]
				if not normalized_target_indices.is_empty()
				else -1
			),
			"target_indices": normalized_target_indices,
		},
	}


static func card_moved_event(
	player_idx: int,
	card_ids: Array,
	source: Dictionary,
	target: Dictionary,
	visibility: String = "public",
) -> Dictionary:
	var source_indices: Array = []
	if source.get("indices", []) is Array:
		source_indices = normalized_indices(Array(source.get("indices", [])))
	elif int(source.get("index", -1)) >= 0:
		source_indices = [int(source["index"])]
	var target_indices: Array = []
	if target.get("indices", []) is Array:
		target_indices = normalized_indices(Array(target.get("indices", [])))
	elif int(target.get("index", -1)) >= 0:
		target_indices = [int(target["index"])]
	var source_endpoint := source.duplicate(true)
	var target_endpoint := target.duplicate(true)
	source_endpoint.erase("indices")
	target_endpoint.erase("indices")
	return {
		"event_type": "card_moved",
		"actor": player_idx,
		"visibility": visibility,
		"card_id": str(card_ids[0]) if card_ids.size() == 1 else "",
		"source": source_endpoint,
		"target": target_endpoint,
		"amount": card_ids.size(),
		"data": {
			"player": player_idx,
			"card_ids": card_ids.duplicate(),
			"count": card_ids.size(),
			"source_zone": str(source_endpoint.get("zone", "")),
			"source_slot": str(source_endpoint.get("slot", "")),
			"source_index": (
				source_indices[0] if not source_indices.is_empty() else -1
			),
			"source_indices": source_indices,
			"target_zone": str(target_endpoint.get("zone", "")),
			"target_slot": str(target_endpoint.get("slot", "")),
			"target_index": (
				target_indices[0] if not target_indices.is_empty() else -1
			),
			"target_indices": target_indices,
		},
	}


static func selected_source_indices(selected: Array[Dictionary]) -> Array[int]:
	var result: Array[int] = []
	for option in selected:
		var index := int(option.get("value", {}).get("index", -1))
		if index >= 0:
			result.append(index)
	result.sort()
	return result


static func normalized_indices(values: Array) -> Array[int]:
	var result: Array[int] = []
	for value in values:
		var index := int(value)
		if index >= 0:
			result.append(index)
	result.sort()
	return result


static func zone(player: PlayerState, zone_name: String) -> Array[String]:
	match zone_name:
		"hand":
			return player.hand
		"discard":
			return player.discard
		"prizes":
			return player.prizes
		_:
			return player.deck
