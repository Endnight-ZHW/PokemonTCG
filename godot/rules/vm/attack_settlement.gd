class_name VMAttackSettlement
extends RefCounted

var catalog: CardCatalog
var validator: RulesValidator
var effect_engine: EffectEngine
var turn_settlement: VMTurnSettlement
var trigger_command_runner: VMTriggerCommands
var knockout_settlement: VMKnockoutSettlement


func _init(
	p_catalog: CardCatalog,
	p_validator: RulesValidator,
	p_knockout_settlement: VMKnockoutSettlement = null,
	p_effect_engine: EffectEngine = null,
) -> void:
	catalog = p_catalog
	validator = p_validator
	effect_engine = p_effect_engine
	trigger_command_runner = VMTriggerCommands.new(catalog)
	if p_knockout_settlement != null:
		knockout_settlement = p_knockout_settlement
	else:
		knockout_settlement = VMKnockoutSettlement.new(catalog, validator, trigger_command_runner)


func set_trigger_command_runner(p_trigger_command_runner: VMTriggerCommands) -> void:
	trigger_command_runner = p_trigger_command_runner
	knockout_settlement.trigger_command_runner = p_trigger_command_runner


func declare_attack(
	state: GameState,
	actor: int,
	attack_idx: int,
	rng: PortableRandomSource,
) -> StepResult:
	var reason := validator.can_attack(state, actor, attack_idx)
	if not reason.is_empty():
		return _error(reason, "illegal_attack", state)
	if effect_engine == null:
		return _error("攻击结算缺少 VM 解释器。", "missing_effect_engine", state)
	var attacker := state.get_player(actor).active
	var attack: Dictionary = catalog.get_card(attacker.card_id).get("attacks", [])[attack_idx]
	state.phase = "ATTACK"
	state.log_action("%s使用了%s。" % [catalog.card_name(attacker.card_id), attack.get("name", "")])
	var attack_event := {
		"event_type": "attack_declared",
		"actor": actor,
		"card_id": attacker.card_id,
		"source": {"player": actor, "slot": "active"},
		"target": {"player": 1 - actor, "slot": "active"},
		"data": {
			"player": actor,
			"attack_idx": attack_idx,
			"attack_name": str(attack.get("name", "")),
			"card_id": attacker.card_id,
		},
	}

	if "CONFUSED" in attacker.status_conditions and not rng.coin():
		attacker.damage_counters += 3
		var confused_events: Array[Dictionary] = [attack_event, {
			"event_type": "confusion_failed",
			"data": {"player": actor, "self_damage": 30},
		}]
		var confused_ko_result := knockout_settlement.resolve_knockouts(state, actor, confused_events, false)
		if not bool(confused_ko_result.get("success", false)):
			return StepResult.new(
				false,
				str(confused_ko_result.get("message", "触发命令结算失败。")),
				null,
				confused_events,
				state.winner,
				false,
				str(confused_ko_result.get("error_code", "trigger_command_failed")),
			)
		knockout_settlement.resolve_empty_boards_and_promotions(state)
		var confused_step := StepResult.new(
			true,
			"混乱判定失败，攻击未生效。",
			null,
			confused_events,
			state.winner,
			state.winner >= 0,
		)
		if state.winner >= 0:
			return confused_step
		if not state.pending_promotions.is_empty():
			var promotion_stack := ResolutionStack.new()
			promotion_stack.context = {
				"finish_attack_after_promotions": true,
				"actor": actor,
			}
			promotion_stack.push_finalize_attack_turn(actor)
			state.resolution_stack = promotion_stack.to_dict()
			return confused_step
		var confused_stack := ResolutionStack.new()
		confused_stack.push_finalize_attack_turn(actor)
		return _merge_steps(confused_step, resolve_attack_turn_frame(state, confused_stack, rng))
	if attacker.dazzled:
		attacker.dazzled = false
		if not rng.coin():
			var dazzled_stack := ResolutionStack.new()
			dazzled_stack.push_finalize_attack_turn(actor)
			return _merge_steps(
				StepResult.new(true, "炫目判定失败，攻击未生效。"),
				resolve_attack_turn_frame(state, dazzled_stack, rng),
			)

	var attack_effects := attack_runtime_effects(attack)
	var replace_base := false
	for effect_value in attack_effects:
		var effect: Dictionary = effect_value
		if VMRuntimeEffects.replaces_attack_base_damage(effect):
			replace_base = true
			break
	var card := catalog.get_card(attacker.card_id)
	var attacking_type := "Colorless"
	if not card.get("energy_types", []).is_empty():
		attacking_type = str(card.get("energy_types", [])[0])
	var context := {
		"finish_attack": true,
		"actor": actor,
		"base_damage": 0 if replace_base else int(attack.get("damage", 0)),
		"attacking_type": attacking_type,
	}
	var step := run_attack_effects(state, attack_effects, actor, "active", rng, context)
	if not step.success or step.pending_choice:
		step.events.push_front(attack_event)
		return step
	var stack := ResolutionStack.from_dict(state.resolution_stack)
	step.events.push_front(attack_event)
	return _merge_steps(step, complete_attack_context(state, stack, rng))


