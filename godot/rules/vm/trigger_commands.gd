class_name VMTriggerCommands
extends RefCounted

const TRIGGER_COMMAND_OPS := [
	"trigger_draw_cards",
	"trigger_place_damage_counters",
	"trigger_move_basic_energy",
	"trigger_switch_with_active",
]

var catalog: CardCatalog
var vm_interpreter: VMInterpreter


func _init(p_catalog: CardCatalog) -> void:
	catalog = p_catalog


func register(interpreter: VMInterpreter) -> void:
	vm_interpreter = interpreter
	var registrations := {
		"trigger_draw_cards": Callable(self, "cmd_trigger_draw_cards"),
		"trigger_place_damage_counters": Callable(self, "cmd_trigger_place_damage_counters"),
		"trigger_move_basic_energy": Callable(self, "cmd_trigger_move_basic_energy"),
		"trigger_switch_with_active": Callable(self, "cmd_trigger_switch_with_active"),
	}
	for op in registrations:
		interpreter.register_command_handler(str(op), registrations[op])
	interpreter.register_continuation(
		"trigger_move_basic_energy",
		Callable(self, "continue_trigger_move_basic_energy"),
	)


func queue_candidates(
	stack: ResolutionStack,
	candidates: Array[Dictionary],
	hook: String,
	active_player: int,
	order_policy: String = "apnap",
	choice_domain: String = "effect",
) -> Dictionary:
	if vm_interpreter == null:
		return VMResult.fail("触发调度器未绑定VM解释器。", "vm_registry_not_ready")
	return vm_interpreter.trigger_scheduler.queue_batch(
		stack, candidates, hook, active_player, order_policy, choice_domain)


func make_candidate(
	trigger_id: String,
	hook: String,
	controller: int,
	priority: int,
	source_ref: Dictionary,
	optional: bool,
	liveness: Dictionary,
	guards: Array,
	commands: Array,
) -> Dictionary:
	var command_specs: Array[Dictionary] = []
	for command_value in commands:
		command_specs.append(Dictionary(command_value).duplicate(true))
	return {
		"trigger_id": trigger_id,
		"hook": hook,
		"controller": controller,
		"priority": priority,
		"source_ref": source_ref.duplicate(true),
		"optional": optional,
		"liveness": liveness.duplicate(true),
		"guards": guards.duplicate(true),
		"commands": command_specs,
		"parent_trigger_id": "",
		"depth": 1,
	}


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
	stack: ResolutionStack = null,
) -> Dictionary:
	var args: Dictionary = spec.get("args", {})
	match str(spec.get("op", "")):
		"trigger_draw_cards":
			_execute_draw_cards(state, args, events)
		"trigger_place_damage_counters":
			_execute_place_damage_counters(state, args, events, stack)
		"trigger_move_basic_energy":
			_execute_move_basic_energy(state, args, events)
		"trigger_switch_with_active":
			_execute_switch_with_active(state, args, events)
		_:
			return VMResult.fail(
				"未知触发命令: %s" % str(spec.get("op", "")),
				"unknown_trigger_command")
	return VMResult.ok()


