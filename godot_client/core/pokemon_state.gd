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
var damage_prevented_next_turn := false
var all_prevented_next_turn := false
var attack_locked := false
var attack_locked_names: Dictionary = {}
var dazzled := false
var paralyzed_since_turn := 0


func _init(p_card_id: String = "") -> void:
	card_id = p_card_id


func current_hp(catalog: CardCatalog) -> int:
	var card := catalog.get_card(card_id)
	var hp := int(card.get("hp", 0))
	if not attached_tool_id.is_empty():
		for effect in catalog.get_card(attached_tool_id).get("trainer_effects", []):
			if (
				effect.get("params", {}).get("effect", "") == "hp_boost_basic"
				and catalog.is_basic_pokemon(card_id)
			):
				hp += 50
	return max(0, hp - damage_counters * 10)


func is_knocked_out(catalog: CardCatalog) -> bool:
	return current_hp(catalog) <= 0


func available_energy(catalog: CardCatalog) -> Array[String]:
	var result: Array[String] = []
	for energy_id in energy_card_ids:
		result.append_array(catalog.provides_energy(energy_id))
	if "svg2-lume" in energy_card_ids:
		for energy_id in energy_card_ids:
			if energy_id != "svg2-lume" and catalog.is_special_energy(energy_id):
				for index in range(result.size()):
					if result[index] == "Rainbow":
						result[index] = "Colorless"
				break
	return result


func has_enough_energy(cost: Array, catalog: CardCatalog) -> bool:
	var available := available_energy(catalog)
	for required_value in cost:
		var required := str(required_value)
		if required == "Colorless":
			continue
		var index := available.find(required)
		if index < 0:
			index = available.find("Rainbow")
		if index < 0:
			return false
		available.remove_at(index)
	var colorless_count := 0
	for required_value in cost:
		if str(required_value) == "Colorless":
			colorless_count += 1
	return available.size() >= colorless_count


func to_dict() -> Dictionary:
	return {
		"card_id": card_id,
		"damage_counters": damage_counters,
		"energy_card_ids": energy_card_ids.duplicate(),
		"attached_tool_id": attached_tool_id,
		"status_conditions": status_conditions.duplicate(),
		"evolution_stack_ids": evolution_stack_ids.duplicate(),
		"can_evolve_this_turn": can_evolve_this_turn,
		"placed_this_turn": placed_this_turn,
		"used_abilities": used_abilities.duplicate(),
		"damage_prevented_next_turn": damage_prevented_next_turn,
		"all_prevented_next_turn": all_prevented_next_turn,
		"attack_locked": attack_locked,
		"attack_locked_names": attack_locked_names.duplicate(true),
		"dazzled": dazzled,
		"paralyzed_since_turn": paralyzed_since_turn,
	}


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
	result.damage_prevented_next_turn = bool(data.get("damage_prevented_next_turn", false))
	result.all_prevented_next_turn = bool(data.get("all_prevented_next_turn", false))
	result.attack_locked = bool(data.get("attack_locked", false))
	result.attack_locked_names = Dictionary(data.get("attack_locked_names", {})).duplicate(true)
	result.dazzled = bool(data.get("dazzled", false))
	result.paralyzed_since_turn = int(data.get("paralyzed_since_turn", 0))
	return result
