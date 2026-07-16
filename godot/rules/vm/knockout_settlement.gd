class_name VMKnockoutSettlement
extends RefCounted

var catalog: CardCatalog
var validator: RulesValidator
var trigger_command_runner: VMTriggerCommands


func _init(
	p_catalog: CardCatalog,
	p_validator: RulesValidator,
	p_trigger_command_runner: VMTriggerCommands = null,
) -> void:
	catalog = p_catalog
	validator = p_validator
	if p_trigger_command_runner != null:
		trigger_command_runner = p_trigger_command_runner
	else:
		trigger_command_runner = VMTriggerCommands.new(catalog)


func resolve_knockouts(
	state: GameState,
	attack_actor: int,
	events: Array[Dictionary],
	from_attack: bool,
	active_stack: ResolutionStack = null,
) -> Dictionary:
	# Engine-owned settlement always supplies a stack so every Prize card remains
	# an explicit player choice.  Keep the historical low-level ATTACK entry point
	# synchronous for presentation/event consumers that have no choice dispatcher;
	# it still runs through the same prize-choice implementation below.
	var settle_synchronously := active_stack == null and state.phase == "ATTACK"
	var stack := active_stack if active_stack != null else ResolutionStack.new()
	if stack.context.get("ko_batch") is Dictionary:
		var continued := _continue_knockout_batch(state, stack, events)
		return (
			_settle_synchronous_prize_choices(state, stack, events, continued)
			if settle_synchronously
			else continued
		)
	var knockouts: Array[Dictionary] = []
	for player_idx in [0, 1]:
		for row in state.get_player(player_idx).get_all_pokemon():
			var pokemon: PokemonState = row["pokemon"]
			if pokemon and pokemon.is_knocked_out(catalog):
				knockouts.append({
					"player": player_idx,
					"slot": str(row["slot"]),
					"card_id": pokemon.card_id,
					"prizes": catalog.prize_value(pokemon.card_id),
					"stage": "declare",
				})
	if knockouts.is_empty():
		return VMResult.ok()
	stack.context["ko_batch"] = {
		"attack_actor": attack_actor,
		"from_attack": from_attack,
		"knockouts": knockouts,
		"prize_awards": [],
		"stage": "declare",
		"trigger_index": 0,
	}
	var result := _continue_knockout_batch(state, stack, events)
	return (
		_settle_synchronous_prize_choices(state, stack, events, result)
		if settle_synchronously
		else result
	)


func _settle_synchronous_prize_choices(
	state: GameState,
	stack: ResolutionStack,
	events: Array[Dictionary],
	initial_result: Dictionary,
) -> Dictionary:
	"""Drain low-level prize choices without bypassing canonical event creation."""
	var result := initial_result
	while bool(result.get("success", false)):
		var request: Variant = result.get("pending_choice", null)
		if not request is ChoiceRequest:
			break
		var choice_result: Dictionary
		if request.request_type == "select_prize":
			# Face-down positions are equivalent to this non-interactive caller.  A
			# real match never enters this branch and presents every position.
			choice_result = apply_prize_choice(
				state,
				request,
				ChoiceResponse.new(request.request_id, ["prize:0"]),
				stack,
			)
		elif str(request.metadata.get("purpose", "")) == "treasure_energy_attach":
			# The Treasure Energy attachment is optional; a non-interactive event
			# consumer deterministically declines it, then resumes remaining prizes.
			choice_result = apply_treasure_energy_choice(
				state,
				ChoiceResponse.new(request.request_id, [], true),
				stack,
			)
		else:
			# Trigger order/confirmation still needs a player and must remain paused.
			return result
		events.append_array(choice_result.get("events", []))
		result = choice_result
	if result.get("pending_choice", null) is ChoiceRequest:
		return result
	# _continue_knockout_batch installs this production continuation before the
	# first prize request.  The synchronous entry point owns no attack lifecycle,
	# so consume only that frame after its prize batch is complete.
	if stack.has_finalize_attack_frame():
		stack.pop_finalize_attack()
	stack.context.erase("prize_attack_actor")
	stack.context.erase("prize_from_attack")
	stack.pending_request = null
	resolve_empty_boards_and_promotions(state)
	if state.is_terminal():
		append_game_over_event(events, state)
	state.resolution_stack = stack.to_dict()
	return result


