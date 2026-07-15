class_name VMTransactionManager
extends RefCounted


func capture_transaction(state: GameState, rng: PortableRandomSource) -> Dictionary:
	return {
		"state": state.snapshot(),
		"rng_state": rng.get_state(),
		"events": state.event_stream._events.duplicate(true),
		"event_capacity": state.event_stream.capacity,
	}


func store_cancel_action_checkpoint(stack: ResolutionStack, checkpoint: Dictionary) -> void:
	stack.context["cancel_action_checkpoint"] = {
		"state": checkpoint["state"],
		"rng_state": checkpoint["rng_state"],
		"events": checkpoint["events"],
		"event_capacity": checkpoint["event_capacity"],
	}


func cancel_action_checkpoint(stack: ResolutionStack) -> Dictionary:
	var checkpoint: Variant = stack.context.get("cancel_action_checkpoint")
	if checkpoint is Dictionary:
		return Dictionary(checkpoint)
	if stack.context.get("cancel_action_snapshot") is Dictionary:
		return {
			"state": stack.context["cancel_action_snapshot"],
			"rng_state": stack.context.get("cancel_action_rng_state"),
			"events": stack.context.get("cancel_action_events", []),
			"event_capacity": stack.context.get("cancel_action_event_capacity", 256),
		}
	return {}


func append_deferred_public_events(
	stack: ResolutionStack,
	events: Array[Dictionary],
	revision: int,
) -> void:
	var deferred: Array = stack.context.get("deferred_public_events", [])
	var sequence := int(stack.context.get("deferred_public_event_sequence", deferred.size()))
	for event in events:
		if str(event.get("event_id", "")).is_empty():
			event["event_id"] = "deferred:%d:%d:%s" % [
				revision,
				sequence,
				str(event.get("event_type", "event")),
			]
		sequence += 1
		deferred.append(event.duplicate(true))
	stack.context["deferred_public_events"] = deferred
	stack.context["deferred_public_event_sequence"] = sequence


func deferred_public_events(stack: ResolutionStack) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event_value in stack.context.get("deferred_public_events", []):
		if event_value is Dictionary:
			result.append(Dictionary(event_value).duplicate(true))
	return result


func clear_deferred_public_events(stack: ResolutionStack) -> void:
	stack.context.erase("deferred_public_events")
	stack.context.erase("deferred_public_event_sequence")
	stack.context.erase("cancel_action_checkpoint")
	stack.context.erase("cancel_action_snapshot")
	stack.context.erase("cancel_action_rng_state")
	stack.context.erase("cancel_action_events")
	stack.context.erase("cancel_action_event_capacity")


func cancelled_trainer_return_event(
	stack: ResolutionStack,
	actor: int,
) -> Dictionary:
	for event in deferred_public_events(stack):
		if str(event.get("event_type", "")) not in [
			"trainer_played", "stadium_changed",
		]:
			continue
		var source := Dictionary(event.get("source", {}))
		var played_target := Dictionary(event.get("target", {})).duplicate(true)
		if str(played_target.get("zone", "")).is_empty():
			played_target = {"player": actor, "zone": "discard"}
		var card_id := str(event.get("card_id", Dictionary(event.get(
			"data", {})).get("card_id", "")))
		return {
			"event_id": "%s:cancel" % str(event.get("event_id", "trainer")),
			"event_type": "card_moved",
			"actor": actor,
			"visibility": "private",
			"card_id": card_id,
			"source": played_target,
			"target": {
				"player": actor,
				"zone": "hand",
				"index": int(source.get("index", -1)),
			},
			"amount": 1,
			"data": {
				"player": actor,
				"card_id": card_id,
				"card_ids": [card_id],
				"source_zone": str(played_target.get("zone", "discard")),
				"target_zone": "hand",
				"target_index": int(source.get("index", -1)),
				"cause": "cancelled_trainer",
			},
		}
	return {}


func restore_cancelled_action(
	state: GameState,
	rng: PortableRandomSource,
	checkpoint: Dictionary,
) -> StepResult:
	var snapshot := Dictionary(checkpoint.get("state", {}))
	# Cancelling is itself an authoritative choice transaction.  The pending
	# action state has already been published at `state.revision`, so restoring
	# the pre-action snapshot must still advance beyond that published revision.
	# Reusing the pending revision leaves remote submitters locked because an
	# equal-revision STATE_UPDATE is not a causal acknowledgement.
	var restored_revision := maxi(
		state.revision,
		int(snapshot.get("revision", state.revision)),
	) + 1
	restore_state(state, snapshot)
	if checkpoint.has("rng_state"):
		rng.set_state(int(checkpoint["rng_state"]))
	if checkpoint.has("event_capacity"):
		state.event_stream.capacity = int(checkpoint["event_capacity"])
	if checkpoint.has("events"):
		state.event_stream._events.assign(checkpoint["events"])
	state.revision = restored_revision
	return StepResult.new(true, "操作已取消。", null, [], state.winner, false)


func rollback_transaction(
	state: GameState,
	rng: PortableRandomSource,
	checkpoint: Dictionary,
) -> void:
	restore_state(state, Dictionary(checkpoint.get("state", {})))
	rng.set_state(int(checkpoint.get("rng_state", rng.get_state())))
	state.event_stream.capacity = int(checkpoint.get("event_capacity", state.event_stream.capacity))
	state.event_stream._events.assign(checkpoint.get("events", []))


func rollback_failed_step(
	state: GameState,
	rng: PortableRandomSource,
	checkpoint: Dictionary,
	step: StepResult,
) -> StepResult:
	rollback_transaction(state, rng, checkpoint)
	step.pending_choice = null
	step.events = []
	step.winner = state.winner
	step.terminal = state.winner >= 0 or state.phase == "GAME_OVER"
	return step


func restore_state(state: GameState, snapshot: Dictionary) -> void:
	var restored := GameState.from_dict(snapshot)
	state.players = restored.players
	state.active_player_idx = restored.active_player_idx
	state.phase = restored.phase
	state.turn_number = restored.turn_number
	state.first_player_idx = restored.first_player_idx
	state.stadium_card_id = restored.stadium_card_id
	state.winner = restored.winner
	state.revision = restored.revision
	state.choice_sequence = restored.choice_sequence
	state.public_deck_keys = restored.public_deck_keys
	state.apply_type_matchups = restored.apply_type_matchups
	state.action_log = restored.action_log
	state.mulligan_count = restored.mulligan_count
	state.extra_draws = restored.extra_draws
	state.setup_ready = restored.setup_ready
	state.pending_promotions = restored.pending_promotions
	state.processed_action_ids = restored.processed_action_ids
	state.resolution_stack = restored.resolution_stack
	state.event_stream = GameEventStream.new()
