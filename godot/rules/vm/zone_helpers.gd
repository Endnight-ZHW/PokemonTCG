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
	events.append({"event_type": "cards_drawn", "data": {
		"player": player_idx, "cards": cards.duplicate(),
	}})
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
	var moved := remove_selected_from_zone(player, source_zone, selected, false)
	match str(data["destination"]):
		"hand":
			player.hand.append_array(moved)
		"bench":
			for card_id in moved:
				var slot := player.find_empty_bench_slot()
				if slot >= 0:
					player.place_bench(card_id, slot)
				else:
					player.hand.append(card_id)
		_:
			player.hand.append_array(moved)
	if bool(data.get("shuffle", false)):
		rng.shuffle(player.deck)
		events.append({"event_type": "deck_shuffled", "data": {"player": player_idx}})
	events.append({"event_type": "cards_selected", "data": {
		"player": player_idx, "cards": moved.duplicate(),
	}})
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
) -> Dictionary:
	return {
		"event_type": "cards_discarded",
		"actor": player_idx,
		"source": {"player": player_idx, "zone": source_zone},
		"target": {"player": player_idx, "zone": "discard"},
		"amount": count,
		"data": {
			"player": player_idx,
			"count": count,
			"card_ids": card_ids.duplicate(),
		},
	}


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
