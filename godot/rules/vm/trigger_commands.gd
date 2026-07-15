class_name VMTriggerCommands
extends RefCounted

const TRIGGER_COMMAND_OPS := [
	"trigger_draw_cards",
	"trigger_place_damage_counters",
	"trigger_move_basic_energy",
	"trigger_switch_with_active",
]

var catalog: CardCatalog


func _init(p_catalog: CardCatalog) -> void:
	catalog = p_catalog


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"trigger_draw_cards": Callable(self, "cmd_trigger_draw_cards"),
		"trigger_place_damage_counters": Callable(self, "cmd_trigger_place_damage_counters"),
		"trigger_move_basic_energy": Callable(self, "cmd_trigger_move_basic_energy"),
		"trigger_switch_with_active": Callable(self, "cmd_trigger_switch_with_active"),
	}
	for op in registrations:
		interpreter.register_command_handler(str(op), registrations[op])


func resolve_commands(
	state: GameState,
	actor: int,
	commands: Array[Dictionary],
	events: Array[Dictionary],
	active_stack: ResolutionStack = null,
) -> Dictionary:
	var normalized := command_specs_from_payloads(commands)
	if not bool(normalized.get("success", false)):
		return normalized
	var specs: Array[Dictionary] = []
	for spec_value in normalized.get("commands", []):
		var spec: Dictionary = spec_value
		specs.append(spec.duplicate(true))
	if specs.is_empty():
		return VMResult.ok()
	var stack := active_stack if active_stack != null else ResolutionStack.new()
	var frame_floor := stack.frames.size()
	stack.push_effects(specs, actor, "active")
	while stack.frames.size() > frame_floor:
		if stack.pending_request != null:
			return VMResult.fail(
				"触发命令不能暂停等待选择。",
				"trigger_choice_unsupported",
			)
		var frame := stack.pop_frame()
		if str(frame.get("kind", "")) != "effect":
			return VMResult.fail(
				"触发结算栈帧不是效果命令。",
				"invalid_trigger_frame",
			)
		var spec: Dictionary = frame.get("effect", {})
		var outcome := execute_trigger_spec(state, spec, events)
		if not bool(outcome.get("success", true)):
			return outcome
	return VMResult.ok()


func command_specs_from_payloads(commands: Array[Dictionary]) -> Dictionary:
	var specs: Array[Dictionary] = []
	var claimed_groups := {}
	for command in commands:
		var exclusive_group := str(command.get("exclusive_group", ""))
		if not exclusive_group.is_empty() and claimed_groups.has(exclusive_group):
			continue
		if command.has("command_specs"):
			var raw_specs = command.get("command_specs")
			if raw_specs == null:
				continue
			if not raw_specs is Array:
				return VMResult.fail(
					"触发 command_specs 必须是可序列化 VM 命令数组。",
					"invalid_trigger_command_specs",
				)
			var appended := false
			for payload_value in raw_specs:
				if payload_value == null:
					continue
				if not payload_value is Dictionary:
					return VMResult.fail(
						"触发 payload 必须是可序列化 VM 命令。",
						"invalid_trigger_payload",
					)
				var payload: Dictionary = payload_value
				var payload_spec := command_spec_from_payload(payload)
				if payload_spec.is_empty():
					return VMResult.fail(
						"触发 payload 必须是可序列化 VM 命令。",
						"invalid_trigger_payload",
					)
				var payload_spec_check := _require_trigger_command_spec(payload_spec)
				if not bool(payload_spec_check.get("success", false)):
					return payload_spec_check
				specs.append(payload_spec)
				appended = true
			if not exclusive_group.is_empty() and appended:
				claimed_groups[exclusive_group] = true
			continue
		var spec := command_spec_from_payload(command)
		if spec.is_empty():
			return VMResult.fail(
				"触发 payload 必须是可序列化 VM 命令。",
				"invalid_trigger_payload",
			)
		var spec_check := _require_trigger_command_spec(spec)
		if not bool(spec_check.get("success", false)):
			return spec_check
		specs.append(spec)
		if not exclusive_group.is_empty():
			claimed_groups[exclusive_group] = true
	var result := VMResult.ok()
	result["commands"] = specs
	return result