func collect_after_damage_triggers(
	state: GameState,
	context: Dictionary,
	candidates: Array[Dictionary],
) -> void:
	if int(context.get("damage", 0)) <= 0:
		return
	var actor := int(context.get("actor", 0))
	var defender_player := int(context.get("defender_player", 1 - actor))
	var defender_slot := str(context.get("defender_slot", "active"))
	var defender: PokemonState = context.get("defender", null)
	if defender == null:
		return
	for energy_index in range(defender.energy_card_ids.size()):
		var energy_id := str(defender.energy_card_ids[energy_index])
		for effect_value in catalog.get_card(energy_id).get("energy_effects", []):
			var descriptor: Dictionary = effect_value
			if (
				str(descriptor.get("kind", "")) != "trigger"
				or str(descriptor.get("hook", "")) != VMModifierManager.AFTER_DAMAGE
			):
				continue
			var condition: Dictionary = descriptor.get("condition", {})
			if int(context.get("damage", 0)) < int(condition.get("min_damage", 1)):
				continue
			var effect_spec := command_spec_from_payload(
				Dictionary(descriptor.get("effect", {})))
			if effect_spec.is_empty():
				continue
			var effect_args: Dictionary = effect_spec.get("args", {})
			effect_args["player"] = defender_player
			effect_args["source"] = energy_id
			effect_spec["args"] = effect_args
			var source_ref := EntityRef.new(
				"attachment", defender_player, "field", defender_slot,
				energy_index, "energy", energy_id).to_dict()
			candidates.append(make_candidate(
				"after_damage:%d:%s:energy:%d:%s" % [
					defender_player, defender_slot, energy_index, energy_id],
				VMModifierManager.AFTER_DAMAGE,
				defender_player,
				int(descriptor.get("priority", 0)),
				source_ref,
				bool(descriptor.get("optional", false)),
				{"kind": "source_exists"},
				[],
				[effect_spec],
			))
	for ability_index in range(catalog.get_card(defender.card_id).get("abilities", []).size()):
		var ability: Dictionary = catalog.get_card(defender.card_id).get(
			"abilities", [])[ability_index]
		for effect_value in VMRuntimeEffects.strict_ability_effects(ability):
			var effect: Dictionary = effect_value
			if not VMRuntimeEffects.effect_matches(effect, "reactive_thorns"):
				continue
			var params := VMRuntimeEffects.effect_args(effect)
			var names: Array = params.get("filter_names", [])
			var count := 0
			for row in state.get_player(defender_player).get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				if pokemon and catalog.card_name(pokemon.card_id) in names:
					count += 1
			var counters := count * int(params.get("per_pokemon", 3))
			var attacker := state.get_player(actor).active
			if attacker and counters > 0:
				var command := {
					"op": "trigger_place_damage_counters",
					"args": {
						"player": actor,
						"slot": "active",
						# Keep a serializable entity anchor.  Authored post-hit effects
						# (notably self-switch) resolve before reactive triggers, so a
						# bare "active" slot would otherwise hit the replacement Pokemon.
						"target_ref": {
							"kind": "pokemon",
							"player": actor,
							"slot": "active",
							"card_id": attacker.card_id,
						},
						"count": counters,
						"source": "reactive_thorns",
						"source_player": defender_player,
						"source_kind": "ability",
						"presentation_phase": "after_damage_trigger",
					},
					"branches": {},
				}
				candidates.append(make_candidate(
					"after_damage:%d:%s:ability:%d:%s" % [
						defender_player, defender_slot, ability_index, defender.card_id],
					VMModifierManager.AFTER_DAMAGE,
					defender_player,
					int(effect.get("priority", 0)),
					EntityRef.new(
						"pokemon", defender_player, "field", defender_slot,
						-1, "", defender.card_id).to_dict(),
					bool(effect.get("optional", false)),
					{"kind": "source_exists"},
					[],
					[command],
				))


