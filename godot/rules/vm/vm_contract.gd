class_name VMContract
extends RefCounted

const IR_VERSION := 1
const COMMAND_KEYS := ["op", "args", "branches"]
const SUPPORTED_EFFECT_TYPES: Array[String] = [
	"ability_discard_revive",
	"any_pokemon_damage",
	"arven",
	"apply_outgoing_damage_reduction",
	"attach_from_discard",
	"attack_fail",
	"attack_damage_formula",
	"attack_lock_basic",
	"aura_damage_reduction",
	"aura_damage_boost",
	"bench_damage",
	"clara",
	"coin_flip",
	"coin_flip_double_ko",
	"coin_flip_energy_discard",
	"coin_flip_triple",
	"coin_flip_until_tails",
	"conditional",
	"conditional_damage_bonus",
	"conditional_damage_heal",
	"conditional_hp_boost",
	"conditional_search_extra",
	"conditional_status",
	"conditional_zero_retreat",
	"damage",
	"damage_and_self_heal",
	"damage_counter_self",
	"damage_per_discard_psychic",
	"damage_per_energy",
	"damage_per_evolved",
	"damage_per_hand_size",
	"damage_per_self_damage",
	"damage_per_self_energy",
	"damage_per_self_energy_type",
	"damage_plus_bench",
	"damage_self_penalty",
	"dazzling_beam",
	"discard",
	"discard_draw",
	"discard_fighting_energy_damage",
	"discard_hand_conditional_bonus",
	"discard_then_draw",
	"draw",
	"draw_and_attach_energy",
	"draw_until",
	"draw_until_more",
	"energy_attach",
	"energy_discard",
	"energy_relocate",
	"evolve_skip_stage",
	"hand_to_bottom_draw",
	"heal",
	"heal_all",
	"houb",
	"judge",
	"look_top_deck",
	"look_top_attach_energy",
	"mill_and_damage_per_energy",
	"piercing_marker",
	"place_counters_and_self_ko",
	"potion_heal",
	"prevent_all",
	"prevent_damage",
	"prevent_effects",
	"reactive_thorns",
	"return_to_hand",
	"search",
	"search_any_and_switch",
	"self_attack_lock",
	"shuffle_draw",
	"shuffle_from_discard",
	"status",
	"switch_opponent",
	"switch_self",
	"tool",
	"tool_exp_share",
	"trekking_shoes",
	"zinnia_resolve",
]
const NATIVE_COMMAND_OPS: Array[String] = [
	"apply_attack_lock_basic",
	"apply_dazzling_beam",
	"apply_outgoing_damage_reduction",
	"apply_self_attack_lock",
	"apply_status",
	"attach_energy",
	"attach_energy_from_discard",
	"choose_damage_target",
	"conditional",
	"choose_heal_damage",
	"conditional_search",
	"conditional_status",
	"deal_damage",
	"deal_damage_per_discard_psychic",
	"deal_damage_per_energy",
	"deal_damage_per_evolved",
	"deal_damage_per_hand_size",
	"deal_damage_per_self_damage",
	"deal_damage_per_self_energy",
	"deal_damage_per_self_energy_type",
	"deal_damage_plus_bench",
	"deal_damage_with_self_penalty",
	"deal_damage_then_heal",
	"deal_bench_damage",
	"conditional_damage",
	"conditional_damage_then_heal",
	"discard_cards",
	"discard_then_draw_cards",
	"discard_hand_then_damage",
	"discard_energy_then_damage",
	"discard_energy",
	"draw_cards",
	"draw_and_attach_energy",
	"draw_until",
	"draw_until_more_than_opponent",
	"evolve_skip_stage",
	"shuffle_then_draw_cards",
	"shuffle_from_discard_to_deck",
	"judge",
	"fail_attack",
	"hand_to_bottom_draw_until",
	"look_top_deck",
	"look_top_attach_energy",
	"flip_coin",
	"flip_coin_repeat_damage",
	"flip_coin_then_discard_energy",
	"flip_coin_then_ko",
	"flip_until_tails",
	"heal_all",
	"heal_damage",
	"hand_to_bottom_then_draw",
	"mill_then_damage",
	"place_damage_counters",
	"place_counters_then_self_ko",
	"prevent_all",
	"prevent_damage",
	"prevent_effects",
	"recover_clara",
	"register_aura_damage_boost",
	"register_aura_damage_reduction",
	"register_conditional_hp_boost",
	"register_conditional_zero_retreat",
	"register_reactive_thorns",
	"register_tool_modifier",
	"register_tool_exp_share",
	"relocate_energy",
	"return_to_hand",
	"set_attack_flags",
	"set_attack_damage_formula",
	"search_cards",
	"search_any_and_switch",
	"search_item_and_tool",
	"switch_pokemon",
	"trekking_shoes",
	"trigger_draw_cards",
	"trigger_move_basic_energy",
	"trigger_place_damage_counters",
	"trigger_switch_with_active",
	"discard_then_revive",
	"zinnia_resolve",
]
const BRANCH_KEYS := {
	"cost": true,
	"on_heads": true,
	"on_tails": true,
	"on_pay": true,
	"on_success": true,
	"on_fail": true,
	"on_failure": true,
}


static func supports_effect_type(effect_type: String) -> bool:
	return effect_type in SUPPORTED_EFFECT_TYPES


static func native_command_ops() -> Array[String]:
	return NATIVE_COMMAND_OPS.duplicate()


static func validate_command_spec(
	spec: Dictionary,
	supported_ops: Dictionary = {},
	path: String = "$"
) -> Array[String]:
	var errors: Array[String] = []
	var op := str(spec.get("op", ""))
	if op.is_empty():
		errors.append("%s.op must be a non-empty string" % path)
	elif not supported_ops.is_empty() and not supported_ops.has(op):
		errors.append("%s.op is unsupported: %s" % [path, op])

	var args: Variant = spec.get("args", {})
	if not args is Dictionary:
		errors.append("%s.args must be a dictionary" % path)
	elif Dictionary(args).has("effect_type"):
		errors.append("%s.args must not contain legacy effect_type" % path)

	var branches: Variant = spec.get("branches", {})
	if not branches is Dictionary:
		errors.append("%s.branches must be a dictionary" % path)
		return errors

	for branch_name in Dictionary(branches):
		var branch_key := str(branch_name)
		if not BRANCH_KEYS.has(branch_key):
			errors.append("%s.branches.%s is not a known branch key" % [path, branch_key])
		var branch_items: Variant = Dictionary(branches)[branch_name]
		if not branch_items is Array:
			errors.append("%s.branches.%s must be an array" % [path, branch_key])
			continue
		for index in range(Array(branch_items).size()):
			var item: Variant = Array(branch_items)[index]
			if not item is Dictionary:
				errors.append("%s.branches.%s[%d] must be a dictionary" % [
					path, branch_key, index])
				continue
			errors.append_array(validate_command_spec(
				Dictionary(item),
				supported_ops,
				"%s.branches.%s[%d]" % [path, branch_key, index],
			))
	return errors
