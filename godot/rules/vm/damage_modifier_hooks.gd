class_name VMDamageModifierHooks
extends RefCounted


static func apply_modify_damage(
	state: GameState,
	catalog: CardCatalog,
	context: Dictionary,
) -> int:
	var manager := VMModifierManager.new()
	_register_modify_damage_hooks(manager, state, catalog, context)
	var damage := int(context.get("damage", 0))
	for hook in manager.hooks_for(VMModifierManager.MODIFY_DAMAGE):
		damage = _apply_modify_damage_hook(state, catalog, context, damage, hook)
	return max(0, damage)


static func _register_modify_damage_hooks(
	manager: VMModifierManager,
	state: GameState,
	catalog: CardCatalog,
	context: Dictionary,
) -> void:
	var actor := int(context.get("actor", 0))
	var attacker: PokemonState = context.get("attacker", null)
	var defender: PokemonState = context.get("defender", null)
	if attacker == null or defender == null:
		return
	var modifier_phase := str(context.get("modifier_phase", "all"))
	var include_attacker := modifier_phase in ["all", "attacker"]
	var include_defender := modifier_phase in ["all", "defender"]
	var ignore_defender_damage_effects := bool(context.get(
		"ignore_defender_damage_effects", context.get("ignore_defender_effects", false)))
	if include_defender and not ignore_defender_damage_effects:
		_register_card_effect_hooks(
			manager,
			catalog.get_card(defender.card_id).get("abilities", []),
			VMModifierManager.MODIFY_DAMAGE,
			"aura_damage_reduction",
			1 - actor,
			0,
		)
		_register_pokemon_modifier_hooks(
			manager,
			defender.modifiers,
			VMModifierManager.MODIFY_DAMAGE,
			"aura_damage_reduction",
			1 - actor,
			0,
		)
	if include_attacker:
		_register_attacker_hooks(manager, state, catalog, context, actor, attacker)
	if include_defender and not ignore_defender_damage_effects:
		_register_defender_tool_hooks(manager, catalog, context, actor, defender)


static func _register_attacker_hooks(
	manager: VMModifierManager,
	state: GameState,
	catalog: CardCatalog,
	_context: Dictionary,
	actor: int,
	attacker: PokemonState,
) -> void:
	for row in state.get_player(actor).get_all_pokemon():
		var aura_source: PokemonState = row["pokemon"]
		if aura_source == null:
			continue
		_register_card_effect_hooks(
			manager,
			catalog.get_card(aura_source.card_id).get("abilities", []),
			VMModifierManager.MODIFY_DAMAGE,
			"aura_damage_boost",
			actor,
			0,
		)
		_register_pokemon_modifier_hooks(
			manager,
			aura_source.modifiers,
			VMModifierManager.MODIFY_DAMAGE,
			"aura_damage_boost",
			actor,
			0,
		)
	for energy_id in attacker.energy_card_ids:
		if energy_id == "svi-dtur":
			manager.register_hook(
				VMModifierManager.MODIFY_DAMAGE,
				energy_id,
				actor,
				0,
				{"kind": "energy_damage_reduction", "amount": 20},
			)
	if attacker.outgoing_damage_reduction_next_turn > 0:
		manager.register_hook(
			VMModifierManager.MODIFY_DAMAGE,
			"outgoing_damage_reduction_next_turn",
			actor,
			0,
			{
				"kind": "outgoing_damage_reduction",
				"amount": attacker.outgoing_damage_reduction_next_turn,
			},
		)
	if not attacker.attached_tool_id.is_empty():
		_register_tool_effect_hooks(
			manager,
			catalog,
			attacker.attached_tool_id,
			VMModifierManager.MODIFY_DAMAGE,
			"attacker_tool",
			actor,
			0,
		)
	_register_pokemon_modifier_hooks(
		manager,
		attacker.modifiers,
		VMModifierManager.MODIFY_DAMAGE,
		"attacker_tool",
		actor,
		0,
		"tool",
	)


static func _register_defender_tool_hooks(
	manager: VMModifierManager,
	catalog: CardCatalog,
	_context: Dictionary,
	actor: int,
	defender: PokemonState,
) -> void:
	if not defender.attached_tool_id.is_empty():
		_register_tool_effect_hooks(
			manager,
			catalog,
			defender.attached_tool_id,
			VMModifierManager.MODIFY_DAMAGE,
			"defender_tool",
			1 - actor,
			0,
		)
	_register_pokemon_modifier_hooks(
		manager,
		defender.modifiers,
		VMModifierManager.MODIFY_DAMAGE,
		"defender_tool",
		1 - actor,
		0,
		"tool",
	)


