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
	for descriptor in manager.descriptors_for(VMModifierManager.MODIFY_DAMAGE):
		damage = _apply_descriptor(state, catalog, context, damage, descriptor)
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
		var defender_player_idx := int(context.get("target_player", 1 - actor))
		var defender_slot := str(context.get(
			"target_slot", _slot_for_pokemon(state.get_player(defender_player_idx), defender)))
		_register_card_effect_hooks(
			manager,
			catalog.get_card(defender.card_id).get("abilities", []),
			VMModifierManager.MODIFY_DAMAGE,
			"aura_damage_reduction",
			defender_player_idx,
			0,
			VMModifierManager.source_pokemon_ref(
				defender_player_idx, defender_slot, defender.card_id),
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
	context: Dictionary,
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
			VMModifierManager.source_pokemon_ref(
				actor, str(row.get("slot", "")), aura_source.card_id),
		)
		_register_pokemon_modifier_hooks(
			manager,
			aura_source.modifiers,
			VMModifierManager.MODIFY_DAMAGE,
			"aura_damage_boost",
			actor,
			0,
		)
	# Attack settlement may intentionally use a frozen attacker snapshot after
	# the live board has changed (for example, an attacker returned to hand).
	# Preserve the authoritative slot in the attack context instead of relying
	# on object identity against the live board.
	var source_slot := str(context.get("attacker_slot", ""))
	if source_slot.is_empty():
		source_slot = _slot_for_pokemon(state.get_player(actor), attacker)
	for energy_index in range(attacker.energy_card_ids.size()):
		var energy_id := str(attacker.energy_card_ids[energy_index])
		for effect_value in catalog.get_card(energy_id).get("energy_effects", []):
			var effect: Dictionary = effect_value
			if (
				str(effect.get("kind", "")) != "modifier"
				or str(effect.get("hook", "")) != VMModifierManager.MODIFY_DAMAGE
			):
				continue
			var effect_operation: Dictionary = effect.get("effect", {})
			if not effect_operation.has("delta") or source_slot.is_empty():
				continue
			manager.register_descriptor(VMModifierManager.descriptor(
				VMModifierManager.MODIFY_DAMAGE,
				"defender_adjust" if str(effect.get("scope", "")) == "attached_defender" else "attacker_adjust",
				int(effect.get("priority", 0)),
				actor,
				VMModifierManager.source_attachment_ref(
					actor, source_slot, "energy", energy_index, energy_id),
				str(effect.get("scope", "attached_attacker")),
				"until_leave_play",
				"stack",
				{},
				{"kind": "damage_delta", "amount": int(effect_operation["delta"])},
			))
	if not attacker.attached_tool_id.is_empty():
		_register_tool_effect_hooks(
			manager,
			catalog,
			attacker.attached_tool_id,
			VMModifierManager.MODIFY_DAMAGE,
			"attacker_tool",
			actor,
			0,
			VMModifierManager.source_pokemon_ref(
				actor, source_slot, attacker.card_id),
		)
	_register_pokemon_modifier_hooks(
		manager,
		attacker.modifiers,
		VMModifierManager.MODIFY_DAMAGE,
		"attacker_tool",
		actor,
		0,
		"tool",
		true,
	)


static func _register_defender_tool_hooks(
	manager: VMModifierManager,
	catalog: CardCatalog,
	context: Dictionary,
	actor: int,
	defender: PokemonState,
) -> void:
	if not defender.attached_tool_id.is_empty():
		var target_player_idx := int(context.get("target_player", 1 - actor))
		var target_slot := str(context.get("target_slot", "active"))
		_register_tool_effect_hooks(
			manager,
			catalog,
			defender.attached_tool_id,
			VMModifierManager.MODIFY_DAMAGE,
			"defender_tool",
			target_player_idx,
			0,
			VMModifierManager.source_pokemon_ref(
				target_player_idx, target_slot, defender.card_id),
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
	source_ref: Dictionary,
) -> void:
	for group_value in effect_groups:
		var group: Dictionary = group_value
		for effect_value in VMRuntimeEffects.strict_ability_effects(group):
			var effect: Dictionary = effect_value
			if not VMRuntimeEffects.effect_matches(effect, effect_kind):
				continue
			var args := VMRuntimeEffects.effect_args(effect)
			var descriptor := _ability_descriptor(
				effect_kind, owner_player, priority, source_ref, args)
			if not descriptor.is_empty():
				manager.register_descriptor(descriptor)


