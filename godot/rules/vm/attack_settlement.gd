class_name VMAttackSettlement
extends RefCounted

var catalog: CardCatalog
var validator: RulesValidator
var effect_engine: EffectEngine
var turn_settlement: VMTurnSettlement
var trigger_command_runner: VMTriggerCommands
var knockout_settlement: VMKnockoutSettlement

# These commands determine whether/how the primary hit is applied. Everything
# else is an attack consequence and must resolve only after the hit and its
# on-damage triggers, but before KO settlement.
const PRE_HIT_ATTACK_OPS: Array[String] = [
	"choose_damage_target",
	"conditional_damage",
	"conditional_damage_then_heal",
	"deal_damage_per_discard_psychic",
	"deal_damage_per_energy",
	"deal_damage_per_evolved",
	"deal_damage_per_hand_size",
	"deal_damage_per_self_damage",
	"deal_damage_per_self_energy",
	"deal_damage_per_self_energy_type",
	"deal_damage_plus_bench",
	"deal_damage_with_self_penalty",
	"discard_energy_then_damage",
	"discard_hand_then_damage",
	"fail_attack",
	"flip_coin",
	"flip_coin_repeat_damage",
	"flip_coin_then_ko",
	"flip_until_tails",
	"mill_then_damage",
	"set_attack_damage_formula",
	"set_attack_flags",
]


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

	var gate_events: Array[Dictionary] = []
	if "CONFUSED" in attacker.status_conditions:
		var confusion_heads := rng.coin()
		gate_events.append(_attack_gate_coin_event(actor, confusion_heads, "confusion"))
		if not confusion_heads:
			attacker.damage_counters += 3
			gate_events.append({
				"event_type": "confusion_failed",
				"actor": actor,
				"source": {"player": actor, "slot": "active"},
				"target": {"player": actor, "slot": "active"},
				"amount": 30,
				"data": {"player": actor, "slot": "active", "self_damage": 30},
			})
			gate_events.push_front(attack_event)
			return _complete_failed_attack_gate(
				state, actor, gate_events, rng, "混乱判定失败，攻击未生效。")
	if attacker.dazzled:
		attacker.dazzled = false
		var dazzled_heads := rng.coin()
		gate_events.append(_attack_gate_coin_event(actor, dazzled_heads, "dazzled"))
		if not dazzled_heads:
			gate_events.append({
				"event_type": "dazzled_failed",
				"actor": actor,
				"source": {"player": actor, "slot": "active"},
				"target": {"player": actor, "slot": "active"},
				"data": {"player": actor, "slot": "active"},
			})
			gate_events.push_front(attack_event)
			return _complete_failed_attack_gate(
				state, actor, gate_events, rng, "炫目判定失败，攻击未生效。")

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
		"attacker_card_id": attacker.card_id,
		"attacker_snapshot": attacker.to_dict(),
		"base_damage": 0 if replace_base else int(attack.get("damage", 0)),
		"attacking_type": attacking_type,
	}
	var phased_effects := partition_attack_effects(attack_effects)
	context["post_hit_effects"] = phased_effects["post_hit"]
	var step := run_attack_effects(
		state, phased_effects["pre_hit"], actor, "active", rng, context)
	step.events = gate_events + step.events
	if not step.success or step.pending_choice:
		step.events.push_front(attack_event)
		return step
	var stack := ResolutionStack.from_dict(state.resolution_stack)
	step.events.push_front(attack_event)
	return merge_attack_presentation(
		step,
		complete_attack_context(state, stack, rng),
	)


func complete_attack_context(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
) -> StepResult:
	var finalize_frame := stack.pop_finalize_attack()
	if finalize_frame.is_empty():
		return StepResult.new(true)
	var actor := int(finalize_frame.get("actor", stack.context.get("actor", state.active_player_idx)))
	var stage := str(finalize_frame.get("stage", "primary_hit"))
	if stage == "settle_knockouts":
		return settle_attack_knockouts_and_turn(state, stack, actor, rng)

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
			str(stack.context.get("attacker_card_id", "")),
			Dictionary(stack.context.get("attacker_snapshot", {})),
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

	# Conditional coin branches are selected while resolving the pre-hit frame.
	# Their ordinary consequences join the authored post-hit effects and are run
	# only now, after damage and reactive on-damage triggers.
	var post_hit_effects: Array = []
	post_hit_effects.append_array(stack.context.get("conditional_post_hit_effects", []))
	post_hit_effects.append_array(stack.context.get("post_hit_effects", []))
	stack.context.erase("conditional_post_hit_effects")
	stack.context.erase("post_hit_effects")
	if bool(stack.context.get("attack_failed", false)):
		post_hit_effects.clear()
	stack.push_finalize_attack(actor, "settle_knockouts")
	stack.push_effects(post_hit_effects, actor, "active")
	var hit_step := StepResult.new(true, "", null, events, state.winner, state.winner >= 0)
	var post_hit_step := effect_engine.resolve(state, stack, rng)
	if not post_hit_step.success or post_hit_step.pending_choice != null:
		return _merge_steps(hit_step, post_hit_step)
	if stack.has_finalize_attack_frame():
		return _merge_steps(
			_merge_steps(hit_step, post_hit_step),
			complete_attack_context(state, stack, rng),
		)
	return _merge_steps(hit_step, post_hit_step)


