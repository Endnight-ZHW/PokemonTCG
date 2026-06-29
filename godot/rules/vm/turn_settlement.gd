class_name VMTurnSettlement
extends RefCounted

var knockout_settlement: VMKnockoutSettlement


func _init(p_knockout_settlement: VMKnockoutSettlement) -> void:
	knockout_settlement = p_knockout_settlement


func end_turn(
	state: GameState,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	if state.winner >= 0:
		return StepResult.new(true, "", null, [], state.winner, true)
	if actor != state.active_player_idx:
		return StepResult.new(false, "不是你的回合。", null, [], state.winner, false, "wrong_actor")
	var events: Array[Dictionary] = [{
		"event_type": "turn_end",
		"data": {"player": actor, "turn": state.turn_number},
	}]
	state.phase = "POKEMON_CHECKUP"
	resolve_checkup(state, rng, events)
	if knockout_settlement == null:
		return StepResult.new(
			false,
			"回合结算缺少 KO 结算器。",
			null,
			events,
			state.winner,
			false,
			"missing_knockout_settlement",
		)
	var ko_result := knockout_settlement.resolve_knockouts(state, actor, events, false)
	if not bool(ko_result.get("success", false)):
		return StepResult.new(
			false,
			str(ko_result.get("message", "触发命令结算失败。")),
			null,
			events,
			state.winner,
			false,
			str(ko_result.get("error_code", "trigger_command_failed")),
		)
	if state.winner >= 0:
		return StepResult.new(true, "对局结束。", null, events, state.winner, true)
	var outgoing := state.get_player(actor)
	for row in outgoing.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon:
			pokemon.outgoing_damage_reduction_next_turn = 0
			pokemon.dazzled = false
			pokemon.attack_locked = false
			var expired: Array[String] = []
			for attack_name in pokemon.attack_locked_names:
				if state.turn_number >= int(pokemon.attack_locked_names[attack_name]) + 2:
					expired.append(str(attack_name))
			for attack_name in expired:
				pokemon.attack_locked_names.erase(attack_name)
	outgoing.was_ko_by_attack = false
	state.active_player_idx = 1 - actor
	state.turn_number += 1
	state.get_player(state.active_player_idx).reset_turn_flags()
	state.phase = "DRAW"
	var incoming := state.get_player(state.active_player_idx)
	if incoming.active == null and incoming.bench_count() > 0:
		if state.active_player_idx not in state.pending_promotions:
			state.pending_promotions.append(state.active_player_idx)
		return StepResult.new(true, "需要选择新的战斗宝可梦。", null, events)
	var begin := begin_turn(state, rng)
	begin.events = events + begin.events
	return begin


func begin_turn(
	state: GameState,
	_rng: PortableRandomSource,
) -> StepResult:
	var player := state.get_player(state.active_player_idx)
	var events: Array[Dictionary] = []
	if state.turn_number != 1:
		var drawn := player.draw_cards(1)
		if drawn.is_empty():
			state.winner = 1 - state.active_player_idx
			state.phase = "GAME_OVER"
			return StepResult.new(
				true, "牌库耗尽。", null, [], state.winner, true)
		events.append({
			"event_type": "cards_drawn",
			"actor": state.active_player_idx,
			"visibility": "owner",
			"card_id": drawn[0] if not drawn.is_empty() else "",
			"source": {"player": state.active_player_idx, "zone": "deck"},
			"target": {"player": state.active_player_idx, "zone": "hand"},
			"data": {
				"player": state.active_player_idx,
				"count": drawn.size(),
				"card_ids": drawn.duplicate(),
			},
		})
	state.phase = "MAIN"
	state.log_action("—— %s的第%d回合 ——" % [player.name, state.turn_number])
	events.append({
		"event_type": "turn_start",
		"actor": state.active_player_idx,
		"data": {"player": state.active_player_idx, "turn": state.turn_number},
	})
	return StepResult.new(true, "回合开始。", null, events)


func resolve_checkup(
	state: GameState,
	rng: PortableRandomSource,
	events: Array[Dictionary],
) -> void:
	for player_idx in [0, 1]:
		var pokemon := state.get_player(player_idx).active
		if pokemon == null:
			continue
		if "POISONED" in pokemon.status_conditions:
			pokemon.damage_counters += 1
		if "BURNED" in pokemon.status_conditions:
			pokemon.damage_counters += 2
			if rng.coin():
				pokemon.status_conditions.erase("BURNED")
		if "ASLEEP" in pokemon.status_conditions and rng.coin():
			pokemon.status_conditions.erase("ASLEEP")
		if (
			"PARALYZED" in pokemon.status_conditions
			and state.turn_number > pokemon.paralyzed_since_turn
		):
			pokemon.status_conditions.erase("PARALYZED")
	events.append({"event_type": "checkup", "data": {"turn": state.turn_number}})