func command_spec_from_payload(command: Dictionary) -> Dictionary:
	if command.get("args") is Dictionary and command.get("branches") is Dictionary:
		return command.duplicate(true)
	match str(command.get("op", "")):
		"draw_cards":
			return {
				"op": "trigger_draw_cards",
				"args": {
					"player": int(command.get("player", 0)),
					"amount": int(command.get("amount", 0)),
					"source": str(command.get("source", "")),
				},
				"branches": {},
			}
		"place_damage_counters":
			return {
				"op": "trigger_place_damage_counters",
				"args": {
					"player": int(command.get("player", 0)),
					"slot": str(command.get("slot", "active")),
					"count": int(command.get("count", 0)),
					"source": str(command.get("source", "")),
				},
				"branches": {},
			}
		"move_basic_energy":
			return {
				"op": "trigger_move_basic_energy",
				"args": {
					"from_player": int(command.get("from_player", 0)),
					"from_slot": str(command.get("from_slot", "active")),
					"to_player": int(command.get("to_player", int(command.get("from_player", 0)))),
					"to_slot": str(command.get("to_slot", "active")),
					"source": str(command.get("source", "")),
				},
				"branches": {},
			}
		"switch_with_active":
			return {
				"op": "trigger_switch_with_active",
				"args": {
					"player": int(command.get("player", 0)),
					"bench_idx": int(command.get("bench_idx", -1)),
					"slot": str(command.get("slot", "")),
					"source": str(command.get("source", "")),
				},
				"branches": {},
			}
	return {}


func _require_trigger_command_spec(spec: Dictionary) -> Dictionary:
	var op := str(spec.get("op", ""))
	if not (op in TRIGGER_COMMAND_OPS):
		return VMResult.fail(
			"触发 VM 命令必须使用已注册的 trigger_* op: %s" % op,
			"invalid_trigger_op",
		)
	return VMResult.ok()


