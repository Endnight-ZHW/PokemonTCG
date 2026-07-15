class_name VMKnockoutSettlement
extends RefCounted

var catalog: CardCatalog
var validator: RulesValidator
var trigger_command_runner: VMTriggerCommands


func _init(
	p_catalog: CardCatalog,
	p_validator: RulesValidator,
	p_trigger_command_runner: VMTriggerCommands = null,
) -> void:
	catalog = p_catalog
	validator = p_validator
	if p_trigger_command_runner != null:
		trigger_command_runner = p_trigger_command_runner
	else:
		trigger_command_runner = VMTriggerCommands.new(catalog)


func resolve_knockouts(
	state: GameState,
	attack_actor: int,
	events: Array[Dictionary],
	from_attack: bool,
	active_stack: ResolutionStack = null,
) -> Dictionary:
	var knockouts: Array[Dictionary] = []
	for player_idx in [0, 1]:
		for row in state.get_player(player_idx).get_all_pokemon():
			var pokemon: PokemonState = row["pokemon"]
			if pokemon and pokemon.is_knocked_out(catalog):
				knockouts.append({
					"player": player_idx,
					"slot": str(row["slot"]),
					"card_id": pokemon.card_id,
				"prizes": catalog.prize_value(pokemon.card_id),
			})
	if knockouts.is_empty():
		return VMResult.ok()
	var pending_prize_events: Array[Dictionary] = []
	for knockout in knockouts:
		var defeated_idx := int(knockout["player"])
		var defeated_player := state.get_player(defeated_idx)
		var knocked_out := defeated_player.get_pokemon(str(knockout["slot"]))
		if knocked_out == null:
			continue
		var defeated_slot := str(knockout["slot"])
		var source_index := (
			defeated_slot.trim_prefix("bench_").to_int()
			if defeated_slot.begins_with("bench_")
			else 0
		)
		# Announce the KO while the source Pokemon and its attachments still
		# exist. KO triggers such as Exp. Share then have a truthful visual
		# source; the separate leave-play event below performs the discard.
		var ko_event := {
			"event_type": "pokemon_ko",
			"actor": attack_actor,
			"card_id": str(knockout["card_id"]),
			"source": {
				"player": defeated_idx,
				"slot": defeated_slot,
				"index": source_index,
			},
			"target": {
				"player": defeated_idx,
				"slot": defeated_slot,
			},
			"amount": 1,
			"data": knockout.merged({
				"stage": "declared",
				"defer_leave_play": true,
				"presentation_phase": "knockout",
			}, true),
		}
		events.append(ko_event)
		var trigger_commands_to_resolve: Array[Dictionary] = []
		trigger_command_runner.collect_pokemon_ko_commands(
			state,
			defeated_idx,
			str(knockout["slot"]),
			knocked_out,
			from_attack,
			attack_actor,
			trigger_commands_to_resolve,
		)
		var trigger_result := trigger_command_runner.resolve_commands(
			state,
			attack_actor,
			trigger_commands_to_resolve,
			events,
			active_stack,
		)
		if not bool(trigger_result.get("success", false)):
			return trigger_result
		var discard_index := defeated_player.discard.size()
		var discarded_card_ids: Array[String] = [knocked_out.card_id]
		discarded_card_ids.append_array(knocked_out.evolution_stack_ids)
		if not knocked_out.attached_tool_id.is_empty():
			discarded_card_ids.append(knocked_out.attached_tool_id)
		discarded_card_ids.append_array(knocked_out.energy_card_ids)
		state.discard_pokemon(defeated_idx, defeated_slot)
		var winner_idx := 1 - defeated_idx
		ko_event["data"] = Dictionary(ko_event["data"]).merged({
			"count": discarded_card_ids.size(),
			"card_ids": discarded_card_ids,
		}, true)
		events.append({
			"event_type": "card_moved",
			"actor": attack_actor,
			"card_id": str(knockout["card_id"]),
			"source": {
				"player": defeated_idx,
				"slot": defeated_slot,
				"index": source_index,
			},
			"target": {
				"player": defeated_idx,
				"zone": "discard",
				"index": discard_index,
			},
			"amount": discarded_card_ids.size(),
			"data": knockout.merged({
				"cause": "pokemon_ko",
				"ko_leave_play": true,
				"presentation_phase": "knockout",
				"count": discarded_card_ids.size(),
				"card_ids": discarded_card_ids,
			}, true),
		})
		for _index in range(int(knockout["prizes"])):
			var winner := state.get_player(winner_idx)
			var hand_index := winner.hand.size()
			var prize_card_id := winner.take_prize()
			if prize_card_id.is_empty():
				break
			pending_prize_events.append({
				"event_type": "prize_taken",
				"actor": winner_idx,
				"visibility": "owner",
				"card_id": prize_card_id,
				"source": {"player": winner_idx, "zone": "prizes", "index": 0},
				"target": {"player": winner_idx, "zone": "hand", "index": hand_index},
				"data": {
					"player": winner_idx,
					"count": 1,
					"card_id": prize_card_id,
					"source_index": 0,
					"target_index": hand_index,
				},
			})
		if from_attack and defeated_idx != attack_actor:
			defeated_player.was_ko_by_attack = true
	events.append_array(pending_prize_events)
	resolve_empty_boards_and_promotions(state)
	if state.winner >= 0:
		_append_game_over_event(events, state.winner)
	return VMResult.ok()


func resolve_empty_boards_and_promotions(state: GameState) -> void:
	var turn_order: Array[int] = [state.active_player_idx, 1 - state.active_player_idx]
	var ordered_pending: Array[int] = []
	for player_idx in turn_order:
		var player := state.get_player(player_idx)
		if (
			player.active == null
			and player.bench_count() > 0
		):
			ordered_pending.append(player_idx)
	state.pending_promotions.assign(ordered_pending)
	var rules_winner := validator.check_winner(state)
	if rules_winner >= 0:
		state.winner = rules_winner
		state.phase = "GAME_OVER"
		# A terminal batch cannot also wait for promotion.  The winner is only
		# decided after every simultaneous KO and prize has settled, so any
		# provisional promotion rows computed above are now stale.
		state.pending_promotions.clear()


func _append_game_over_event(
	events: Array[Dictionary],
	winner: int,
) -> void:
	# Settlement may be reached through action, choice, attack, or checkup
	# wrappers.  Normalize any pre-existing terminal marker so this batch exposes
	# exactly one, in the only causally valid position after all prize events.
	for index in range(events.size() - 1, -1, -1):
		if str(events[index].get("event_type", "")) == "game_over":
			events.remove_at(index)
	events.append({
		"event_type": "game_over",
		"actor": winner,
		"data": {
			"winner": winner,
			"loser": 1 - winner,
			"reason": "knockout",
		},
	})
