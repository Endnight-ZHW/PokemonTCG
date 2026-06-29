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
		state.discard_pokemon(defeated_idx, str(knockout["slot"]))
		var winner_idx := 1 - defeated_idx
		for _index in range(int(knockout["prizes"])):
			var prize_card_id := state.get_player(winner_idx).take_prize()
			events.append({
				"event_type": "prize_taken",
				"actor": winner_idx,
				"visibility": "owner",
				"card_id": prize_card_id,
				"source": {"player": winner_idx, "zone": "prizes"},
				"target": {"player": winner_idx, "zone": "hand"},
				"data": {
					"player": winner_idx,
					"count": 1,
					"card_id": prize_card_id,
				},
			})
		if from_attack and defeated_idx != attack_actor:
			defeated_player.was_ko_by_attack = true
		events.append({"event_type": "pokemon_ko", "data": knockout.duplicate(true)})
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
