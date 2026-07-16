class_name VMPokemonStatHooks
extends RefCounted

const TOOL_HP_BOOST := 50


static func current_hp(pokemon: PokemonState, catalog: CardCatalog) -> int:
	if pokemon == null:
		return 0
	var max_hp := int(catalog.get_card(pokemon.card_id).get("hp", 0))
	var manager := VMModifierManager.new()
	_register_max_hp_hooks(manager, pokemon, catalog)
	for hook_value in manager.hooks_for(VMModifierManager.MAX_HP):
		var hook: Dictionary = hook_value
		max_hp = _apply_max_hp_hook(pokemon, catalog, max_hp, hook)
	return max(0, max_hp - pokemon.damage_counters * 10)


static func _register_max_hp_hooks(
	manager: VMModifierManager,
	pokemon: PokemonState,
	catalog: CardCatalog,
) -> void:
	if not pokemon.attached_tool_id.is_empty():
		for effect_value in VMRuntimeEffects.strict_trainer_effects(
			catalog.get_card(pokemon.attached_tool_id),
			"trainer:%s" % pokemon.attached_tool_id,
		):
			var effect: Dictionary = effect_value
			var params := VMRuntimeEffects.effect_args(effect)
			if (
				not VMRuntimeEffects.effect_matches(effect, "tool")
				or str(params.get("effect", "")) != "hp_boost_basic"
			):
				continue
			manager.register_hook(
				VMModifierManager.MAX_HP,
				pokemon.attached_tool_id,
				-1,
				0,
				{
					"kind": "hp_boost_basic",
					"amount": int(params.get("amount", TOOL_HP_BOOST)),
				},
			)
	for ability_value in catalog.get_card(pokemon.card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		for effect_value in VMRuntimeEffects.strict_ability_effects(ability):
			var effect: Dictionary = effect_value
			if not VMRuntimeEffects.effect_matches(effect, "conditional_hp_boost"):
				continue
			manager.register_hook(
				VMModifierManager.MAX_HP,
				"conditional_hp_boost",
				-1,
				0,
				{
					"kind": "conditional_hp_boost",
					"params": VMRuntimeEffects.effect_args(effect),
				},
			)
	for modifier_value in pokemon.modifiers:
		var modifier: Dictionary = modifier_value
		if str(modifier.get("modifier_kind", modifier.get("effect_type", ""))) != "conditional_hp_boost":
			continue
		manager.register_hook(
			VMModifierManager.MAX_HP,
			str(modifier.get("source", "conditional_hp_boost")),
			-1,
			0,
			{
				"kind": "conditional_hp_boost",
				"params": Dictionary(modifier.get("params", {})).duplicate(true),
			},
		)


static func _apply_max_hp_hook(
	pokemon: PokemonState,
	catalog: CardCatalog,
	max_hp: int,
	hook: Dictionary,
) -> int:
	var payload: Dictionary = hook.get("payload", {})
	match str(payload.get("kind", "")):
		"hp_boost_basic":
			if catalog.is_basic_pokemon(pokemon.card_id):
				return max_hp + int(payload.get("amount", TOOL_HP_BOOST))
		"conditional_hp_boost":
			var params: Dictionary = payload.get("params", {})
			if _has_energy_threshold(
				pokemon,
				catalog,
				str(params.get("energy_type", "")),
				int(params.get("threshold", 0)),
			):
				return max_hp + int(params.get("amount", 0))
	return max_hp


static func _has_energy_threshold(
	pokemon: PokemonState,
	catalog: CardCatalog,
	required_type: String,
	threshold: int,
) -> bool:
	var required := required_type.to_lower()
	if threshold <= 0:
		return true
	var matching := 0
	for provided in EnergyView.units_for_cards(pokemon.energy_card_ids, catalog):
		if str(provided).to_lower() in [required, "rainbow"]:
			matching += 1
	return matching >= threshold