func collect_pokemon_ko_triggers(
	state: GameState,
	defeated_idx: int,
	source_slot: String,
	knocked_out: PokemonState,
	from_attack: bool,
	attack_actor: int,
	candidates: Array[Dictionary],
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
		var target_slot := "bench_%d" % bench_index
		var tool_id := bench_pokemon.attached_tool_id
		var tool_ref := EntityRef.new(
			"attachment", defeated_idx, "field", target_slot,
			0, "tool", tool_id).to_dict()
		var knocked_out_ref := EntityRef.new(
			"pokemon", defeated_idx, "field", source_slot,
			-1, "", knocked_out.card_id).to_dict()
		candidates.append(make_candidate(
			"pokemon_ko:%d:%s:tool:%s" % [defeated_idx, target_slot, tool_id],
			VMModifierManager.POKEMON_KO,
			defeated_idx,
			20,
			tool_ref,
			true,
			{"kind": "source_exists"},
			[{"kind": "ref_exists", "ref": knocked_out_ref}],
			[_move_basic_energy_trigger_spec(
				defeated_idx,
				source_slot,
				defeated_idx,
				target_slot,
				"exp_share",
				tool_id,
			)],
		))


func _bench_pokemon_has_exp_share(bench_pokemon: PokemonState) -> bool:
	return (
		bench_pokemon is PokemonState
		and not bench_pokemon.attached_tool_id.is_empty()
		and tool_has_effect(bench_pokemon.attached_tool_id, "tool_exp_share")
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
	target_tool_id: String = "",
) -> Dictionary:
	return {
		"op": "trigger_move_basic_energy",
		"args": {
			"from_player": from_player,
			"from_slot": from_slot,
			"to_player": to_player,
			"to_slot": to_slot,
			"source": source,
			"select_source": true,
			"optional": false,
			"target_tool_id": target_tool_id,
		},
		"branches": {},
	}


func collect_on_prize_revealed_triggers(
	card_id: String,
	player_idx: int,
	prize_index: int,
	candidates: Array[Dictionary],
) -> Dictionary:
	var source_ref := EntityRef.new(
		"card", player_idx, "prizes", "", prize_index, "", card_id).to_dict()
	var effect_index := 0
	for effect_value in catalog.get_card(card_id).get("energy_effects", []):
		if not effect_value is Dictionary:
			return VMResult.fail(
				"奖赏卡触发描述符必须是对象。", "invalid_trigger_payload")
		var descriptor: Dictionary = effect_value
		if (
			str(descriptor.get("kind", "")) != "trigger"
			or str(descriptor.get("hook", "")) != "ON_PRIZE_REVEALED"
		):
			effect_index += 1
			continue
		var condition_value: Variant = descriptor.get("condition", {})
		var effect_spec_value: Variant = descriptor.get("effect", {})
		if not condition_value is Dictionary or not effect_spec_value is Dictionary:
			return VMResult.fail(
				"奖赏卡触发 condition/effect 必须是对象。",
				"invalid_trigger_payload",
			)
		var condition: Dictionary = condition_value
		if str(condition.get("source_zone", "")) != "prizes":
			effect_index += 1
			continue
		var compiled_value: Variant = descriptor.get("compiled_commands", null)
		if not compiled_value is Array or compiled_value.is_empty():
			return VMResult.fail(
				"奖赏卡触发缺少编译后的VM命令。", "invalid_trigger_payload")
		var commands: Array[Dictionary] = []
		for command_value in compiled_value:
			if not command_value is Dictionary:
				return VMResult.fail(
					"奖赏卡触发编译命令必须是对象。", "invalid_trigger_payload")
			commands.append(Dictionary(command_value).duplicate(true))
		candidates.append(make_candidate(
			"on_prize_revealed:%d:%d:%d" % [player_idx, prize_index, effect_index],
			"ON_PRIZE_REVEALED",
			player_idx,
			int(descriptor.get("priority", 0)),
			source_ref,
			bool(descriptor.get("optional", false)),
			{"kind": "source_exists"},
			[],
			commands,
		))
		effect_index += 1
	return VMResult.ok()


func collect_on_attach_triggers(
	card_id: String,
	player_idx: int,
	target_slot: String,
	source_zone: String,
	candidates: Array[Dictionary],
	attachment_index: int = 0,
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
			candidates.append(make_candidate(
				"on_attach:%d:%s:%s" % [player_idx, target_slot, card_id],
				VMModifierManager.ON_ATTACH,
				player_idx,
				int(effect.get("priority", 0)),
				EntityRef.new(
					"attachment", player_idx, "field", target_slot,
					attachment_index, "energy", card_id).to_dict(),
				bool(effect.get("optional", false)),
				{"kind": "source_exists"},
				[],
				[_switch_with_active_trigger_spec(
					player_idx,
					target_slot.trim_prefix("bench_").to_int(),
					card_id,
					target_slot,
				)],
			))


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
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	_player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	_execute_place_damage_counters(state, args, events, stack)
	return VMResult.ok()


func cmd_trigger_move_basic_energy(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	_player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var from_player := int(args.get("from_player", -1))
	var from_slot := str(args.get("from_slot", ""))
	var source := state.get_player(from_player).get_pokemon(from_slot)
	var target := state.get_player(int(args.get("to_player", from_player))).get_pokemon(
		str(args.get("to_slot", "")))
	if source == null or target == null:
		return VMResult.ok("触发来源或目标已失效。")
	var target_tool_id := str(args.get("target_tool_id", ""))
	if not target_tool_id.is_empty() and target.attached_tool_id != target_tool_id:
		return VMResult.ok("触发来源道具已失效。")
	var options: Array[Dictionary] = []
	for index in range(source.energy_card_ids.size()):
		var energy_id := str(source.energy_card_ids[index])
		if not catalog.is_basic_energy(energy_id):
			continue
		var ref := EntityRef.new(
			"attachment", from_player, "field", from_slot,
			index, "energy", energy_id).to_dict()
		options.append({
			"option_id": "attachment:%d:%s:energy:%d:%s" % [
				from_player, from_slot, index, energy_id],
			"label": catalog.card_name(energy_id),
			"ref": ref,
			"value": ref.duplicate(true),
		})
	if options.is_empty():
		return VMResult.ok("没有可移动的基础能量。")
	if not bool(args.get("select_source", false)):
		return _move_selected_basic_energy(
			state,
			args,
			Dictionary(options[0].get("ref", {})),
			events,
		)
	var frame_id := "trigger:move_basic_energy:%d" % stack.sequence
	stack.push_continuation("trigger_move_basic_energy", {
		"kind": "trigger_move_basic_energy",
		"frame_id": frame_id,
		"args": args.duplicate(true),
	})
	var domain := vm_interpreter.trigger_scheduler.choice_domain_for_current_trigger(stack)
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, from_player, "select_attachment"),
		"select_attachment",
		from_player,
		"请选择要移动的基础能量。",
		options,
		1,
		1,
		false,
		false,
		{
			"domain": domain,
			"purpose": "trigger_move_basic_energy",
			"revision": state.revision,
			"continuation_frame_id": frame_id,
			"trigger_id": stack.current_trigger_id(),
		},
	)
	return VMResult.ok("请选择要移动的基础能量。")


func continue_trigger_move_basic_energy(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	if selected.size() != 1:
		return VMResult.fail("必须选择1张基础能量。", "choice_count")
	var ref_value: Variant = selected[0].get("ref", selected[0].get("value", {}))
	if not ref_value is Dictionary:
		return VMResult.fail("基础能量引用无效。", "invalid_choice")
	return _move_selected_basic_energy(
		state,
		Dictionary(data.get("args", {})),
		Dictionary(ref_value),
		events,
	)


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
	stack: ResolutionStack = null,
) -> void:
	var target_player := int(args.get("player", 0))
	var target_slot := str(args.get("slot", "active"))
	var target_ref_value: Variant = args.get("target_ref", null)
	var expected_card_id := ""
	if target_ref_value is Dictionary and not target_ref_value.is_empty():
		var target_ref: Dictionary = target_ref_value
		target_player = int(target_ref.get("player", target_player))
		target_slot = str(target_ref.get("slot", target_slot))
		expected_card_id = str(target_ref.get("card_id", ""))
	var target := state.get_player(target_player).get_pokemon(target_slot)
	if target != null and not expected_card_id.is_empty() and target.card_id != expected_card_id:
		# Never fall back to whichever Pokemon currently occupies the old slot.  A
		# stale/missing anchor makes this optional reactive consequence a no-op.
		target = null
	var counters := int(args.get("count", 0))
	if target and counters > 0:
		target.damage_counters += counters
		if stack != null:
			var causes: Dictionary = stack.context.get("knockout_causes", {})
			causes["%d:%s" % [target_player, target_slot]] = {
				"source_kind": str(args.get("source_kind", "ability")),
				"cause_kind": "damage_counters",
				"source_player": int(args.get("source_player", target_player)),
			}
			stack.context["knockout_causes"] = causes
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
				"presentation_phase": str(args.get("presentation_phase", "")),
			},
		})


