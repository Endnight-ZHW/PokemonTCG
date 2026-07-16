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
	if state.is_terminal():
		return StepResult.new(true, "", null, [], state.winner, true)
	if actor != state.active_player_idx:
		return StepResult.new(false, "不是你的回合。", null, [], state.winner, false, "wrong_actor")
	var events: Array[Dictionary] = [{
		"event_type": "turn_end",
		"actor": actor,
		"target": {"player": actor, "slot": "active"},
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
	var stack := ResolutionStack.new()
	stack.context["finish_end_turn_after_knockouts"] = true
	stack.context["end_turn_actor"] = actor
	var checkup_causes: Dictionary = {}
	for event in events:
		var event_data: Dictionary = event.get("data", {})
		if (
			str(event.get("event_type", "")) != "damage_dealt"
			or not bool(event_data.get("checkup", false))
		):
			continue
		var affected_player := int(event_data.get("player", -1))
		var key := "%d:active" % affected_player
		var existing: Dictionary = checkup_causes.get(key, {
			"source_kind": "special_condition",
			"cause_kind": "special_condition",
			"source_player": -1,
			"cause_details": [],
		})
		var details: Array = existing.get("cause_details", [])
		details.append(str(event_data.get("cause", "")))
		existing["cause_details"] = details
		checkup_causes[key] = existing
	stack.context["knockout_causes"] = checkup_causes
	var ko_result := knockout_settlement.resolve_knockouts(
		state, actor, events, false, stack)
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
	var pending_choice: Variant = ko_result.get("pending_choice", null)
	if pending_choice is ChoiceRequest:
		state.resolution_stack = stack.to_dict()
		return StepResult.new(
			true, "请完成昏厥结算。", pending_choice, events, state.winner, false)
	stack.context.erase("finish_end_turn_after_knockouts")
	stack.context.erase("end_turn_actor")
	state.resolution_stack = stack.to_dict()
	return finish_end_turn_after_knockouts(state, actor, rng, events)


func finish_end_turn_after_knockouts(
	state: GameState,
	actor: int,
	rng: PortableRandomSource,
	events: Array[Dictionary] = [],
) -> StepResult:
	# A paused checkup KO can resume here only after its final prize choice. Re-run
	# the batch result evaluation before advancing the turn: taking the last prize
	# (or simultaneous conditions becoming true) is terminal and must never leak
	# into promotion, turn-start, or draw presentation.
	knockout_settlement.resolve_empty_boards_and_promotions(state)
	if state.is_terminal():
		knockout_settlement.append_game_over_event(events, state)
		state.resolution_stack = ResolutionStack.new().to_dict()
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
	state.advance_turn_facts()
	state.active_player_idx = 1 - actor
	state.turn_number += 1
	state.get_player(state.active_player_idx).reset_turn_flags()
	state.phase = "DRAW"
	var incoming := state.get_player(state.active_player_idx)
	if incoming.active == null and incoming.bench_count() > 0:
		if state.active_player_idx not in state.pending_promotions:
			state.pending_promotions.append(state.active_player_idx)
	# Every checkup KO must be promoted before the next turn can draw.  This is
	# intentionally broader than checking only the incoming player: the player
	# whose turn just ended can also be KO'd by Poison/Burn.
	if not state.pending_promotions.is_empty():
		return StepResult.new(true, "需要选择新的战斗宝可梦。", null, events)
	var begin := begin_turn(state, rng)
	begin.events = events + begin.events
	return begin


func begin_turn(
	state: GameState,
	_rng: PortableRandomSource,
) -> StepResult:
	var player := state.get_player(state.active_player_idx)
	var events: Array[Dictionary] = [{
		"event_type": "turn_start",
		"actor": state.active_player_idx,
		"target": {"player": state.active_player_idx, "slot": "active"},
		"data": {"player": state.active_player_idx, "turn": state.turn_number},
	}]
	var drawn := player.draw_cards(1)
	if drawn.is_empty():
		state.set_win(1 - state.active_player_idx, "deck_exhausted", [
			[], ["opponent_deck_exhausted"]
		] if state.active_player_idx == 0 else [
			["opponent_deck_exhausted"], []
		])
		events.append({
			"event_type": "deck_exhausted",
			"actor": state.active_player_idx,
			"source": {"player": state.active_player_idx, "zone": "deck"},
			"data": {"player": state.active_player_idx, "reason": "draw_failed"},
		})
		events.append({
			"event_type": "game_over",
			"actor": state.winner,
			"data": {
				"result_status": state.result_status,
				"winner": state.winner,
				"reason": "deck_exhausted",
				"loser": state.active_player_idx,
			},
		})
		return StepResult.new(
			true, "牌库耗尽。", null, events, state.winner, true)
	events.append({
		"event_type": "cards_drawn",
		"actor": state.active_player_idx,
		"visibility": "owner",
		"card_id": drawn[0],
		"source": {"player": state.active_player_idx, "zone": "deck"},
		"target": {"player": state.active_player_idx, "zone": "hand"},
		"data": {
			"player": state.active_player_idx,
			"count": drawn.size(),
			"card_ids": drawn.duplicate(),
			"purpose": "turn_draw",
			"turn": state.turn_number,
		},
	})
	state.phase = "MAIN"
	state.log_action("—— %s的第%d回合 ——" % [player.name, state.turn_number])
	return StepResult.new(true, "回合开始。", null, events)


func resolve_checkup(
	state: GameState,
	rng: PortableRandomSource,
	events: Array[Dictionary],
) -> void:
	events.append({
		"event_type": "checkup",
		"actor": state.active_player_idx,
		"target": {"player": state.active_player_idx, "slot": "active"},
		"data": {
			"player": state.active_player_idx,
			"turn": state.turn_number,
		},
	})
	# Pokemon Checkup is ordered by condition, not by player: resolve Poison
	# for both Active Pokemon, then Burn, Asleep, and finally Paralyzed.  KO is
	# checked only after every condition has finished, so damage remains
	# simultaneous while the public event stream keeps the official causality.
	for player_idx in [0, 1]:
		var pokemon := state.get_player(player_idx).active
		if pokemon != null and "POISONED" in pokemon.status_conditions:
			pokemon.damage_counters += 1
			events.append(_checkup_damage_event(player_idx, 10, "poisoned"))
	for player_idx in [0, 1]:
		var pokemon := state.get_player(player_idx).active
		if pokemon == null:
			continue
		if "BURNED" in pokemon.status_conditions:
			pokemon.damage_counters += 2
			events.append(_checkup_damage_event(player_idx, 20, "burned"))
			var burn_recovered := rng.coin()
			events.append(_checkup_coin_event(player_idx, burn_recovered, "burned"))
			if burn_recovered:
				pokemon.status_conditions.erase("BURNED")
				events.append(_status_removed_event(player_idx, "BURNED", "checkup_coin"))
	for player_idx in [0, 1]:
		var pokemon := state.get_player(player_idx).active
		if pokemon == null:
			continue
		if "ASLEEP" in pokemon.status_conditions:
			var woke_up := rng.coin()
			events.append(_checkup_coin_event(player_idx, woke_up, "asleep"))
			if woke_up:
				pokemon.status_conditions.erase("ASLEEP")
				events.append(_status_removed_event(player_idx, "ASLEEP", "checkup_coin"))
	for player_idx in [0, 1]:
		var pokemon := state.get_player(player_idx).active
		if pokemon == null:
			continue
		if (
			"PARALYZED" in pokemon.status_conditions
			and state.turn_number > pokemon.paralyzed_since_turn
		):
			pokemon.status_conditions.erase("PARALYZED")
			events.append(_status_removed_event(player_idx, "PARALYZED", "checkup_expired"))


func _checkup_damage_event(player_idx: int, amount: int, cause: String) -> Dictionary:
	return {
		"event_type": "damage_dealt",
		"actor": player_idx,
		"source": {"player": player_idx, "slot": "active"},
		"target": {"player": player_idx, "slot": "active"},
		"amount": amount,
		"data": {
			"player": player_idx,
			"slot": "active",
			"amount": amount,
			"cause": cause,
			"checkup": true,
		},
	}


func _checkup_coin_event(player_idx: int, result: bool, purpose: String) -> Dictionary:
	return {
		"event_type": "coin_flip",
		"actor": player_idx,
		"source": {"player": player_idx, "slot": "active"},
		"target": {"player": player_idx, "slot": "active"},
		"data": {
			"results": [result],
			"purpose": "checkup_%s" % purpose,
			"player": player_idx,
		},
	}


func _status_removed_event(player_idx: int, status: String, cause: String) -> Dictionary:
	return {
		"event_type": "status_removed",
		"actor": player_idx,
		"source": {"player": player_idx, "slot": "active"},
		"target": {"player": player_idx, "slot": "active"},
		"data": {
			"player": player_idx,
			"slot": "active",
			"status": status,
			"cause": cause,
			"checkup": true,
		},
	}