static func _register_pokemon_modifier_hooks(
	manager: VMModifierManager,
	modifiers: Array[Dictionary],
	hook: String,
	payload_kind: String,
	owner_player: int,
	priority: int,
	modifier_kind: String = "",
	_include_strict: bool = false,
) -> void:
	var expected_kind := modifier_kind if not modifier_kind.is_empty() else payload_kind
	for modifier_value in modifiers:
		var modifier: Dictionary = modifier_value
		if VMModifierDescriptorRegistry.shared().validation_error(modifier).is_empty():
			if (
				str(modifier.get("hook", "")) == hook
			):
				manager.register_descriptor(modifier)
			continue
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
	source_ref: Dictionary,
) -> void:
	for effect_value in VMRuntimeEffects.strict_trainer_effects(
		catalog.get_card(tool_id),
		"trainer:%s" % tool_id,
	):
		var effect: Dictionary = effect_value
		if not VMRuntimeEffects.effect_matches(effect, "tool"):
			continue
		var descriptor := _tool_descriptor(
			payload_kind,
			owner_player,
			priority,
			source_ref,
			VMRuntimeEffects.effect_args(effect),
		)
		if not descriptor.is_empty():
			manager.register_descriptor(descriptor)


static func _ability_descriptor(
	effect_kind: String,
	owner_player: int,
	priority: int,
	source_ref: Dictionary,
	args: Dictionary,
) -> Dictionary:
	var layer := ""
	var scope := "self"
	var condition: Dictionary = {}
	var operation: Dictionary = {}
	match effect_kind:
		"aura_damage_reduction":
			layer = "defender_adjust"
			condition = {
				"requires_attached_energy": bool(args.get("requires_attached_energy", false)),
			}
			operation = {
				"kind": "damage_delta", "amount": -abs(int(args.get("reduction", 20))),
			}
		"aura_damage_boost":
			layer = "attacker_adjust"
			scope = "allied_board"
			condition = {
				"attacker_subtype": str(args.get("attacker_subtype", "")),
				"defender_type": str(args.get("defender_type", "")),
			}
			operation = {"kind": "damage_delta", "amount": int(args.get("amount", 0))}
		_:
			return {}
	return VMModifierManager.descriptor(
		VMModifierManager.MODIFY_DAMAGE,
		layer,
		priority,
		owner_player,
		source_ref,
		scope,
		"until_leave_play",
		"replace_same_source",
		condition,
		operation,
	)


static func _tool_descriptor(
	payload_kind: String,
	owner_player: int,
	priority: int,
	source_ref: Dictionary,
	args: Dictionary,
) -> Dictionary:
	var layer := "attacker_adjust"
	var scope := "attached_attacker"
	var condition: Dictionary = {}
	var operation: Dictionary = {}
	var effect := str(args.get("effect", ""))
	if payload_kind == "attacker_tool":
		if effect == "damage_boost_10":
			operation = {"kind": "damage_delta", "amount": 10}
		elif effect == "damage_boost_when_behind":
			condition = {"behind_on_prizes": true}
			operation = {"kind": "damage_delta", "amount": 30}
	elif payload_kind == "defender_tool" and effect == "damage_reduction_stage1":
		layer = "defender_adjust"
		scope = "attached_defender"
		condition = {"target_stage": "stage1"}
		operation = {
			"kind": "damage_delta", "amount": -abs(int(args.get("amount", 30))),
		}
	if operation.is_empty():
		return {}
	return VMModifierManager.descriptor(
		VMModifierManager.MODIFY_DAMAGE,
		layer,
		priority,
		owner_player,
		source_ref,
		scope,
		"until_leave_play",
		"replace_same_source",
		condition,
		operation,
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


static func _apply_descriptor(
	state: GameState,
	catalog: CardCatalog,
	context: Dictionary,
	damage: int,
	descriptor: Dictionary,
) -> int:
	if not _descriptor_condition_matches(state, catalog, context, descriptor):
		return damage
	var operation: Dictionary = descriptor.get("operation", {})
	match str(operation.get("kind", "")):
		"damage_delta":
			return damage + int(operation.get("amount", 0))
		"prevent_damage":
			return 0
	return damage


static func _descriptor_condition_matches(
	state: GameState,
	catalog: CardCatalog,
	context: Dictionary,
	descriptor: Dictionary,
) -> bool:
	var condition: Dictionary = descriptor.get("condition", {})
	var attacker: PokemonState = context.get("attacker", null)
	var defender: PokemonState = context.get("defender", null)
	if attacker == null or defender == null:
		return false
	if bool(condition.get("requires_attached_energy", false)) and defender.energy_card_ids.is_empty():
		return false
	var attacker_subtype := str(condition.get("attacker_subtype", ""))
	if (
		not attacker_subtype.is_empty()
		and attacker_subtype not in catalog.get_card(attacker.card_id).get("subtypes", [])
	):
		return false
	var defender_type := str(condition.get("defender_type", ""))
	if (
		not defender_type.is_empty()
		and defender_type not in catalog.get_card(defender.card_id).get("energy_types", [])
	):
		return false
	if bool(condition.get("behind_on_prizes", false)):
		var actor := int(context.get("actor", 0))
		if state.get_player(actor).prizes.size() <= state.get_player(1 - actor).prizes.size():
			return false
	if str(condition.get("target_stage", "")) == "stage1" and not catalog.is_stage1(defender.card_id):
		return false
	return true


static func _slot_for_pokemon(player: PlayerState, pokemon: PokemonState) -> String:
	for row in player.get_all_pokemon():
		if row.get("pokemon") == pokemon:
			return str(row.get("slot", ""))
	return ""