static func retarget_pending_after_damage_entity(
	stack: ResolutionStack,
	player_idx: int,
	from_slot: String,
	to_slot: String,
	card_id: String,
) -> void:
	"""Move serialized reactive targets when the referenced Pokemon changes slots."""
	if stack == null or not stack.context.get("pending_after_damage_triggers", []) is Array:
		return
	var candidates: Array = stack.context.get("pending_after_damage_triggers", [])
	for candidate_index in range(candidates.size()):
		if not candidates[candidate_index] is Dictionary:
			continue
		var candidate: Dictionary = candidates[candidate_index]
		var commands: Array = candidate.get("commands", [])
		for command_index in range(commands.size()):
			if not commands[command_index] is Dictionary:
				continue
			var spec: Dictionary = commands[command_index]
			if str(spec.get("op", "")) != "trigger_place_damage_counters":
				continue
			var args: Dictionary = spec.get("args", {})
			var target_ref_value: Variant = args.get("target_ref", null)
			if not target_ref_value is Dictionary:
				continue
			var target_ref: Dictionary = target_ref_value
			if (
				int(target_ref.get("player", -1)) != player_idx
				or str(target_ref.get("slot", "")) != from_slot
				or str(target_ref.get("card_id", "")) != card_id
			):
				continue
			target_ref["slot"] = to_slot
			args["target_ref"] = target_ref
			args["player"] = player_idx
			args["slot"] = to_slot
			spec["args"] = args
			commands[command_index] = spec
		candidate["commands"] = commands
		candidates[candidate_index] = candidate
	stack.context["pending_after_damage_triggers"] = candidates


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
	_move_selected_basic_energy(
		state,
		args,
		EntityRef.new(
			"attachment", from_player, "field", from_slot,
			basic_energy_index, "energy",
			str(source.energy_card_ids[basic_energy_index])).to_dict(),
		events,
	)


