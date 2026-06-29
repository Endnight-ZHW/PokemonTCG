class_name VMCombatConditionals
extends RefCounted

var catalog: CardCatalog
var damage: VMCombatDamage


func _init(p_catalog: CardCatalog, p_damage: VMCombatDamage) -> void:
	catalog = p_catalog
	damage = p_damage


func conditional_effect(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	if params.get("condition", "") == "ko_by_attack_last_turn":
		if not player.was_ko_by_attack:
			return VMResult.fail("条件未满足。")
		player.was_ko_by_attack = false
	var on_pay: Variant = params.get("on_pay")
	if on_pay is Dictionary:
		stack.push_effect(on_pay, player_idx, source_slot)
	elif on_pay is Array:
		stack.push_effects(on_pay, player_idx, source_slot)
	var cost: Variant = params.get("cost")
	if cost is Dictionary:
		stack.push_effect(cost, player_idx, source_slot)
	elif cost is Array:
		stack.push_effects(cost, player_idx, source_slot)
	return VMResult.ok()


func conditional_damage_bonus(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	params: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var opponent := state.get_player(1 - player_idx)
	var condition := str(params.get("condition", ""))
	var applies := false
	match condition:
		"opponent_active_damaged":
			applies = opponent.active != null and opponent.active.damage_counters > 0
		"ko_by_attack_last_turn":
			applies = player.was_ko_by_attack
			player.was_ko_by_attack = false
		"opponent_active_evolved":
			applies = opponent.active != null and not catalog.is_basic_pokemon(opponent.active.card_id)
		"field_energy_ge_5":
			var count := 0
			for row in player.get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				if pokemon:
					count += pokemon.energy_card_ids.size()
			applies = count >= 5
	if not applies:
		return VMResult.ok("追加伤害条件未满足。")
	return damage.deal_attack_or_effect_damage(
		state, stack, player_idx, 1 - player_idx, "active",
		int(params.get("bonus", 0)), events)