func complete_attack_context(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
) -> StepResult:
	var finalize_frame := stack.pop_finalize_attack()
	if finalize_frame.is_empty():
		return StepResult.new(true)
	var actor := int(finalize_frame.get("actor", stack.context.get("actor", state.active_player_idx)))
	var events: Array[Dictionary] = []
	if not bool(stack.context.get("attack_failed", false)):
		var trigger_commands_to_resolve: Array[Dictionary] = []
		apply_attack_damage(
			state,
			actor,
			int(stack.context.get("base_damage", 0)),
			str(stack.context.get("attacking_type", "Colorless")),
			bool(stack.context.get("piercing", false)),
			bool(stack.context.get("ignore_defender_effects", false)),
			events,
			trigger_commands_to_resolve,
		)
		var trigger_result := trigger_command_runner.resolve_commands(
			state,
			actor,
			trigger_commands_to_resolve,
			events,
			stack,
		)
		if not bool(trigger_result.get("success", false)):
			return StepResult.new(
				false,
				str(trigger_result.get("message", "触发命令结算失败。")),
				null,
				events,
				state.winner,
				false,
				str(trigger_result.get("error_code", "trigger_command_failed")),
			)
	var ko_result := knockout_settlement.resolve_knockouts(state, actor, events, true, stack)
	if not bool(ko_result.get("success", false)):
		return StepResult.new(
			false,
			str(ko_result.get("message", "触发命令结算失败。")),
			null,
			events,
			state.winner,
			false,
			str(ko_result.get("error_code", "trigger_command_failed")),
		)
	var damage_step := StepResult.new(true, "", null, events, state.winner, state.winner >= 0)
	knockout_settlement.resolve_empty_boards_and_promotions(state)
	if state.winner >= 0:
		state.resolution_stack = ResolutionStack.new().to_dict()
		damage_step.winner = state.winner
		damage_step.terminal = true
		return damage_step
	if not state.pending_promotions.is_empty():
		stack.context["finish_attack_after_promotions"] = true
		stack.context["actor"] = actor
		stack.push_finalize_attack_turn(actor)
		state.resolution_stack = stack.to_dict()
		return damage_step
	stack.push_finalize_attack_turn(actor)
	return _merge_steps(damage_step, resolve_attack_turn_frame(state, stack, rng))


func resolve_attack_turn_frame(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
) -> StepResult:
	var finalize_turn_frame := stack.pop_finalize_attack_turn()
	if finalize_turn_frame.is_empty():
		return StepResult.new(true)
	var actor := int(finalize_turn_frame.get("actor", stack.context.get("actor", state.active_player_idx)))
	state.resolution_stack = ResolutionStack.new().to_dict()
	if turn_settlement == null:
		return StepResult.new(
			false,
			"攻击结算缺少回合状态机。",
			null,
			[],
			state.winner,
			false,
			"missing_turn_settlement",
		)
	return turn_settlement.end_turn(state, actor, rng)


func apply_attack_damage(
	state: GameState,
	actor: int,
	base_damage: int,
	attacking_type: String,
	piercing: bool,
	ignore_defender_effects: bool,
	events: Array[Dictionary],
	trigger_commands: Array[Dictionary] = [],
) -> void:
	var attacker := state.get_player(actor).active
	var defender := state.get_player(1 - actor).active
	if attacker == null or defender == null or base_damage <= 0:
		return
	if defender.damage_prevented_next_turn and not ignore_defender_effects:
		defender.damage_prevented_next_turn = false
		defender.all_prevented_next_turn = false
		events.append({"event_type": "damage_prevented", "data": {"player": 1 - actor}})
		return
	var damage := base_damage
	if state.apply_type_matchups and not piercing:
		var defending_card := catalog.get_card(defender.card_id)
		for weakness_value in defending_card.get("weaknesses", []):
			var weakness: Dictionary = weakness_value
			if str(weakness.get("energy_type", "")) == attacking_type:
				var value := str(weakness.get("value", ""))
				if value in ["×2", "x2"]:
					damage *= 2
				break
		for resistance_value in defending_card.get("resistances", []):
			var resistance: Dictionary = resistance_value
			if str(resistance.get("energy_type", "")) == attacking_type:
				damage -= abs(int(str(resistance.get("value", "0")).replace("-", "")))
				break
	var damage_context := {
		"actor": actor,
		"attacker": attacker,
		"defender": defender,
		"damage": damage,
		"attacking_type": attacking_type,
		"piercing": piercing,
		"ignore_defender_effects": ignore_defender_effects,
	}
	damage = VMDamageModifierHooks.apply_modify_damage(state, catalog, damage_context)
	damage_context["damage"] = damage
	defender.damage_counters += int(float(damage) / 10.0)
	events.append({"event_type": "damage_dealt", "data": {
		"player": 1 - actor, "slot": "active", "amount": damage,
	}})
	trigger_command_runner.collect_after_damage_commands(
		state,
		damage_context,
		trigger_commands,
	)


func run_attack_effects(
	state: GameState,
	effects: Array,
	actor: int,
	source_slot: String,
	rng: PortableRandomSource,
	context: Dictionary,
) -> StepResult:
	var stack := ResolutionStack.new()
	stack.context = context.duplicate(true)
	stack.push_finalize_attack(actor)
	stack.push_effects(effects, actor, source_slot)
	return effect_engine.resolve(state, stack, rng)


func attack_runtime_effects(attack: Dictionary) -> Array:
	return VMRuntimeEffects.strict_attack_effects(attack)


func _error(
	message: String,
	code: String,
	state: GameState,
) -> StepResult:
	return StepResult.new(false, message, null, [], state.winner, false, code)


func _merge_steps(first: StepResult, second: StepResult) -> StepResult:
	var message := first.message
	if not second.message.is_empty():
		message = ("%s %s" % [message, second.message]).strip_edges()
	return StepResult.new(
		first.success and second.success,
		message,
		second.pending_choice if second.pending_choice else first.pending_choice,
		first.events + second.events,
		second.winner if second.winner >= 0 else first.winner,
		first.terminal or second.terminal,
		second.error_code if not second.error_code.is_empty() else first.error_code,
	)
