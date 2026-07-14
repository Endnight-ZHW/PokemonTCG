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
		var defeated_slot := str(knockout["slot"])
		var discard_index := defeated_player.discard.size()
		var discarded_card_ids: Array[String] = [knocked_out.card_id]
		discarded_card_ids.append_array(knocked_out.evolution_stack_ids)
		if not knocked_out.attached_tool_id.is_empty():
			discarded_card_ids.append(knocked_out.attached_tool_id)
		discarded_card_ids.append_array(knocked_out.energy_card_ids)
		state.discard_pokemon(defeated_idx, defeated_slot)
		var winner_idx := 1 - defeated_idx
		var source_index := (
			defeated_slot.trim_prefix("bench_").to_int()
			if defeated_slot.begins_with("bench_")
			else 0
		)
		events.append({
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
				"zone": "discard",
				"index": discard_index,
			},
			"amount": discarded_card_ids.size(),
			"data": knockout.merged({
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
	return VMResult.ok()


func resolve_empty_boards_and_promotions(state: GameState) -> void:
	for player_idx in [0, 1]:
		var player := state.get_player(player_idx)
		if (
			player.active == null
			and player.bench_count() > 0
			and player_idx not in state.pending_promotions
		):
			state.pending_promotions.append(player_idx)
	var rules_winner := validator.check_winner(state)
	if rules_winner >= 0:
		state.winner = rules_winner
		state.phase = "GAME_OVER"
