class_name PokemonState
extends RefCounted

var card_id: String
var damage_counters := 0
var energy_card_ids: Array[String] = []
var attached_tool_id := ""
var status_conditions: Array[String] = []
var evolution_stack_ids: Array[String] = []
var can_evolve_this_turn := true
var placed_this_turn := true
var used_abilities: Array[String] = []
var healed_this_turn := false
var damage_prevented_next_turn := false
var all_prevented_next_turn := false
var outgoing_damage_reduction_next_turn := 0
var attack_locked := false
var attack_locked_names: Dictionary = {}
var dazzled := false
var modifiers: Array[Dictionary] = []
var paralyzed_since_turn := 0


func _init(p_card_id: String = "") -> void:
	card_id = p_card_id


func current_hp(catalog: CardCatalog) -> int:
	return VMPokemonStatHooks.current_hp(self, catalog)


func is_knocked_out(catalog: CardCatalog) -> bool:
	return current_hp(catalog) <= 0


func available_energy(catalog: CardCatalog) -> Array[String]:
	return EnergyView.units_for_cards(energy_card_ids, catalog)


func has_enough_energy(cost: Array, catalog: CardCatalog) -> bool:
	return EnergyView.can_pay_cost(energy_card_ids, cost, catalog)


func clear_special_conditions_and_attack_effects() -> void:
	# Evolving or moving an Active Pokemon to the Bench removes Special
	# Conditions and effects of attacks on that Pokemon. Card attachments,
	# damage, the evolution stack and persistent card modifiers remain.
	status_conditions.clear()
	damage_prevented_next_turn = false
	all_prevented_next_turn = false
	outgoing_damage_reduction_next_turn = 0
	attack_locked = false
	attack_locked_names.clear()
	dazzled = false
	paralyzed_since_turn = 0


func to_dict() -> Dictionary:
	var payload := {
		"card_id": card_id,
		"damage_counters": damage_counters,
		"energy_card_ids": energy_card_ids.duplicate(),
		"attached_tool_id": attached_tool_id,
		"status_conditions": status_conditions.duplicate(),
		"evolution_stack_ids": evolution_stack_ids.duplicate(),
		"can_evolve_this_turn": can_evolve_this_turn,
		"placed_this_turn": placed_this_turn,
		"used_abilities": used_abilities.duplicate(),
		"healed_this_turn": healed_this_turn,
		"damage_prevented_next_turn": damage_prevented_next_turn,
		"all_prevented_next_turn": all_prevented_next_turn,
		"outgoing_damage_reduction_next_turn": outgoing_damage_reduction_next_turn,
		"attack_locked": attack_locked,
		"attack_locked_names": attack_locked_names.duplicate(true),
		"dazzled": dazzled,
		"paralyzed_since_turn": paralyzed_since_turn,
	}
	if not modifiers.is_empty():
		payload["modifiers"] = modifiers.duplicate(true)
	return payload


func clone_state() -> PokemonState:
	var result := PokemonState.new(card_id)
	result.damage_counters = damage_counters
	result.energy_card_ids.assign(energy_card_ids)
	result.attached_tool_id = attached_tool_id
	result.status_conditions.assign(status_conditions)
	result.evolution_stack_ids.assign(evolution_stack_ids)
	result.can_evolve_this_turn = can_evolve_this_turn
	result.placed_this_turn = placed_this_turn
	result.used_abilities.assign(used_abilities)
	result.healed_this_turn = healed_this_turn
	result.damage_prevented_next_turn = damage_prevented_next_turn
	result.all_prevented_next_turn = all_prevented_next_turn
	result.outgoing_damage_reduction_next_turn = outgoing_damage_reduction_next_turn
	result.attack_locked = attack_locked
	result.attack_locked_names = attack_locked_names.duplicate(true)
	result.dazzled = dazzled
	result.modifiers.assign(modifiers.duplicate(true))
	result.paralyzed_since_turn = paralyzed_since_turn
	return result


static func from_dict(data: Dictionary) -> PokemonState:
	var result := PokemonState.new(str(data.get("card_id", "")))
	result.damage_counters = int(data.get("damage_counters", 0))
	result.energy_card_ids.assign(data.get("energy_card_ids", []))
	result.attached_tool_id = str(data.get("attached_tool_id", ""))
	result.status_conditions.assign(data.get("status_conditions", []))
	result.evolution_stack_ids.assign(data.get("evolution_stack_ids", []))
	result.can_evolve_this_turn = bool(data.get("can_evolve_this_turn", true))
	result.placed_this_turn = bool(data.get("placed_this_turn", true))
	result.used_abilities.assign(data.get("used_abilities", []))
	result.healed_this_turn = bool(data.get("healed_this_turn", false))
	result.damage_prevented_next_turn = bool(data.get("damage_prevented_next_turn", false))
	result.all_prevented_next_turn = bool(data.get("all_prevented_next_turn", false))
	result.outgoing_damage_reduction_next_turn = int(data.get("outgoing_damage_reduction_next_turn", 0))
	result.attack_locked = bool(data.get("attack_locked", false))
	result.attack_locked_names = Dictionary(data.get("attack_locked_names", {})).duplicate(true)
	result.dazzled = bool(data.get("dazzled", false))
	for modifier in data.get("modifiers", []):
		if modifier is Dictionary:
			result.modifiers.append(Dictionary(modifier).duplicate(true))
	result.paralyzed_since_turn = int(data.get("paralyzed_since_turn", 0))
	return result
