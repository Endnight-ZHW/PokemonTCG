class_name VMRuntimeEffects
extends RefCounted

const OP_ALIASES := {
	"apply_attack_lock_basic": "attack_lock_basic",
	"apply_dazzling_beam": "dazzling_beam",
	"apply_outgoing_damage_reduction": "apply_outgoing_damage_reduction",
	"apply_self_attack_lock": "self_attack_lock",
	"apply_status": "status",
	"attach_energy": "energy_attach",
	"attach_energy_from_discard": "attach_from_discard",
	"choose_damage_target": "any_pokemon_damage",
	"conditional": "conditional",
	"conditional_damage": "conditional_damage_bonus",
	"conditional_damage_then_heal": "conditional_damage_heal",
	"conditional_search": "conditional_search_extra",
	"conditional_status": "conditional_status",
	"deal_bench_damage": "bench_damage",
	"deal_damage": "damage",
	"deal_damage_then_heal": "damage_and_self_heal",
	"discard_cards": "discard",
	"discard_energy": "energy_discard",
	"discard_energy_then_damage": "discard_fighting_energy_damage",
	"discard_hand_then_damage": "discard_hand_conditional_bonus",
	"discard_then_draw_cards": "discard_then_draw",
	"discard_then_revive": "ability_discard_revive",
	"draw_and_attach_energy": "draw_and_attach_energy",
	"draw_cards": "draw",
	"draw_until": "draw_until",
	"draw_until_more_than_opponent": "draw_until_more",
	"evolve_skip_stage": "evolve_skip_stage",
	"fail_attack": "attack_fail",
	"flip_coin": "coin_flip",
	"flip_coin_repeat_damage": "coin_flip_triple",
	"flip_coin_then_discard_energy": "coin_flip_energy_discard",
	"flip_coin_then_ko": "coin_flip_double_ko",
	"flip_until_tails": "coin_flip_until_tails",
	"hand_to_bottom_draw_until": "houb",
	"hand_to_bottom_then_draw": "hand_to_bottom_draw",
	"heal_all": "heal_all",
	"heal_damage": "heal",
	"judge": "judge",
	"look_top_attach_energy": "look_top_attach_energy",
	"look_top_deck": "look_top_deck",
	"mill_then_damage": "mill_and_damage_per_energy",
	"place_counters_then_self_ko": "place_counters_and_self_ko",
	"place_damage_counters": "damage_counter_self",
	"prevent_all": "prevent_all",
	"prevent_damage": "prevent_damage",
	"prevent_effects": "prevent_effects",
	"recover_clara": "clara",
	"register_aura_damage_boost": "aura_damage_boost",
	"register_aura_damage_reduction": "aura_damage_reduction",
	"register_conditional_hp_boost": "conditional_hp_boost",
	"register_conditional_zero_retreat": "conditional_zero_retreat",
	"register_reactive_thorns": "reactive_thorns",
	"register_tool_exp_share": "tool_exp_share",
	"register_tool_modifier": "tool",
	"relocate_energy": "energy_relocate",
	"return_to_hand": "return_to_hand",
	"search_any_and_switch": "search_any_and_switch",
	"search_cards": "search",
	"search_item_and_tool": "arven",
	"set_attack_damage_formula": "attack_damage_formula",
	"set_attack_flags": "attack_flags",
	"shuffle_from_discard_to_deck": "shuffle_from_discard",
	"shuffle_then_draw_cards": "shuffle_draw",
	"switch_pokemon": "switch_self",
	"trekking_shoes": "trekking_shoes",
	"zinnia_resolve": "zinnia_resolve",
}