func _continue_knockout_batch(
	state: GameState,
	stack: ResolutionStack,
	events: Array[Dictionary],
) -> Dictionary:
	var batch: Dictionary = stack.context.get("ko_batch", {})
	var knockouts: Array = batch.get("knockouts", [])
	var stage := str(batch.get("stage", "declare"))
	if stage == "declare":
		# KO checks are a batch barrier. Announce every Pokemon and collect every
		# optional trigger against the same complete pre-discard board before any
		# trigger can pause settlement or any Pokemon can leave play.
		var live_knockouts: Array = []
		for knockout_value in knockouts:
			var knockout: Dictionary = knockout_value
			var defeated_idx := int(knockout.get("player", -1))
			var defeated_slot := str(knockout.get("slot", ""))
			var knocked_out := state.get_player(defeated_idx).get_pokemon(defeated_slot)
			if knocked_out == null or knocked_out.card_id != str(knockout.get("card_id", "")):
				continue
			_append_knockout_declared_event(
				events, knockout, int(batch.get("attack_actor", -1)))
			var knockout_cause := _knockout_cause_for(
				stack, batch, defeated_idx, defeated_slot)
			knockout["cause"] = knockout_cause
			knockout["triggers"] = _collect_exp_share_triggers(
				state,
				defeated_idx,
				defeated_slot,
				knocked_out,
				knockout_cause,
			)
			knockout["current_trigger"] = {}
			live_knockouts.append(knockout)
		knockouts = live_knockouts
		batch["knockouts"] = knockouts
		batch["stage"] = "triggers"
		batch["trigger_index"] = 0
		stack.context["ko_batch"] = batch

		# The current card pool has only Learning Device in the KO hook domain;
		# keep the generic immediate-hook path after the global declaration and
		# collection barrier so future registered commands cannot cause an early
		# leave-play mutation.
		for knockout_value in knockouts:
			var knockout: Dictionary = knockout_value
			var defeated_idx := int(knockout.get("player", -1))
			var defeated_slot := str(knockout.get("slot", ""))
			var knocked_out := state.get_player(defeated_idx).get_pokemon(defeated_slot)
			if knocked_out == null or knocked_out.card_id != str(knockout.get("card_id", "")):
				continue
			var knockout_cause: Dictionary = knockout.get("cause", {})
			var non_exp_share_result := _resolve_non_exp_share_ko_triggers(
				state,
				stack,
				events,
				defeated_idx,
				defeated_slot,
				knocked_out,
				_is_opponent_attack_damage(knockout_cause, defeated_idx),
				int(knockout_cause.get("source_player", -1)),
			)
			if not bool(non_exp_share_result.get("success", false)):
				return non_exp_share_result
		stage = "triggers"

	if stage == "triggers":
		var trigger_index := int(batch.get("trigger_index", 0))
		while trigger_index < knockouts.size():
			var knockout: Dictionary = knockouts[trigger_index]
			var triggers: Array = knockout.get("triggers", [])
			if (
				not triggers.is_empty()
				or not Dictionary(knockout.get("current_trigger", {})).is_empty()
			):
				var trigger_request := _request_next_ko_trigger(state, stack)
				if trigger_request != null:
					var pending_trigger := VMResult.ok()
					pending_trigger["pending_choice"] = trigger_request
					return pending_trigger
			trigger_index += 1
			batch = stack.context.get("ko_batch", {})
			batch["trigger_index"] = trigger_index
			stack.context["ko_batch"] = batch
		batch = stack.context.get("ko_batch", {})
		batch["stage"] = "discard"
		stack.context["ko_batch"] = batch
		stage = "discard"

	if stage == "discard":
		# No choice may occur in this phase. Sequential mutations are emitted in
		# one atomic result, after every simultaneous KO trigger has completed.
		knockouts = batch.get("knockouts", [])
		while not knockouts.is_empty():
			_finalize_current_knockout(state, stack, events)
			batch = stack.context.get("ko_batch", {})
			knockouts = batch.get("knockouts", [])
	batch = stack.context.get("ko_batch", {})
	var prize_awards: Array = batch.get("prize_awards", [])
	stack.context.erase("ko_batch")
	queue_empty_board_promotions(state)
	if not prize_awards.is_empty():
		stack.context["prize_awards"] = prize_awards
		stack.context["prize_attack_actor"] = int(batch.get("attack_actor", -1))
		stack.context["prize_from_attack"] = bool(batch.get("from_attack", false))
		if bool(batch.get("from_attack", false)) and not stack.has_finalize_attack_frame():
			stack.push_finalize_attack(
				int(batch.get("attack_actor", -1)), "after_prizes")
		var prize_request := request_next_prize(state, stack)
		var pending_prize := VMResult.ok()
		pending_prize["pending_choice"] = prize_request
		return pending_prize
	stack.pending_request = null
	state.resolution_stack = stack.to_dict()
	resolve_empty_boards_and_promotions(state)
	if state.is_terminal():
		append_game_over_event(events, state)
	return VMResult.ok()


func _resolve_non_exp_share_ko_triggers(
	state: GameState,
	stack: ResolutionStack,
	events: Array[Dictionary],
	defeated_idx: int,
	defeated_slot: String,
	knocked_out: PokemonState,
	from_attack: bool,
	attack_actor: int,
) -> Dictionary:
	var commands: Array[Dictionary] = []
	trigger_command_runner.collect_pokemon_ko_commands(
		state,
		defeated_idx,
		defeated_slot,
		knocked_out,
		from_attack,
		attack_actor,
		commands,
	)
	var normalized := trigger_command_runner.command_specs_from_payloads(commands)
	if not bool(normalized.get("success", false)):
		return normalized
	var immediate: Array[Dictionary] = []
	for spec_value in normalized.get("commands", []):
		var spec: Dictionary = spec_value
		# Learning Device is optional and needs entity/order/energy choices, so it
		# is handled by the serializable KO trigger queue below.
		if str(spec.get("op", "")) == "trigger_move_basic_energy":
			continue
		immediate.append(spec.duplicate(true))
	if immediate.is_empty():
		return VMResult.ok()
	var trigger_result := trigger_command_runner.resolve_commands(
		state, attack_actor, immediate, events, stack)
	return trigger_result


func _append_knockout_declared_event(
	events: Array[Dictionary],
	knockout: Dictionary,
	attack_actor: int,
) -> void:
	var defeated_idx := int(knockout.get("player", -1))
	var defeated_slot := str(knockout.get("slot", ""))
	var source_index := (
		defeated_slot.trim_prefix("bench_").to_int()
		if defeated_slot.begins_with("bench_")
		else 0
	)
	events.append({
		"event_type": "pokemon_ko",
		"actor": attack_actor,
		"card_id": str(knockout.get("card_id", "")),
		"source": {
			"player": defeated_idx,
			"slot": defeated_slot,
			"index": source_index,
		},
		"target": {"player": defeated_idx, "slot": defeated_slot},
		"amount": 1,
		"data": knockout.merged({
			"stage": "declared",
			"defer_leave_play": true,
			"presentation_phase": "knockout",
		}, true),
	})