func execute_trigger_spec(
	state: GameState,
	spec: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var args: Dictionary = spec.get("args", {})
	match str(spec.get("op", "")):
		"trigger_draw_cards":
			_execute_draw_cards(state, args, events)
		"trigger_place_damage_counters":
			_execute_place_damage_counters(state, args, events)
		"trigger_move_basic_energy":
			_execute_move_basic_energy(state, args, events)
		"trigger_switch_with_active":
			_execute_switch_with_active(state, args, events)
		_:
			return VMResult.fail(
				"未知触发命令: %s" % str(spec.get("op", "")),
				"unknown_trigger_command")
	return VMResult.ok()


func collect_after_damage_commands(
	state: GameState,
	context: Dictionary,
	commands: Array[Dictionary],
) -> void:
	if int(context.get("damage", 0)) <= 0 or bool(context.get("ignore_defender_effects", false)):
		return
	var manager := VMModifierManager.new()
	_register_after_damage_hooks(manager, context)
	for hook_value in manager.hooks_for(VMModifierManager.AFTER_DAMAGE):
		var hook: Dictionary = hook_value
		_append_after_damage_command(state, context, hook, commands)


func _register_after_damage_hooks(
	manager: VMModifierManager,
	context: Dictionary,
) -> void:
	var actor := int(context.get("actor", 0))
	var defender: PokemonState = context.get("defender", null)
	if defender == null:
		return
	if "svi-mirc" in defender.energy_card_ids:
		manager.register_hook(
			VMModifierManager.AFTER_DAMAGE,
			"svi-mirc",
			1 - actor,
			0,
			{"kind": "miracle_energy_draw"},
		)
	_register_after_damage_card_hooks(
		manager,
		catalog.get_card(defender.card_id).get("abilities", []),
		"reactive_thorns",
		1 - actor,
		0,
	)
	_register_after_damage_modifier_hooks(
		manager,
		defender.modifiers,
		"reactive_thorns",
		1 - actor,
		0,
	)


func _register_after_damage_card_hooks(
	manager: VMModifierManager,
	effect_groups: Array,
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
				VMModifierManager.AFTER_DAMAGE,
				effect_kind,
				owner_player,
				priority,
				{
					"kind": effect_kind,
					"params": VMRuntimeEffects.effect_args(effect),
				},
			)


func _register_after_damage_modifier_hooks(
	manager: VMModifierManager,
	modifiers: Array[Dictionary],
	payload_kind: String,
	owner_player: int,
	priority: int,
) -> void:
	for modifier_value in modifiers:
		var modifier: Dictionary = modifier_value
		if str(modifier.get("modifier_kind", modifier.get("effect_type", ""))) != payload_kind:
			continue
		manager.register_hook(
			VMModifierManager.AFTER_DAMAGE,
			str(modifier.get("source", payload_kind)),
			owner_player,
			priority,
			{
				"kind": payload_kind,
				"params": Dictionary(modifier.get("params", {})).duplicate(true),
			},
		)


func _append_after_damage_command(
	state: GameState,
	context: Dictionary,
	hook: Dictionary,
	commands: Array[Dictionary],
) -> void:
	var payload: Dictionary = hook.get("payload", {})
	var kind := str(payload.get("kind", ""))
	var actor := int(context.get("actor", 0))
	match kind:
		"miracle_energy_draw":
			commands.append({
				"op": "trigger_draw_cards",
				"args": {
					"player": 1 - actor,
					"amount": 1,
					"source": str(hook.get("source", "svi-mirc")),
				},
				"branches": {},
			})
		"reactive_thorns":
			var params: Dictionary = payload.get("params", {})
			var names: Array = params.get("filter_names", [])
			var count := 0
			for row in state.get_player(1 - actor).get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				if pokemon and catalog.card_name(pokemon.card_id) in names:
					count += 1
			var counters := count * int(params.get("per_pokemon", 3))
			var attacker := state.get_player(actor).active
			if attacker and counters > 0:
				commands.append({
					"op": "trigger_place_damage_counters",
					"args": {
						"player": actor,
						"slot": "active",
						"count": counters,
						"source": "reactive_thorns",
					},
					"branches": {},
				})


func collect_pokemon_ko_commands(
	state: GameState,
	defeated_idx: int,
	source_slot: String,
	knocked_out: PokemonState,
	from_attack: bool,
	attack_actor: int,
	commands: Array[Dictionary],
) -> void:
	var manager := VMModifierManager.new()
	_register_exp_share_ko_hooks(
		manager,
		state,
		defeated_idx,
		source_slot,
		knocked_out,
		from_attack,
		attack_actor,
	)
	for hook_value in manager.hooks_for(VMModifierManager.POKEMON_KO):
		var hook: Dictionary = hook_value
		var payload: Dictionary = hook.get("payload", {})
		match str(payload.get("kind", "")):
			"tool_exp_share":
				commands.append(_move_basic_energy_trigger_spec(
					int(payload.get("from_player", defeated_idx)),
					str(payload.get("from_slot", source_slot)),
					int(payload.get("to_player", defeated_idx)),
					str(payload.get("to_slot", "active")),
					str(payload.get("source", "exp_share")),
				))


func _register_exp_share_ko_hooks(
	manager: VMModifierManager,
	state: GameState,
	defeated_idx: int,
	source_slot: String,
	knocked_out: PokemonState,
	from_attack: bool,
	attack_actor: int,
) -> void:
	if not from_attack or defeated_idx == attack_actor:
		return
	if not pokemon_has_basic_energy(knocked_out):
		return
	var player := state.get_player(defeated_idx)
	for bench_index in range(player.bench.size()):
		var bench_pokemon: PokemonState = player.bench[bench_index]
		if not _bench_pokemon_has_exp_share(bench_pokemon):
			continue
		manager.register_hook(
			VMModifierManager.POKEMON_KO,
			"exp_share",
			defeated_idx,
			0,
			{
				"kind": "tool_exp_share",
				"from_player": defeated_idx,
				"from_slot": source_slot,
				"to_player": defeated_idx,
				"to_slot": "bench_%d" % bench_index,
				"source": "exp_share",
			},
		)
		return


func _bench_pokemon_has_exp_share(bench_pokemon: PokemonState) -> bool:
	return (
		bench_pokemon is PokemonState
		and (
			(
				not bench_pokemon.attached_tool_id.is_empty()
				and tool_has_effect(bench_pokemon.attached_tool_id, "tool_exp_share")
			)
			or pokemon_has_modifier(bench_pokemon, "tool_exp_share")
		)
	)


func pokemon_has_basic_energy(pokemon: PokemonState) -> bool:
	for energy_id in pokemon.energy_card_ids:
		if catalog.is_basic_energy(str(energy_id)):
			return true
	return false


func _move_basic_energy_trigger_spec(
	from_player: int,
	from_slot: String,
	to_player: int,
	to_slot: String,
	source: String,
) -> Dictionary:
	return {
		"op": "trigger_move_basic_energy",
		"args": {
			"from_player": from_player,
			"from_slot": from_slot,
			"to_player": to_player,
			"to_slot": to_slot,
			"source": source,
		},
		"branches": {},
	}


func collect_on_attach_commands(
	card_id: String,
	player_idx: int,
	target_slot: String,
	source_zone: String,
	commands: Array[Dictionary],
) -> void:
	var manager := VMModifierManager.new()
	_register_energy_on_attach_hooks(manager, card_id, player_idx, target_slot, source_zone)
	for hook_value in manager.hooks_for(VMModifierManager.ON_ATTACH):
		var hook: Dictionary = hook_value
		var payload: Dictionary = hook.get("payload", {})
		match str(payload.get("kind", "")):
			"switch_with_active":
				commands.append(_switch_with_active_trigger_spec(
					int(payload.get("player", player_idx)),
					int(payload.get("bench_idx", -1)),
					str(payload.get("source", card_id)),
					str(payload.get("slot", target_slot)),
				))


func _register_energy_on_attach_hooks(
	manager: VMModifierManager,
	card_id: String,
	player_idx: int,
	target_slot: String,
	source_zone: String,
) -> void:
	for effect_value in catalog.get_card(card_id).get("energy_effects", []):
		var effect: Dictionary = effect_value
		if str(effect.get("kind", "")) != "trigger" or str(effect.get("hook", "")) != VMModifierManager.ON_ATTACH:
			continue
		var condition: Dictionary = effect.get("condition", {})
		var condition_zone := str(condition.get("from_zone", ""))
		if not condition_zone.is_empty() and condition_zone != source_zone:
			continue
		var condition_target := str(condition.get("target", ""))
		if condition_target == "bench" and not target_slot.begins_with("bench_"):
			continue
		var effect_spec: Dictionary = effect.get("effect", {})
		if str(effect_spec.get("op", "")) == "switch_with_active":
			manager.register_hook(
				VMModifierManager.ON_ATTACH,
				card_id,
				player_idx,
				int(effect.get("priority", 0)),
				{
					"kind": "switch_with_active",
					"player": player_idx,
					"bench_idx": target_slot.trim_prefix("bench_").to_int(),
					"source": card_id,
					"slot": target_slot,
				},
			)


func _switch_with_active_trigger_spec(
	player_idx: int,
	bench_idx: int,
	source: String,
	slot: String,
) -> Dictionary:
	return {
		"op": "trigger_switch_with_active",
		"args": {
			"player": player_idx,
			"bench_idx": bench_idx,
			"source": source,
			"slot": slot,
		},
		"branches": {},
	}


func cmd_trigger_draw_cards(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	_player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	_execute_draw_cards(state, args, events)
	return VMResult.ok()


func cmd_trigger_place_damage_counters(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	_player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	_execute_place_damage_counters(state, args, events)
	return VMResult.ok()


func cmd_trigger_move_basic_energy(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	_player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	_execute_move_basic_energy(state, args, events)
	return VMResult.ok()


func cmd_trigger_switch_with_active(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	_player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	_execute_switch_with_active(state, args, events)
	return VMResult.ok()


func _execute_draw_cards(
	state: GameState,
	args: Dictionary,
	events: Array[Dictionary],
) -> void:
	var player_idx := int(args.get("player", 0))
	var amount := int(args.get("amount", 0))
	var drawn := state.get_player(player_idx).draw_cards(amount)
	if not drawn.is_empty():
		events.append({"event_type": "cards_drawn", "data": {
			"player": player_idx,
			"cards": drawn,
			"source": str(args.get("source", "")),
		}})


func _execute_place_damage_counters(
	state: GameState,
	args: Dictionary,
	events: Array[Dictionary],
) -> void:
	var target_player := int(args.get("player", 0))
	var target_slot := str(args.get("slot", "active"))
	var target := state.get_player(target_player).get_pokemon(target_slot)
	var counters := int(args.get("count", 0))
	if target and counters > 0:
		target.damage_counters += counters
		events.append({
			"event_type": "damage_counters_placed",
			"actor": int(args.get("source_player", target_player)),
			"target": {"player": target_player, "slot": target_slot},
			"amount": counters * 10,
			"data": {
				"player": target_player,
				"slot": target_slot,
				"count": counters,
				"counter_count": counters,
				"source": str(args.get("source", "")),
			},
		})


func _execute_move_basic_energy(
	state: GameState,
	args: Dictionary,
	events: Array[Dictionary],
) -> void:
	var from_player := int(args.get("from_player", 0))
	var from_slot := str(args.get("from_slot", "active"))
	var to_player := int(args.get("to_player", from_player))
	var to_slot := str(args.get("to_slot", "active"))
	var source := state.get_player(from_player).get_pokemon(from_slot)
	var target := state.get_player(to_player).get_pokemon(to_slot)
	if source == null or target == null:
		return
	var basic_energy_index := -1
	for index in range(source.energy_card_ids.size()):
		if catalog.is_basic_energy(source.energy_card_ids[index]):
			basic_energy_index = index
			break
	if basic_energy_index < 0:
		return
	var energy_id: String = source.energy_card_ids.pop_at(basic_energy_index)
	var target_index := target.energy_card_ids.size()
	target.energy_card_ids.append(energy_id)
	events.append({
		"event_type": "energy_attached",
		"actor": to_player,
		"card_id": energy_id,
		"source": {
			"player": from_player,
			"slot": from_slot,
			"attachment_type": "energy",
			"index": basic_energy_index,
		},
		"target": {
			"player": to_player,
			"slot": to_slot,
			"attachment_type": "energy",
			"index": target_index,
		},
		"data": {
			"player": to_player,
			"slot": to_slot,
			"card_id": energy_id,
			"presentation_phase": (
				"knockout" if str(args.get("source", "")) == "exp_share" else ""
			),
			"source": str(args.get("source", "")),
			"source_player": from_player,
			"source_slot": from_slot,
			"source_index": basic_energy_index,
			"target_player": to_player,
			"target_slot": to_slot,
			"target_index": target_index,
		},
	})


func _execute_switch_with_active(
	state: GameState,
	args: Dictionary,
	events: Array[Dictionary],
) -> void:
	var player_idx := int(args.get("player", 0))
	var bench_idx := int(args.get("bench_idx", -1))
	if state.get_player(player_idx).switch_active_to_bench(bench_idx):
		events.append({"event_type": "switched", "data": {
			"player": player_idx,
			"slot": str(args.get("slot", "bench_%d" % bench_idx)),
			"source": str(args.get("source", "")),
		}})


func tool_has_effect(tool_id: String, effect_type: String) -> bool:
	for effect_value in VMRuntimeEffects.strict_trainer_effects(
		catalog.get_card(tool_id),
		"trainer:%s" % tool_id,
	):
		if VMRuntimeEffects.effect_matches(effect_value, effect_type):
			return true
	return false


func pokemon_has_modifier(pokemon: PokemonState, effect_type: String) -> bool:
	for modifier in pokemon.modifiers:
		if str(modifier.get("modifier_kind", modifier.get("effect_type", ""))) == effect_type:
			return true
	return false