const AVAILABILITY_OP_ALIASES := {
	"apply_attack_lock_basic": "attack_lock_basic",
	"apply_dazzling_beam": "dazzling_beam",
	"apply_outgoing_damage_reduction": "apply_outgoing_damage_reduction",
	"apply_self_attack_lock": "self_attack_lock",
	"apply_status": "status",
	"attach_energy": "energy_attach",
	"attach_energy_from_discard": "attach_from_discard",
	"choose_damage_target": "any_pokemon_damage",
	"choose_heal_damage": "potion_heal",
	"conditional": "conditional",
	"conditional_damage": "conditional_damage_bonus",
	"conditional_damage_then_heal": "conditional_damage_heal",
	"conditional_search": "conditional_search_extra",
	"conditional_status": "conditional_status",
	"deal_bench_damage": "bench_damage",
	"deal_damage": "damage",
	"deal_damage_per_discard_psychic": "damage_per_discard_psychic",
	"deal_damage_per_energy": "damage_per_energy",
	"deal_damage_per_evolved": "damage_per_evolved",
	"deal_damage_per_hand_size": "damage_per_hand_size",
	"deal_damage_per_self_damage": "damage_per_self_damage",
	"deal_damage_per_self_energy": "damage_per_self_energy",
	"deal_damage_per_self_energy_type": "damage_per_self_energy_type",
	"deal_damage_plus_bench": "damage_plus_bench",
	"deal_damage_then_heal": "damage_and_self_heal",
	"deal_damage_with_self_penalty": "damage_self_penalty",
	"discard_cards": "discard",
	"discard_energy": "energy_discard",
	"discard_energy_then_damage": "discard_fighting_energy_damage",
	"discard_hand_then_damage": "discard_hand_conditional_bonus",
	"discard_then_draw_cards": "discard_then_draw",
	"draw_and_attach_energy": "draw_and_attach_energy",
	"draw_cards": "draw",
	"draw_until": "draw_until",
	"draw_until_more_than_opponent": "draw_until_more",
	"evolve_skip_stage": "evolve_skip_stage",
	"fail_attack": "attack_fail",
	"flip_coin": "coin_flip",
	"flip_coin_repeat_damage": "coin_flip_triple",
	"flip_coin_then_discard_energy": "coin_flip_energy_discard",
	"flip_coin_then_ko": "coin_flip_double_ko",
	"flip_until_tails": "coin_flip_until_tails",
	"hand_to_bottom_draw_until": "houb",
	"hand_to_bottom_then_draw": "hand_to_bottom_draw",
	"heal_all": "heal_all",
	"heal_damage": "heal",
	"judge": "judge",
	"look_top_attach_energy": "look_top_attach_energy",
	"look_top_deck": "look_top_deck",
	"mill_then_damage": "mill_and_damage_per_energy",
	"place_counters_then_self_ko": "place_counters_and_self_ko",
	"place_damage_counters": "any_pokemon_damage",
	"prevent_all": "prevent_all",
	"prevent_damage": "prevent_damage",
	"prevent_effects": "prevent_effects",
	"recover_clara": "clara",
	"register_aura_damage_boost": "aura_damage_boost",
	"register_aura_damage_reduction": "aura_damage_reduction",
	"register_conditional_hp_boost": "conditional_hp_boost",
	"register_conditional_zero_retreat": "conditional_zero_retreat",
	"register_reactive_thorns": "reactive_thorns",
	"register_tool_exp_share": "tool_exp_share",
	"register_tool_modifier": "tool",
	"relocate_energy": "energy_relocate",
	"return_to_hand": "return_to_hand",
	"search_any_and_switch": "search_any_and_switch",
	"search_cards": "search",
	"search_item_and_tool": "arven",
	"set_attack_damage_formula": "attack_damage_formula",
	"shuffle_from_discard_to_deck": "shuffle_from_discard",
	"shuffle_then_draw_cards": "shuffle_draw",
	"trekking_shoes": "trekking_shoes",
	"zinnia_resolve": "zinnia_resolve",
}

const DAMAGE_REPLACING_EFFECT_KINDS := [
	"damage_per_self_damage",
	"damage_per_self_energy",
	"damage_per_self_energy_type",
	"damage_plus_bench",
	"damage_per_hand_size",
	"damage_per_energy",
	"damage_per_evolved",
	"damage_self_penalty",
	"damage_per_discard_psychic",
	"conditional_damage_heal",
	"damage_and_self_heal",
	"discard_fighting_energy_damage",
	"discard_hand_conditional_bonus",
	"coin_flip_triple",
	"coin_flip_until_tails",
	"mill_and_damage_per_energy",
	"attack_damage_formula",
]