func _collect_exp_share_triggers(
	state: GameState,
	defeated_idx: int,
	defeated_slot: String,
	knocked_out: PokemonState,
	knockout_cause: Dictionary,
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	# Learning Device only sees the owner's Active Pokemon being Knocked Out by
	# damage from the opponent's attack. Direct-KO/effect/checkup paths do not
	# satisfy that condition.
	if (
		not _is_opponent_attack_damage(knockout_cause, defeated_idx)
		or defeated_slot != "active"
		or not trigger_command_runner.pokemon_has_basic_energy(knocked_out)
	):
		return result
	var player := state.get_player(defeated_idx)
	for bench_index in range(player.bench.size()):
		var target: PokemonState = player.bench[bench_index]
		if target == null:
			continue
		var target_slot := "bench_%d" % bench_index
		var tool_id := target.attached_tool_id
		var modifier_index := -1
		if tool_id.is_empty() or not trigger_command_runner.tool_has_effect(
			tool_id, "tool_exp_share"):
			tool_id = ""
			for index in range(target.modifiers.size()):
				if str(target.modifiers[index].get(
					"modifier_kind", target.modifiers[index].get("effect_type", ""))) == "tool_exp_share":
					modifier_index = index
					break
			if modifier_index < 0:
				continue
		var entity_suffix := tool_id if not tool_id.is_empty() else "modifier_%d" % modifier_index
		result.append({
			"trigger_id": "exp_share:%d:%s:%s" % [defeated_idx, target_slot, entity_suffix],
			"kind": "tool_exp_share",
			"owner": defeated_idx,
			"source_player": defeated_idx,
			"source_slot": defeated_slot,
			"source_card_id": knocked_out.card_id,
			"target_player": defeated_idx,
			"target_slot": target_slot,
			"target_card_id": target.card_id,
			"tool_card_id": tool_id,
			"modifier_index": modifier_index,
		})
	return result


func _knockout_cause_for(
	stack: ResolutionStack,
	batch: Dictionary,
	defeated_idx: int,
	defeated_slot: String,
) -> Dictionary:
	var default_source_kind := (
		"attack_damage" if bool(batch.get("from_attack", false))
		else str(stack.context.get("effect_source_kind", "effect"))
	)
	var cause: Dictionary = {
		"source_kind": default_source_kind,
		"cause_kind": "damage" if default_source_kind == "attack_damage" else "effect",
		"source_player": int(batch.get("attack_actor", -1)),
		"cause_detail": "",
	}
	var cause_map_value: Variant = stack.context.get("knockout_causes", {})
	if not cause_map_value is Dictionary:
		return cause
	var cause_map: Dictionary = cause_map_value
	var cause_key := "%d:%s" % [defeated_idx, defeated_slot]
	if not cause_map.has(cause_key):
		return cause
	var cause_value: Variant = cause_map[cause_key]
	if cause_value is Dictionary:
		var explicit_cause: Dictionary = cause_value
		cause["source_kind"] = str(explicit_cause.get(
			"source_kind", cause["source_kind"]))
		cause["cause_kind"] = str(explicit_cause.get(
			"cause_kind",
			"damage" if cause["source_kind"] == "attack_damage" else "effect",
		))
		cause["source_player"] = int(explicit_cause.get(
			"source_player", cause["source_player"]))
		cause["cause_detail"] = explicit_cause.get(
			"cause_details", explicit_cause.get("cause_detail", ""))
	else:
		cause["source_kind"] = str(cause_value)
		cause["cause_kind"] = (
			"damage" if cause["source_kind"] == "attack_damage" else "effect")
	return cause


func _is_opponent_attack_damage(cause: Dictionary, defeated_idx: int) -> bool:
	var source_player := int(cause.get("source_player", -1))
	return (
		str(cause.get("source_kind", "")) == "attack_damage"
		and str(cause.get("cause_kind", "")) == "damage"
		and source_player in [0, 1]
		and source_player != defeated_idx
	)


func _request_next_ko_trigger(
	state: GameState,
	stack: ResolutionStack,
) -> ChoiceRequest:
	var batch: Dictionary = stack.context.get("ko_batch", {})
	var knockouts: Array = batch.get("knockouts", [])
	var trigger_index := int(batch.get("trigger_index", 0))
	if trigger_index < 0 or trigger_index >= knockouts.size():
		return null
	var knockout: Dictionary = knockouts[trigger_index]
	var current: Dictionary = knockout.get("current_trigger", {})
	if not current.is_empty():
		return _request_exp_share_confirmation(state, stack, current)
	var triggers: Array = knockout.get("triggers", [])
	if triggers.is_empty():
		return null
	if triggers.size() == 1:
		current = Dictionary(triggers.pop_front()).duplicate(true)
		knockout["triggers"] = triggers
		knockout["current_trigger"] = current
		knockouts[trigger_index] = knockout
		batch["knockouts"] = knockouts
		stack.context["ko_batch"] = batch
		return _request_exp_share_confirmation(state, stack, current)
	var options: Array[Dictionary] = []
	for trigger_value in triggers:
		var trigger: Dictionary = trigger_value
		var trigger_id := str(trigger.get("trigger_id", ""))
		options.append({
			"option_id": "trigger:%s" % trigger_id,
			"label": "%s上的学习装置" % catalog.card_name(str(trigger.get("target_card_id", ""))),
			"value": {"trigger_id": trigger_id},
		})
	var owner := int(triggers[0].get("owner", -1))
	var frame_id := "knockout:trigger_order:%d" % stack.sequence
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, owner, "choose_trigger_order"),
		"choose_trigger_order",
		owner,
		"请选择下一个要结算的学习装置。",
		options,
		1,
		1,
		false,
		false,
		{
			"domain": "knockout",
			"purpose": "exp_share_trigger_order",
			"revision": state.revision,
			"continuation_frame_id": frame_id,
		},
	)
	state.resolution_stack = stack.to_dict()
	return stack.pending_request


