class_name LocalHandoffPlan
extends RefCounted

const MODE_LOCAL := "local"

static func create(
	state: GameState,
	current_view_player: int,
	ai_thinking: bool,
	game_mode: String,
	raw_events: Array,
	previous_active: int,
	previous_phase: String = "",
) -> Dictionary:
	var opening_turn_after_setup: bool = (
		previous_phase == "SETUP"
		and state != null
		and state.phase == "MAIN"
	)
	if (
		game_mode != MODE_LOCAL
		or state == null
		or state.is_terminal()
	):
		return {}
	var incoming_player: int = state.active_player_idx
	var presents_incoming_turn := false
	for event_value in raw_events:
		if not event_value is Dictionary:
			continue
		var event: Dictionary = event_value
		var event_type := PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		)
		var data: Dictionary = event.get("data", {})
		var actor := int(event.get("actor", data.get("player", -1)))
		if event_type == "turn_start" and actor == incoming_player:
			presents_incoming_turn = true
			break
	var returning_view_to_incoming: bool = (
		presents_incoming_turn
		and current_view_player != incoming_player
	)
	if (
		state.active_player_idx == previous_active
		and not opening_turn_after_setup
		and not returning_view_to_incoming
	):
		return {}
	var events: Array[Dictionary] = []
	for index in range(raw_events.size()):
		if not raw_events[index] is Dictionary:
			continue
		var event: Dictionary = Dictionary(raw_events[index]).duplicate(true)
		var event_type := PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		)
		if str(event.get("event_id", "")).is_empty():
			event["event_id"] = "presentation:%d:%d:%s" % [
				state.revision,
				index,
				event_type,
			]
		events.append(event)
	events = PresentationEvent.order_for_presentation(events)
	var boundary := -1
	for index in range(events.size()):
		var event: Dictionary = events[index]
		var event_type := PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		)
		var data: Dictionary = event.get("data", {})
		var actor := int(event.get("actor", data.get("player", -1)))
		if actor == incoming_player and event_type == "turn_start":
			boundary = index
			break
	if boundary < 0:
		for index in range(events.size()):
			var event: Dictionary = events[index]
			var event_type := PresentationEvent.canonical_event_type(
				str(event.get("event_type", "")),
			)
			var data: Dictionary = event.get("data", {})
			var actor := int(event.get("actor", data.get("player", -1)))
			if actor == incoming_player and event_type == "cards_drawn":
				boundary = index
				break
	if boundary < 0:
		return {}
	var prefix_events: Array[Dictionary] = []
	var suffix_events: Array[Dictionary] = []
	for index in range(events.size()):
		if index < boundary:
			prefix_events.append(events[index])
		else:
			suffix_events.append(events[index])
	var pre_draw_state := _state_before_handoff_draw(state, suffix_events, incoming_player)
	if pre_draw_state == null:
		return {}
	var outgoing_view := BattleViewModel.capture_player_view(
		pre_draw_state,
		current_view_player,
		[],
		"",
		ai_thinking,
		game_mode,
	)
	var incoming_view := BattleViewModel.capture_player_view(
		pre_draw_state,
		incoming_player,
		[],
		"",
		ai_thinking,
		game_mode,
	)
	return {
		"incoming_player": incoming_player,
		"prefix_events": prefix_events,
		"suffix_events": suffix_events,
		"outgoing_view": outgoing_view,
		"incoming_view": incoming_view,
	}

static func _state_before_handoff_draw(
	state: GameState,
	suffix_events: Array[Dictionary],
	incoming_player: int,
) -> GameState:
	if state == null or incoming_player not in [0, 1]:
		return null
	var result: GameState = state.clone_state()
	var player: PlayerState = result.get_player(incoming_player)
	for event_index in range(suffix_events.size() - 1, -1, -1):
		var event: Dictionary = suffix_events[event_index]
		if PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		) != "cards_drawn":
			continue
		var data: Dictionary = event.get("data", {})
		var actor := int(event.get("actor", data.get("player", -1)))
		if actor != incoming_player:
			continue
		var raw_card_ids: Variant = data.get("card_ids", data.get("cards", []))
		var card_ids: Array[String] = []
		if raw_card_ids is Array:
			for value in raw_card_ids:
				card_ids.append(str(value))
		var amount := maxi(0, int(event.get(
			"amount",
			data.get("count", card_ids.size()),
		)))
		for offset in range(amount):
			var expected_id := (
				card_ids[card_ids.size() - 1 - offset]
				if offset < card_ids.size()
				else ""
			)
			var restored_id := _pop_last_matching_card(player.hand, expected_id)
			if not restored_id.is_empty():
				player.deck.append(restored_id)
	result.phase = "DRAW"
	if (
		not result.action_log.is_empty()
		and str(result.action_log[-1]).begins_with("—— ")
	):
		result.action_log.pop_back()
	return result

static func _pop_last_matching_card(cards: Array[String], card_id: String) -> String:
	if cards.is_empty():
		return ""
	if card_id.is_empty() or cards[-1] == card_id:
		return cards.pop_back()
	for index in range(cards.size() - 1, -1, -1):
		if cards[index] == card_id:
			return cards.pop_at(index)
	return cards.pop_back()