static func trainer_effects(card: Dictionary) -> Array:
	return runtime_effects(card, "trainer_effects", "compiled_trainer_effects")


static func ability_effects(ability: Dictionary) -> Array:
	return runtime_effects(ability, "effects", "compiled_effects")


static func attack_effects(attack: Dictionary) -> Array:
	return runtime_effects(attack, "effects", "compiled_effects")


static func strict_trainer_effects(card: Dictionary, source: String) -> Array:
	return strict_runtime_effects(card, "trainer_effects", "compiled_trainer_effects", source)


static func strict_ability_effects(ability: Dictionary) -> Array:
	return strict_runtime_effects(
		ability, "effects", "compiled_effects",
		"ability:%s" % str(ability.get("name", "")))


static func strict_attack_effects(attack: Dictionary) -> Array:
	return strict_runtime_effects(
		attack, "effects", "compiled_effects",
		"attack:%s" % str(attack.get("name", "")))


static func runtime_effects(owner: Dictionary, legacy_key: String, compiled_key: String) -> Array:
	var compiled: Array = owner.get(compiled_key, [])
	if not compiled.is_empty():
		return compiled
	return owner.get(legacy_key, [])


static func strict_runtime_effects(
	owner: Dictionary,
	legacy_key: String,
	compiled_key: String,
	source: String,
) -> Array:
	var compiled: Array = owner.get(compiled_key, [])
	if not compiled.is_empty():
		return compiled
	var raw: Array = owner.get(legacy_key, [])
	if raw.is_empty():
		return []
	return [missing_compiled_effect(source)]


static func missing_compiled_effect(source: String) -> Dictionary:
	return {
		"op": "__missing_compiled_effect__",
		"args": {"source": source},
		"branches": {},
	}


static func effect_list(effects: Variant) -> Array:
	var result: Array = []
	if effects is Array:
		result = effects
	elif effects is Dictionary:
		result.append(effects)
	return result


static func effect_kind(effect: Dictionary) -> String:
	if effect.has("op"):
		return str(OP_ALIASES.get(str(effect.get("op", "")), effect.get("op", "")))
	return str(effect.get("effect_type", ""))


static func effect_args(effect: Dictionary) -> Dictionary:
	if effect.has("op"):
		return Dictionary(effect.get("args", {})).duplicate(true)
	return Dictionary(effect.get("params", {})).duplicate(true)


static func effect_matches(effect: Dictionary, kind: String) -> bool:
	return effect_kind(effect) == kind


static func availability_effect_kind(effect: Dictionary) -> String:
	var raw_type := str(effect.get("effect_type", ""))
	if not raw_type.is_empty():
		return raw_type
	var op := str(effect.get("op", ""))
	if op == "set_attack_flags":
		return "attack_flags"
	if op == "switch_pokemon":
		if str(availability_effect_params(effect).get("target", "self")) == "opponent":
			return "switch_opponent"
		return "switch_self"
	return str(AVAILABILITY_OP_ALIASES.get(op, op))


static func availability_effect_params(effect: Dictionary) -> Dictionary:
	var params: Dictionary = {}
	var raw_params: Variant = effect.get("params", {})
	if raw_params is Dictionary:
		params = Dictionary(raw_params).duplicate(true)
	var args: Variant = effect.get("args", {})
	if args is Dictionary:
		for key in Dictionary(args):
			params[key] = Dictionary(args)[key]
	var branches: Variant = effect.get("branches", {})
	if branches is Dictionary:
		for key in Dictionary(branches):
			if not params.has(key):
				params[key] = Dictionary(branches)[key]
	return params


static func replaces_attack_base_damage(effect: Dictionary) -> bool:
	var kind := availability_effect_kind(effect)
	if kind in DAMAGE_REPLACING_EFFECT_KINDS:
		return true
	if str(effect.get("op", "")) != "deal_damage":
		return false
	var params := availability_effect_params(effect)
	return params.has("formula_ast") or params.get("formula", null) is Dictionary