func _request_exp_share_confirmation(
	state: GameState,
	stack: ResolutionStack,
	trigger: Dictionary,
) -> ChoiceRequest:
	var trigger_id := str(trigger.get("trigger_id", ""))
	var owner := int(trigger.get("owner", -1))
	var frame_id := "knockout:trigger_confirm:%d" % stack.sequence
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, owner, "confirm_trigger"),
		"confirm_trigger",
		owner,
		"要发动这张学习装置吗？",
		[{
			"option_id": "trigger:%s" % trigger_id,
			"label": "发动学习装置",
			"value": {"trigger_id": trigger_id},
		}],
		0,
		1,
		false,
		true,
		{
			"domain": "knockout",
			"purpose": "exp_share_confirm",
			"revision": state.revision,
			"continuation_frame_id": frame_id,
			"trigger_id": trigger_id,
		},
	)
	state.resolution_stack = stack.to_dict()
	return stack.pending_request


func _request_exp_share_energy(
	state: GameState,
	stack: ResolutionStack,
	trigger: Dictionary,
) -> ChoiceRequest:
	var source_player := int(trigger.get("source_player", -1))
	var source_slot := str(trigger.get("source_slot", ""))
	var source := state.get_player(source_player).get_pokemon(source_slot)
	if source == null:
		return null
	var options: Array[Dictionary] = []
	for index in range(source.energy_card_ids.size()):
		var energy_id := str(source.energy_card_ids[index])
		if not catalog.is_basic_energy(energy_id):
			continue
		options.append({
			"option_id": "attachment:%d:%s:energy:%d:%s" % [
				source_player, source_slot, index, energy_id],
			"label": catalog.card_name(energy_id),
			"ref": EntityRef.new(
				"attachment", source_player, "field", source_slot, index,
				"energy", energy_id).to_dict(),
			"value": {
				"player": source_player,
				"slot": source_slot,
				"index": index,
				"attachment_type": "energy",
				"card_id": energy_id,
			},
		})
	if options.is_empty():
		return null
	var owner := int(trigger.get("owner", -1))
	var frame_id := "knockout:exp_share_energy:%d" % stack.sequence
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, owner, "select_attachment"),
		"select_attachment",
		owner,
		"选择要移动到学习装置宝可梦上的基础能量。",
		options,
		1,
		1,
		false,
		false,
		{
			"domain": "knockout",
			"purpose": "exp_share_energy",
			"revision": state.revision,
			"continuation_frame_id": frame_id,
			"trigger_id": str(trigger.get("trigger_id", "")),
		},
	)
	state.resolution_stack = stack.to_dict()
	return stack.pending_request


func apply_ko_trigger_choice(
	state: GameState,
	response: ChoiceResponse,
	stack: ResolutionStack,
) -> Dictionary:
	var pending := stack.pending_request
	if pending == null:
		return VMResult.fail("昏厥触发选择已过期。", "stale_choice")
	match str(pending.metadata.get("purpose", "")):
		"exp_share_trigger_order":
			return _apply_exp_share_order_choice(state, response, stack)
		"exp_share_confirm":
			return _apply_exp_share_confirmation(state, response, stack)
		"exp_share_energy":
			return _apply_exp_share_energy_choice(state, response, stack)
	return VMResult.fail("未知的昏厥触发选择。", "unknown_knockout_choice")


func _apply_exp_share_order_choice(
	state: GameState,
	response: ChoiceResponse,
	stack: ResolutionStack,
) -> Dictionary:
	if response.cancelled or response.option_ids.size() != 1:
		return VMResult.fail("必须选择下一个触发。", "choice_count")
	var selected_id := response.option_ids[0].trim_prefix("trigger:")
	var batch: Dictionary = stack.context.get("ko_batch", {})
	var knockouts: Array = batch.get("knockouts", [])
	var trigger_index := int(batch.get("trigger_index", 0))
	if trigger_index < 0 or trigger_index >= knockouts.size():
		return VMResult.fail("昏厥批次已结束。", "stale_choice")
	var knockout: Dictionary = knockouts[trigger_index]
	var triggers: Array = knockout.get("triggers", [])
	var selected_index := -1
	for index in range(triggers.size()):
		if str(triggers[index].get("trigger_id", "")) == selected_id:
			selected_index = index
			break
	if selected_index < 0:
		return VMResult.fail("触发顺序选择无效。", "invalid_choice")
	var trigger: Dictionary = triggers.pop_at(selected_index)
	knockout["triggers"] = triggers
	knockout["current_trigger"] = trigger.duplicate(true)
	knockouts[trigger_index] = knockout
	batch["knockouts"] = knockouts
	stack.context["ko_batch"] = batch
	stack.pending_request = null
	var next_request := _request_exp_share_confirmation(state, stack, trigger)
	var result := VMResult.ok("已选择下一个学习装置。")
	result["pending_choice"] = next_request
	return result