func _move_selected_basic_energy(
	state: GameState,
	args: Dictionary,
	ref: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var from_player := int(args.get("from_player", -1))
	var from_slot := str(args.get("from_slot", ""))
	var to_player := int(args.get("to_player", from_player))
	var to_slot := str(args.get("to_slot", ""))
	var source := state.get_player(from_player).get_pokemon(from_slot)
	var target := state.get_player(to_player).get_pokemon(to_slot)
	var target_tool_id := str(args.get("target_tool_id", ""))
	var basic_energy_index := int(ref.get("index", -1))
	var expected_id := str(ref.get("card_id", ""))
	if (
		source == null
		or target == null
		or (not target_tool_id.is_empty() and target.attached_tool_id != target_tool_id)
		or str(ref.get("kind", "")) != "attachment"
		or int(ref.get("player", -1)) != from_player
		or str(ref.get("slot", "")) != from_slot
		or str(ref.get("attachment_type", "")) != "energy"
		or basic_energy_index < 0
		or basic_energy_index >= source.energy_card_ids.size()
		or str(source.energy_card_ids[basic_energy_index]) != expected_id
		or not catalog.is_basic_energy(expected_id)
	):
		return VMResult.fail("选择的基础能量已不存在。", "stale_choice")
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
	return VMResult.ok("基础能量已移动。")


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