static func _register_card_effect_hooks(
	manager: VMModifierManager,
	effect_groups: Array,
	hook: String,
	effect_kind: String,
	owner_player: int,
	priority: int,
) -> void:
	for group_value in effect_groups:
		var group: Dictionary = group_value
		for effect_value in VMRuntimeEffects.strict_ability_effects(group):
			var effect: Dictionary = effect_value
			if not VMRuntimeEffects.effect_matches(effect, effect_kind):
				continue
			manager.register_hook(
				hook,
				effect_kind,
				owner_player,
				priority,
				{
					"kind": effect_kind,
					"params": VMRuntimeEffects.effect_args(effect),
				},
			)


static func _register_pokemon_modifier_hooks(
	manager: VMModifierManager,
	modifiers: Array[Dictionary],
	hook: String,
	payload_kind: String,
	owner_player: int,
	priority: int,
	modifier_kind: String = "",
) -> void:
	var expected_kind := modifier_kind if not modifier_kind.is_empty() else payload_kind
	for modifier_value in modifiers:
		var modifier: Dictionary = modifier_value
		if str(modifier.get("modifier_kind", modifier.get("effect_type", ""))) != expected_kind:
			continue
		manager.register_hook(
			hook,
			str(modifier.get("source", payload_kind)),
			owner_player,
			priority,
			{
				"kind": payload_kind,
				"params": Dictionary(modifier.get("params", {})).duplicate(true),
			},
		)


static func _register_tool_effect_hooks(
	manager: VMModifierManager,
	catalog: CardCatalog,
	tool_id: String,
	hook: String,
	payload_kind: String,
	owner_player: int,
	priority: int,
) -> void:
	for effect_value in VMRuntimeEffects.strict_trainer_effects(
		catalog.get_card(tool_id),
		"trainer:%s" % tool_id,
	):
		var effect: Dictionary = effect_value
		if not VMRuntimeEffects.effect_matches(effect, "tool"):
			continue
		manager.register_hook(
			hook,
			tool_id,
			owner_player,
			priority,
			{
				"kind": payload_kind,
				"params": VMRuntimeEffects.effect_args(effect),
			},
		)


static func _apply_modify_damage_hook(
	state: GameState,
	catalog: CardCatalog,
	context: Dictionary,
	damage: int,
	hook: Dictionary,
) -> int:
	var payload: Dictionary = hook.get("payload", {})
	var kind := str(payload.get("kind", ""))
	var params: Dictionary = payload.get("params", {})
	var actor := int(context.get("actor", 0))
	var attacker: PokemonState = context.get("attacker", null)
	var defender: PokemonState = context.get("defender", null)
	if attacker == null or defender == null:
		return damage
	match kind:
		"aura_damage_reduction":
			if bool(params.get("requires_attached_energy", false)) and defender.energy_card_ids.is_empty():
				return damage
			return damage - int(params.get("reduction", 20))
		"aura_damage_boost":
			var attacker_subtype := str(params.get("attacker_subtype", ""))
			var defender_type := str(params.get("defender_type", ""))
			if (
				not attacker_subtype.is_empty()
				and attacker_subtype not in catalog.get_card(attacker.card_id).get("subtypes", [])
			):
				return damage
			if (
				not defender_type.is_empty()
				and defender_type not in catalog.get_card(defender.card_id).get("energy_types", [])
			):
				return damage
			return damage + int(params.get("amount", 0))
		"energy_damage_reduction":
			return damage - int(payload.get("amount", 0))
		"outgoing_damage_reduction":
			return damage - int(payload.get("amount", 0))
		"attacker_tool":
			var attacker_tool_effect := str(params.get("effect", ""))
			if attacker_tool_effect == "damage_boost_10":
				return damage + 10
			if (
				attacker_tool_effect == "damage_boost_when_behind"
				and state.get_player(actor).prizes.size() > state.get_player(1 - actor).prizes.size()
			):
				return damage + 30
			return damage
		"defender_tool":
			if (
				str(params.get("effect", "")) == "damage_reduction_stage1"
				and catalog.is_stage1(defender.card_id)
			):
				return damage - int(params.get("amount", 30))
			return damage
	return damage