func _apply_exp_share_confirmation(
	state: GameState,
	response: ChoiceResponse,
	stack: ResolutionStack,
) -> Dictionary:
	var trigger := _current_ko_trigger(stack)
	if trigger.is_empty():
		return VMResult.fail("学习装置触发已过期。", "stale_choice")
	if response.option_ids.size() > 1:
		return VMResult.fail("学习装置确认选择无效。", "choice_count")
	var accepted := not response.cancelled and not response.option_ids.is_empty()
	if accepted and response.option_ids[0] != "trigger:%s" % str(trigger.get("trigger_id", "")):
		return VMResult.fail("学习装置确认项无效。", "invalid_choice")
	stack.pending_request = null
	if accepted and _exp_share_trigger_is_live(state, trigger):
		var energy_request := _request_exp_share_energy(state, stack, trigger)
		if energy_request != null:
			var pending_result := VMResult.ok("请选择基础能量。")
			pending_result["pending_choice"] = energy_request
			return pending_result
	_clear_current_ko_trigger(stack)
	var events: Array[Dictionary] = []
	var continued := _continue_knockout_batch(state, stack, events)
	continued["events"] = events
	return continued


func _apply_exp_share_energy_choice(
	state: GameState,
	response: ChoiceResponse,
	stack: ResolutionStack,
) -> Dictionary:
	if response.cancelled or response.option_ids.size() != 1:
		return VMResult.fail("必须选择1张基础能量。", "choice_count")
	var trigger := _current_ko_trigger(stack)
	if trigger.is_empty() or not _exp_share_trigger_is_live(state, trigger):
		return VMResult.fail("学习装置触发已失效。", "stale_choice")
	var selected: Dictionary = {}
	for option in stack.pending_request.options:
		if str(option.get("option_id", "")) == response.option_ids[0]:
			selected = option
			break
	if selected.is_empty() or not selected.get("ref") is Dictionary:
		return VMResult.fail("基础能量选择无效。", "invalid_choice")
	var ref: Dictionary = selected["ref"]
	var source_player := int(trigger.get("source_player", -1))
	var source_slot := str(trigger.get("source_slot", ""))
	var source := state.get_player(source_player).get_pokemon(source_slot)
	var source_index := int(ref.get("index", -1))
	var energy_id := str(ref.get("card_id", ""))
	if (
		source == null
		or str(ref.get("kind", "")) != "attachment"
		or int(ref.get("player", -1)) != source_player
		or str(ref.get("slot", "")) != source_slot
		or str(ref.get("attachment_type", "")) != "energy"
		or source_index < 0
		or source_index >= source.energy_card_ids.size()
		or str(source.energy_card_ids[source_index]) != energy_id
		or not catalog.is_basic_energy(energy_id)
	):
		return VMResult.fail("选择的基础能量已不存在。", "stale_choice")
	var target_player := int(trigger.get("target_player", -1))
	var target_slot := str(trigger.get("target_slot", ""))
	var target := state.get_player(target_player).get_pokemon(target_slot)
	if target == null:
		return VMResult.fail("学习装置宝可梦已不存在。", "stale_choice")
	source.energy_card_ids.remove_at(source_index)
	var target_index := target.energy_card_ids.size()
	target.energy_card_ids.append(energy_id)
	var events: Array[Dictionary] = [{
		"event_type": "energy_attached",
		"actor": target_player,
		"card_id": energy_id,
		"source": {
			"player": source_player,
			"slot": source_slot,
			"attachment_type": "energy",
			"index": source_index,
		},
		"target": {
			"player": target_player,
			"slot": target_slot,
			"attachment_type": "energy",
			"index": target_index,
		},
		"data": {
			"player": target_player,
			"slot": target_slot,
			"card_id": energy_id,
			"presentation_phase": "knockout",
			"source": "exp_share",
			"source_player": source_player,
			"source_slot": source_slot,
			"source_index": source_index,
			"target_player": target_player,
			"target_slot": target_slot,
			"target_index": target_index,
		},
	}]
	stack.pending_request = null
	_clear_current_ko_trigger(stack)
	var continued := _continue_knockout_batch(state, stack, events)
	continued["events"] = events
	return continued


func _current_ko_trigger(stack: ResolutionStack) -> Dictionary:
	var batch: Dictionary = stack.context.get("ko_batch", {})
	var knockouts: Array = batch.get("knockouts", [])
	var trigger_index := int(batch.get("trigger_index", 0))
	if trigger_index < 0 or trigger_index >= knockouts.size():
		return {}
	return Dictionary(knockouts[trigger_index].get("current_trigger", {})).duplicate(true)


func _clear_current_ko_trigger(stack: ResolutionStack) -> void:
	var batch: Dictionary = stack.context.get("ko_batch", {})
	var knockouts: Array = batch.get("knockouts", [])
	var trigger_index := int(batch.get("trigger_index", 0))
	if trigger_index < 0 or trigger_index >= knockouts.size():
		return
	var knockout: Dictionary = knockouts[trigger_index]
	knockout["current_trigger"] = {}
	knockouts[trigger_index] = knockout
	batch["knockouts"] = knockouts
	stack.context["ko_batch"] = batch


