class_name VMChoiceRequests
extends RefCounted


static func request_cards(
	catalog: CardCatalog,
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	zone: String,
	available: Array[String],
	operation: String,
	data: Dictionary,
	min_select: int,
	max_select: int,
	prompt: String,
	can_cancel: bool = false,
) -> Dictionary:
	var source: Array[String] = VMZoneHelpers.zone(state.get_player(player_idx), zone)
	var occurrence: Dictionary = {}
	var options: Array[Dictionary] = []
	for card_id in available:
		var start := int(occurrence.get(card_id, 0))
		var index := source.find(card_id, start)
		if index < 0:
			continue
		occurrence[card_id] = index + 1
		options.append({
			"option_id": "card:%s:%d:%s" % [zone, index, card_id],
			"label": catalog.card_name(card_id),
			"ref": EntityRef.new("card", player_idx, zone, "", index, "", card_id).to_dict(),
			"value": {"index": index, "card_id": card_id},
		})
	if options.is_empty():
		return VMResult.ok("没有可选卡牌。")
	stack.push_continuation(operation, data)
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, operation),
		operation,
		player_idx,
		prompt,
		options,
		min_select,
		max_select,
		false,
		can_cancel,
		{"revision": state.revision, "zone": zone},
	)
	return VMResult.ok()


static func confirm_request(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	operation: String,
	data: Dictionary,
	prompt: String,
	metadata: Dictionary = {},
) -> Dictionary:
	var options: Array[Dictionary] = [
		{"option_id": "confirm:yes", "label": "是", "value": true},
		{"option_id": "confirm:no", "label": "否", "value": false},
	]
	var request_metadata := metadata.duplicate(true)
	if not request_metadata.has("revision"):
		request_metadata["revision"] = state.revision
	stack.push_continuation(operation, data)
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "confirm"),
		"confirm",
		player_idx,
		prompt,
		options,
		1,
		1,
		false,
		false,
		request_metadata,
	)
	return VMResult.ok()