func settle_attack_knockouts_and_turn(
	state: GameState,
	stack: ResolutionStack,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	var events: Array[Dictionary] = []
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
	attacker_card_id: String = "",
	attacker_snapshot: Dictionary = {},
) -> void:
	var attacker: PokemonState = null
	if not attacker_snapshot.is_empty():
		attacker = PokemonState.from_dict(attacker_snapshot)
	else:
		attacker = state.get_player(actor).active
	var defender := state.get_player(1 - actor).active
	if attacker == null and not attacker_card_id.is_empty():
		attacker = PokemonState.new(attacker_card_id)
	if attacker == null or defender == null or base_damage <= 0:
		return
	if defender.damage_prevented_next_turn and not ignore_defender_effects:
		events.append({
			"event_type": "damage_prevented",
			"actor": actor,
			"source": {"player": actor, "slot": "active"},
			"target": {"player": 1 - actor, "slot": "active"},
			"data": {"player": 1 - actor, "slot": "active"},
		})
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
	var applied_counters := int(float(damage) / 10.0)
	var applied_amount := applied_counters * 10
	defender.damage_counters += applied_counters
	if applied_amount > 0:
		events.append({
			"event_type": "damage_dealt",
			"actor": actor,
			"source": {"player": actor, "slot": "active"},
			"target": {"player": 1 - actor, "slot": "active"},
			"amount": applied_amount,
			"data": {
				"player": 1 - actor,
				"slot": "active",
				"amount": applied_amount,
				"cause": "attack",
			},
		})
	trigger_command_runner.collect_after_damage_commands(
		state,
		damage_context,
		trigger_commands,
	)


func partition_attack_effects(effects: Array) -> Dictionary:
	var pre_hit: Array[Dictionary] = []
	var post_hit: Array[Dictionary] = []
	for effect_value in effects:
		var effect := Dictionary(effect_value).duplicate(true)
		var op := str(effect.get("op", ""))
		if op == "deal_damage_then_heal":
			# This legacy compound command used to heal before the queued primary
			# packet landed. Split it so its authored "then" is literal.
			var args := Dictionary(effect.get("args", {}))
			pre_hit.append({
				"op": "deal_damage",
				"args": {"amount": int(args.get("damage", 0))},
				"branches": {},
			})
			post_hit.append({
				"op": "heal_damage",
				"args": {
					"amount": int(args.get("heal", 0)),
					"target": "self",
				},
				"branches": {},
			})
		elif _is_pre_hit_attack_effect(effect):
			pre_hit.append(effect)
		else:
			post_hit.append(effect)
	return {"pre_hit": pre_hit, "post_hit": post_hit}


func _is_pre_hit_attack_effect(effect: Dictionary) -> bool:
	var op := str(effect.get("op", ""))
	if op == "deal_damage":
		return str(Dictionary(effect.get("args", {})).get(
			"target", "opponent_active")) != "self"
	return op in PRE_HIT_ATTACK_OPS


func _attack_gate_coin_event(actor: int, heads: bool, purpose: String) -> Dictionary:
	return {
		"event_type": "coin_flip",
		"actor": actor,
		"source": {"player": actor, "slot": "active"},
		"target": {"player": actor, "slot": "active"},
		"data": {
			"player": actor,
			"results": [heads],
			"purpose": purpose,
		},
	}


func _complete_failed_attack_gate(
	state: GameState,
	actor: int,
	events: Array[Dictionary],
	rng: PortableRandomSource,
	message: String,
) -> StepResult:
	var ko_result := knockout_settlement.resolve_knockouts(
		state, actor, events, false)
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
	knockout_settlement.resolve_empty_boards_and_promotions(state)
	var failed_step := StepResult.new(
		true, message, null, events, state.winner, state.winner >= 0)
	if state.winner >= 0:
		return failed_step
	if not state.pending_promotions.is_empty():
		var promotion_stack := ResolutionStack.new()
		promotion_stack.context = {
			"finish_attack_after_promotions": true,
			"actor": actor,
		}
		promotion_stack.push_finalize_attack_turn(actor)
		state.resolution_stack = promotion_stack.to_dict()
		return failed_step
	var failed_stack := ResolutionStack.new()
	failed_stack.push_finalize_attack_turn(actor)
	return _merge_steps(
		failed_step, resolve_attack_turn_frame(state, failed_stack, rng))


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


func merge_attack_presentation(
	effect_step: StepResult,
	completion_step: StepResult,
) -> StepResult:
	# Preserve the causal phases even when a pending pre-hit or post-hit choice
	# resumes in a later transaction. Events within each phase remain stable.
	var declarations: Array[Dictionary] = []
	var pre_hit_events: Array[Dictionary] = []
	var hit_events: Array[Dictionary] = []
	var post_hit_events: Array[Dictionary] = []
	var knockout_events: Array[Dictionary] = []
	var flow_events: Array[Dictionary] = []
	var reached_flow := false
	for event in effect_step.events + completion_step.events:
		var event_type := str(event.get("event_type", ""))
		var presentation_phase := str(Dictionary(event.get("data", {})).get(
			"presentation_phase", ""))
		if event_type in ["turn_end", "game_over"]:
			reached_flow = true
		if reached_flow:
			flow_events.append(event)
		elif event_type == "attack_declared":
			declarations.append(event)
		elif presentation_phase == "pre_hit" or event_type == "coin_flip":
			pre_hit_events.append(event)
		elif event_type in [
			"confusion_failed",
			"dazzled_failed",
			"damage_counters_placed",
			"damage_dealt",
			"damage_prevented",
		]:
			hit_events.append(event)
		elif (
			presentation_phase == "knockout"
			or event_type in ["pokemon_ko", "prize_taken"]
		):
			knockout_events.append(event)
		else:
			post_hit_events.append(event)

	var ordered_events: Array[Dictionary] = []
	ordered_events.append_array(declarations)
	ordered_events.append_array(pre_hit_events)
	ordered_events.append_array(hit_events)
	ordered_events.append_array(post_hit_events)
	ordered_events.append_array(knockout_events)
	ordered_events.append_array(flow_events)
	var merged := _merge_steps(effect_step, completion_step)
	merged.events = ordered_events
	return merged


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