func _exp_share_trigger_is_live(state: GameState, trigger: Dictionary) -> bool:
	var source := state.get_player(int(trigger.get("source_player", -1))).get_pokemon(
		str(trigger.get("source_slot", "")))
	var target := state.get_player(int(trigger.get("target_player", -1))).get_pokemon(
		str(trigger.get("target_slot", "")))
	if (
		source == null
		or target == null
		or source.card_id != str(trigger.get("source_card_id", ""))
		or target.card_id != str(trigger.get("target_card_id", ""))
	):
		return false
	var tool_id := str(trigger.get("tool_card_id", ""))
	if not tool_id.is_empty():
		return target.attached_tool_id == tool_id and trigger_command_runner.tool_has_effect(
			tool_id, "tool_exp_share")
	var modifier_index := int(trigger.get("modifier_index", -1))
	return (
		modifier_index >= 0
		and modifier_index < target.modifiers.size()
		and str(target.modifiers[modifier_index].get(
			"modifier_kind", target.modifiers[modifier_index].get("effect_type", ""))) == "tool_exp_share"
	)


func _finalize_current_knockout(
	state: GameState,
	stack: ResolutionStack,
	events: Array[Dictionary],
) -> void:
	var batch: Dictionary = stack.context.get("ko_batch", {})
	var knockouts: Array = batch.get("knockouts", [])
	if knockouts.is_empty():
		return
	var knockout: Dictionary = knockouts[0]
	var defeated_idx := int(knockout.get("player", -1))
	var defeated_slot := str(knockout.get("slot", ""))
	var defeated_player := state.get_player(defeated_idx)
	var knocked_out := defeated_player.get_pokemon(defeated_slot)
	if knocked_out == null:
		knockouts.pop_front()
		batch["knockouts"] = knockouts
		stack.context["ko_batch"] = batch
		return
	var source_index := (
		defeated_slot.trim_prefix("bench_").to_int()
		if defeated_slot.begins_with("bench_")
		else 0
	)
	var discard_index := defeated_player.discard.size()
	var discarded_card_ids: Array[String] = [knocked_out.card_id]
	discarded_card_ids.append_array(knocked_out.evolution_stack_ids)
	if not knocked_out.attached_tool_id.is_empty():
		discarded_card_ids.append(knocked_out.attached_tool_id)
	discarded_card_ids.append_array(knocked_out.energy_card_ids)
	var cause: Dictionary = knockout.get("cause", {})
	if cause.is_empty():
		cause = _knockout_cause_for(stack, batch, defeated_idx, defeated_slot)
	var source_kind := str(cause.get("source_kind", "effect"))
	var cause_kind := str(cause.get("cause_kind", "effect"))
	var source_player := int(cause.get("source_player", -1))
	var cause_detail: Variant = cause.get("cause_detail", "")
	state.record_knockout({
		"defeated_player": defeated_idx,
		"slot": defeated_slot,
		"card_id": knocked_out.card_id,
		"source_player": source_player,
		"source_kind": source_kind,
		"cause_kind": cause_kind,
		"cause_detail": cause_detail,
		"turn": state.turn_number,
	})
	state.discard_pokemon(defeated_idx, defeated_slot)
	events.append({
		"event_type": "card_moved",
		"actor": int(batch.get("attack_actor", -1)),
		"card_id": str(knockout.get("card_id", "")),
		"source": {
			"player": defeated_idx,
			"slot": defeated_slot,
			"index": source_index,
		},
		"target": {
			"player": defeated_idx,
			"zone": "discard",
			"index": discard_index,
		},
		"amount": discarded_card_ids.size(),
		"data": knockout.merged({
			"cause": "pokemon_ko",
			"ko_leave_play": true,
			"presentation_phase": "knockout",
			"count": discarded_card_ids.size(),
			"card_ids": discarded_card_ids,
		}, true),
	})
	var winner_idx := 1 - defeated_idx
	var prize_count := mini(
		int(knockout.get("prizes", 1)), state.get_player(winner_idx).prizes.size())
	if prize_count > 0:
		var prize_awards: Array = batch.get("prize_awards", [])
		prize_awards.append({
			"player": winner_idx,
			"remaining": prize_count,
			"defeated_player": defeated_idx,
			"defeated_card_id": str(knockout.get("card_id", "")),
		})
		batch["prize_awards"] = prize_awards
	if _is_opponent_attack_damage(cause, defeated_idx):
		defeated_player.was_ko_by_attack = true
	knockouts.pop_front()
	batch["knockouts"] = knockouts
	stack.context["ko_batch"] = batch


func request_next_prize(
	state: GameState,
	stack: ResolutionStack,
) -> ChoiceRequest:
	var awards: Array = stack.context.get("prize_awards", [])
	while not awards.is_empty():
		var award: Dictionary = awards[0]
		var player_idx := int(award.get("player", -1))
		if (
			player_idx in [0, 1]
			and int(award.get("remaining", 0)) > 0
			and not state.get_player(player_idx).prizes.is_empty()
		):
			break
		awards.pop_front()
	stack.context["prize_awards"] = awards
	if awards.is_empty():
		stack.pending_request = null
		state.resolution_stack = stack.to_dict()
		return null
	var award: Dictionary = awards[0]
	var player_idx := int(award["player"])
	var options: Array[Dictionary] = []
	for index in range(state.get_player(player_idx).prizes.size()):
		options.append({
			"option_id": "prize:%d" % index,
			"label": "奖赏卡 %d" % (index + 1),
			"value": {"index": index},
		})
	var frame_id := "knockout:prize:%d" % stack.sequence
	stack.push_continuation("select_prize", {
		"kind": "select_prize",
		"frame_id": frame_id,
		"player_idx": player_idx,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "select_prize"),
		"select_prize",
		player_idx,
		"请选择1张奖赏卡。",
		options,
		1,
		1,
		false,
		false,
		{
			"domain": "knockout",
			"purpose": "select_prize",
			"revision": state.revision,
			"continuation_frame_id": frame_id,
			"remaining": int(award.get("remaining", 0)),
		},
	)
	state.resolution_stack = stack.to_dict()
	return stack.pending_request


