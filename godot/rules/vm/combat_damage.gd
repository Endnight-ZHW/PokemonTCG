class_name VMCombatDamage
extends RefCounted

const DAMAGE_PER_COUNTER := 10


func deal_attack_or_effect_damage(
	state: GameState,
	stack: ResolutionStack,
	attacker_idx: int,
	target_player_idx: int,
	slot: String,
	amount: int,
	events: Array[Dictionary],
	consume_effect_immunity: bool = true,
) -> Dictionary:
	if (
		bool(stack.context.get("finish_attack", false))
		and target_player_idx == 1 - attacker_idx
		and slot == "active"
	):
		stack.context["base_damage"] = int(stack.context.get("base_damage", 0)) + max(0, amount)
		return VMResult.ok("攻击伤害已加入结算。")
	return deal_damage(
		state,
		target_player_idx,
		slot,
		amount,
		events,
		consume_effect_immunity,
		stack,
		attacker_idx,
	)


func deal_damage(
	state: GameState,
	player_idx: int,
	slot: String,
	amount: int,
	events: Array[Dictionary],
	_consume_effect_immunity: bool = true,
	stack: ResolutionStack = null,
	source_player_idx: int = -1,
) -> Dictionary:
	var pokemon := state.get_player(player_idx).get_pokemon(slot)
	if pokemon == null or amount <= 0:
		return VMResult.ok()
	var from_blockable_attack := (
		stack != null
		and stack.is_blockable_opponent_attack_effect(source_player_idx, player_idx)
	)
	if from_blockable_attack and pokemon.damage_prevented_next_turn:
		events.append({
			"event_type": "damage_prevented",
			"target": {"player": player_idx, "slot": slot},
			"data": {
				"player": player_idx,
				"slot": slot,
				"reason": "damage_immunity",
			},
		})
		return VMResult.ok("伤害被免疫。")
	var applied_counters := int(amount / DAMAGE_PER_COUNTER)
	if applied_counters <= 0:
		return VMResult.ok()
	var applied_amount := applied_counters * DAMAGE_PER_COUNTER
	pokemon.damage_counters += applied_counters
	events.append({"event_type": "damage_dealt", "data": {
		"player": player_idx, "slot": slot, "amount": applied_amount,
	}})
	return VMResult.ok("造成%d点伤害。" % applied_amount)


func heal_pokemon(
	state: GameState,
	player_idx: int,
	slot: String,
	amount: int,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var pokemon := player.get_pokemon(slot)
	if pokemon == null:
		return VMResult.fail("没有回复目标。")
	var counters := int(amount / DAMAGE_PER_COUNTER)
	var healed: int = min(pokemon.damage_counters, counters)
	pokemon.damage_counters -= healed
	if healed > 0:
		player.healed_this_turn = true
		events.append({"event_type": "healed", "data": {
			"player": player_idx, "slot": slot, "amount": healed * DAMAGE_PER_COUNTER,
		}})
	return VMResult.ok()


func selected_target_damage(
	state: GameState,
	stack: ResolutionStack,
	selected: Array[Dictionary],
	source_player: int,
	target_player: int,
	amount: int,
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return VMResult.fail("没有选择目标。")
	return deal_damage(
		state, target_player,
		str(selected[0].get("value", {}).get("slot", "")),
		amount, events, true, stack, source_player)


func selected_bench_damage(
	state: GameState,
	stack: ResolutionStack,
	selected: Array[Dictionary],
	source_player: int,
	target_player: int,
	amount: int,
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return VMResult.fail("没有选择目标。")
	for option in selected:
		var slot := str(option.get("value", {}).get("slot", ""))
		if slot.begins_with("bench_"):
			deal_damage(
				state, target_player, slot, amount, events,
				true, stack, source_player)
	return VMResult.ok("备战伤害已结算。")