func apply_prize_choice(
	state: GameState,
	request: ChoiceRequest,
	response: ChoiceResponse,
	stack: ResolutionStack,
) -> Dictionary:
	if response.cancelled or response.option_ids.size() != 1:
		return VMResult.fail("必须选择1张奖赏卡。", "choice_count")
	var option_id := response.option_ids[0]
	if not option_id.begins_with("prize:"):
		return VMResult.fail("奖赏卡选择无效。", "invalid_choice")
	var awards: Array = stack.context.get("prize_awards", [])
	if awards.is_empty():
		return VMResult.fail("没有待领取的奖赏卡。", "stale_choice")
	var award: Dictionary = awards[0]
	var player_idx := int(award.get("player", -1))
	var player := state.get_player(player_idx)
	var source_index := option_id.trim_prefix("prize:").to_int()
	if source_index < 0 or source_index >= player.prizes.size():
		return VMResult.fail("选择的奖赏卡已不存在。", "stale_choice")
	_pop_knockout_choice_frame(stack, "select_prize")
	var card_id := str(player.prizes[source_index])
	if card_id == "svi-trea":
		# Treasure Energy resolves while the exact card is still in the Prize zone.
		# Keeping the entity anchored here makes every pause/snapshot authoritative:
		# declining moves it to the hand, accepting moves it directly to a Pokemon.
		stack.context["pending_treasure_energy"] = {
			"player": player_idx,
			"prize_index": source_index,
			"card_id": card_id,
		}
		stack.pending_request = null
		var treasure_request := request_treasure_energy_attachment(state, stack)
		var treasure_result := VMResult.ok("宝藏能量触发等待结算。")
		treasure_result["events"] = []
		treasure_result["pending_choice"] = treasure_request
		treasure_result["finished"] = false
		return treasure_result
	var hand_index := player.hand.size()
	card_id = player.take_prize(source_index)
	_consume_current_prize_award(stack)
	stack.pending_request = null
	var result := VMResult.ok("领取了1张奖赏卡。")
	result["events"] = [{
		"event_type": "prize_taken",
		"actor": player_idx,
		"visibility": "owner",
		"card_id": card_id,
		"source": {"player": player_idx, "zone": "prizes", "index": source_index},
		"target": {"player": player_idx, "zone": "hand", "index": hand_index},
		"data": {
			"player": player_idx,
			"count": 1,
			"card_id": card_id,
			"source_index": source_index,
			"target_index": hand_index,
		},
	}]
	var next_request := request_next_prize(state, stack)
	result["pending_choice"] = next_request
	result["finished"] = next_request == null
	return result


func request_treasure_energy_attachment(
	state: GameState,
	stack: ResolutionStack,
) -> ChoiceRequest:
	var pending: Dictionary = stack.context.get("pending_treasure_energy", {})
	var player_idx := int(pending.get("player", -1))
	if player_idx not in [0, 1]:
		return request_next_prize(state, stack)
	var options: Array[Dictionary] = []
	for row in state.get_player(player_idx).get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var slot := str(row["slot"])
		options.append({
			"option_id": "pokemon:%d:%s:%s" % [player_idx, slot, pokemon.card_id],
			"label": catalog.card_name(pokemon.card_id),
			"value": {"player": player_idx, "slot": slot, "card_id": pokemon.card_id},
		})
	var frame_id := "knockout:treasure:%d" % stack.sequence
	stack.push_continuation("treasure_energy_attach", {
		"kind": "treasure_energy_attach",
		"frame_id": frame_id,
		"player_idx": player_idx,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "confirm_trigger"),
		"confirm_trigger",
		player_idx,
		"可以将宝藏能量附于自己的1只宝可梦。",
		options,
		0,
		1,
		false,
		true,
		{
			"domain": "knockout",
			"purpose": "treasure_energy_attach",
			"revision": state.revision,
			"continuation_frame_id": frame_id,
		},
	)
	state.resolution_stack = stack.to_dict()
	return stack.pending_request


func apply_treasure_energy_choice(
	state: GameState,
	response: ChoiceResponse,
	stack: ResolutionStack,
) -> Dictionary:
	var pending: Dictionary = stack.context.get("pending_treasure_energy", {})
	var player_idx := int(pending.get("player", -1))
	if player_idx not in [0, 1]:
		return VMResult.fail("宝藏能量触发已过期。", "stale_choice")
	var player := state.get_player(player_idx)
	var prize_index := int(pending.get("prize_index", -1))
	var expected_id := str(pending.get("card_id", ""))
	if (
		prize_index < 0
		or prize_index >= player.prizes.size()
		or str(player.prizes[prize_index]) != expected_id
		or expected_id != "svi-trea"
	):
		return VMResult.fail("宝藏能量奖赏卡已变化。", "stale_choice")
	if response.option_ids.size() > 1:
		return VMResult.fail("宝藏能量最多选择1个目标。", "choice_count")
	var events: Array[Dictionary] = []
	var accepted := not response.cancelled and not response.option_ids.is_empty()
	var selected_slot := ""
	var selected_target: PokemonState = null
	if not response.cancelled and not response.option_ids.is_empty():
		var option_id := response.option_ids[0]
		var selected_option: Dictionary = {}
		if stack.pending_request != null:
			for option in stack.pending_request.options:
				if str(option.get("option_id", "")) == option_id:
					selected_option = option
					break
		if selected_option.is_empty():
			return VMResult.fail("宝藏能量目标无效。", "invalid_choice")
		selected_slot = str(selected_option.get("value", {}).get("slot", ""))
		selected_target = player.get_pokemon(selected_slot)
		if (
			selected_target == null
			or selected_target.card_id
			!= str(selected_option.get("value", {}).get("card_id", ""))
		):
			return VMResult.fail("宝藏能量或目标已变化。", "stale_choice")
	var card_id := str(player.prizes.pop_at(prize_index))
	if accepted:
		# The authoritative entity moves Prize -> Pokemon directly. Presentation
		# retains the familiar Prize -> Hand -> Pokemon motion as one atomic event
		# group; no intervening state or action window ever exposes it in hand.
		var hand_index := player.hand.size()
		var target_index := selected_target.energy_card_ids.size()
		selected_target.energy_card_ids.append(card_id)
		events.append({
			"event_type": "prize_taken",
			"actor": player_idx,
			"visibility": "public",
			"card_id": card_id,
			"source": {"player": player_idx, "zone": "prizes", "index": prize_index},
			"target": {"player": player_idx, "zone": "hand", "index": hand_index},
			"data": {
				"player": player_idx,
				"count": 1,
				"card_id": card_id,
				"source_index": prize_index,
				"target_index": hand_index,
			},
		})
		events.append({
			"event_type": "energy_attached",
			"actor": player_idx,
			"card_id": card_id,
			"source": {"player": player_idx, "zone": "hand", "index": hand_index},
			"target": {"player": player_idx, "slot": selected_slot, "index": target_index},
			"data": {
				"player": player_idx,
				"slot": selected_slot,
				"card_id": card_id,
				"source": "prize_trigger",
			},
		})
	else:
		var hand_index := player.hand.size()
		player.hand.append(card_id)
		events.append({
			"event_type": "prize_taken",
			"actor": player_idx,
			"visibility": "owner",
			"card_id": card_id,
			"source": {"player": player_idx, "zone": "prizes", "index": prize_index},
			"target": {"player": player_idx, "zone": "hand", "index": hand_index},
			"data": {
				"player": player_idx,
				"count": 1,
				"card_id": card_id,
				"source_index": prize_index,
				"target_index": hand_index,
			},
		})
	_consume_current_prize_award(stack)
	_pop_knockout_choice_frame(stack, "treasure_energy_attach")
	stack.context.erase("pending_treasure_energy")
	stack.pending_request = null
	var next_request := request_next_prize(state, stack)
	var result := VMResult.ok("宝藏能量触发已结算。")
	result["events"] = events
	result["pending_choice"] = next_request
	result["finished"] = next_request == null
	return result


func _consume_current_prize_award(stack: ResolutionStack) -> void:
	var awards: Array = stack.context.get("prize_awards", [])
	if awards.is_empty():
		return
	var award: Dictionary = awards[0]
	award["remaining"] = int(award.get("remaining", 0)) - 1
	if int(award["remaining"]) <= 0:
		awards.pop_front()
	else:
		awards[0] = award
	stack.context["prize_awards"] = awards


func resolve_empty_boards_and_promotions(state: GameState) -> void:
	queue_empty_board_promotions(state)
	var result := validator.evaluate_result(state)
	var status := str(result.get("status", GameState.RESULT_ONGOING))
	if status == GameState.RESULT_WIN:
		state.set_win(
			int(result.get("winner", -1)), "knockout", result.get("conditions", [[], []]))
	elif status == GameState.RESULT_DRAW:
		state.set_draw("simultaneous_win_conditions", result.get("conditions", [[], []]))
	if state.is_terminal():
		# A terminal batch cannot also wait for promotion.  The winner is only
		# decided after every simultaneous KO and prize has settled, so any
		# provisional promotion rows computed above are now stale.
		state.pending_promotions.clear()


func queue_empty_board_promotions(state: GameState) -> void:
	var turn_order: Array[int] = [1 - state.active_player_idx, state.active_player_idx]
	var ordered_pending: Array[int] = []
	for player_idx in turn_order:
		var player := state.get_player(player_idx)
		if (
			player.active == null
			and player.bench_count() > 0
		):
			ordered_pending.append(player_idx)
	state.pending_promotions.assign(ordered_pending)


func _pop_knockout_choice_frame(stack: ResolutionStack, operation: String) -> void:
	if stack.frames.is_empty():
		return
	var frame: Dictionary = stack.frames[-1]
	if (
		str(frame.get("kind", "")) == "continuation"
		and str(frame.get("operation", "")) == operation
	):
		stack.pop_frame()


func append_game_over_event(
	events: Array[Dictionary],
	state: GameState,
) -> void:
	# Settlement may be reached through action, choice, attack, or checkup
	# wrappers.  Normalize any pre-existing terminal marker so this batch exposes
	# exactly one, in the only causally valid position after all prize events.
	for index in range(events.size() - 1, -1, -1):
		if str(events[index].get("event_type", "")) == "game_over":
			events.remove_at(index)
	events.append({
		"event_type": "game_over",
		"actor": state.winner,
		"data": {
			"result_status": state.result_status,
			"winner": state.winner,
			"loser": 1 - state.winner if state.winner >= 0 else -1,
			"reason": state.result_reason,
			"conditions": state.result_conditions.duplicate(true),
		},
	})
