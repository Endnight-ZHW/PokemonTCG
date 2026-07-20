class_name VMKnockoutSettlement
extends RefCounted

var catalog: CardCatalog
var validator: RulesValidator
var trigger_command_runner: VMTriggerCommands
var effect_engine: EffectEngine


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
		effect_engine = EffectEngine.new(catalog)
		trigger_command_runner = effect_engine.trigger_commands()


func resolve_knockouts(
	state: GameState,
	attack_actor: int,
	events: Array[Dictionary],
	from_attack: bool,
	active_stack: ResolutionStack = null,
	rng: PortableRandomSource = null,
) -> Dictionary:
	# Engine-owned settlement always supplies a stack so every Prize card remains
	# an explicit player choice.  Keep the historical low-level ATTACK entry point
	# synchronous for presentation/event consumers that have no choice dispatcher;
	# it still runs through the same prize-choice implementation below.
	var settle_synchronously := active_stack == null and state.phase == "ATTACK"
	var stack := active_stack if active_stack != null else ResolutionStack.new()
	if stack.context.get("ko_batch") is Dictionary:
		var continued := _continue_knockout_batch(state, stack, events, rng)
		return (
			_settle_synchronous_prize_choices(state, stack, events, continued, rng)
			if settle_synchronously
			else continued
		)
	var knockouts: Array[Dictionary] = []
	for player_idx in [0, 1]:
		var player := state.get_player(player_idx)
		_append_knockout_candidate(knockouts, player.active, player_idx, "active")
		for bench_idx in range(player.bench.size()):
			var pokemon: PokemonState = player.bench[bench_idx]
			if pokemon != null:
				_append_knockout_candidate(
					knockouts, pokemon, player_idx, "bench_%d" % bench_idx)
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
	var result := _continue_knockout_batch(state, stack, events, rng)
	return (
		_settle_synchronous_prize_choices(state, stack, events, result, rng)
		if settle_synchronously
		else result
	)


func _append_knockout_candidate(
	knockouts: Array[Dictionary],
	pokemon: PokemonState,
	player_idx: int,
	slot: String,
) -> void:
	if pokemon == null or not pokemon.is_knocked_out(catalog):
		return
	knockouts.append({
		"player": player_idx,
		"slot": slot,
		"card_id": pokemon.card_id,
		"prizes": catalog.prize_value(pokemon.card_id),
		"stage": "declare",
	})


func _settle_synchronous_prize_choices(
	state: GameState,
	stack: ResolutionStack,
	events: Array[Dictionary],
	initial_result: Dictionary,
	rng: PortableRandomSource = null,
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
				rng,
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
	rng: PortableRandomSource = null,
) -> Dictionary:
	var batch: Dictionary = stack.context.get("ko_batch", {})
	var knockouts: Array = batch.get("knockouts", [])
	var stage := str(batch.get("stage", "declare"))
	if stage == "declare":
		# KO checks are a batch barrier. Announce every Pokemon and collect every
		# optional trigger against the same complete pre-discard board before any
		# trigger can pause settlement or any Pokemon can leave play.
		var live_knockouts: Array = []
		var trigger_candidates: Array[Dictionary] = []
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
			trigger_command_runner.collect_pokemon_ko_triggers(
				state,
				defeated_idx,
				defeated_slot,
				knocked_out,
				_is_opponent_attack_damage(knockout_cause, defeated_idx),
				int(knockout_cause.get("source_player", -1)),
				trigger_candidates,
			)
			live_knockouts.append(knockout)
		knockouts = live_knockouts
		batch["knockouts"] = knockouts
		batch["trigger_candidates"] = trigger_candidates
		batch["stage"] = "trigger_schedule"
		stack.context["ko_batch"] = batch
		stage = "trigger_schedule"

	if stage == "trigger_schedule":
		var trigger_candidates: Array[Dictionary] = []
		trigger_candidates.assign(batch.get("trigger_candidates", []))
		if not trigger_candidates.is_empty():
			if effect_engine == null:
				return VMResult.fail("KO触发缺少VM解释器。", "missing_effect_engine")
			var order_player := state.active_player_idx
			var order_policy := "apnap"
			if bool(stack.context.get("finish_end_turn_after_knockouts", false)):
				order_player = 1 - int(stack.context.get(
					"end_turn_actor", state.active_player_idx))
				order_policy = "incoming_first"
			var queued := trigger_command_runner.queue_candidates(
				stack,
				trigger_candidates,
				VMModifierManager.POKEMON_KO,
				order_player,
				order_policy,
				"knockout",
			)
			if not bool(queued.get("success", false)):
				return queued
			batch["stage"] = "trigger_resolving"
			stack.context["ko_batch"] = batch
			var trigger_rng := rng if rng != null else PortableRandomSource.new(0)
			var trigger_step := effect_engine.resolve(state, stack, trigger_rng)
			events.append_array(trigger_step.events)
			if not trigger_step.success:
				return VMResult.fail(trigger_step.message, trigger_step.error_code)
			if trigger_step.pending_choice != null:
				var pending_trigger := VMResult.ok(trigger_step.message)
				pending_trigger["pending_choice"] = trigger_step.pending_choice
				return pending_trigger
		batch = stack.context.get("ko_batch", {})
		batch["stage"] = "discard"
		stack.context["ko_batch"] = batch
		stage = "discard"

	if stage == "trigger_resolving":
		return VMResult.fail("KO触发仍在等待续体。", "missing_choice")

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


func apply_ko_trigger_choice(
	state: GameState,
	response: ChoiceResponse,
	stack: ResolutionStack,
	rng: PortableRandomSource = null,
) -> Dictionary:
	var pending := stack.pending_request
	if pending == null:
		return VMResult.fail("昏厥触发选择已过期。", "stale_choice")
	if effect_engine == null:
		return VMResult.fail("KO触发缺少VM解释器。", "missing_effect_engine")
	var trigger_rng := rng if rng != null else PortableRandomSource.new(0)
	var step := effect_engine.apply_choice(state, stack, response, trigger_rng)
	if not step.success:
		return VMResult.fail(step.message, step.error_code)
	var events: Array[Dictionary] = []
	events.append_array(step.events)
	if step.pending_choice != null:
		var pending_result := VMResult.ok(step.message)
		pending_result["events"] = events
		pending_result["pending_choice"] = step.pending_choice
		return pending_result
	if stack.has_finalize_prize_revealed_frame():
		var finalized_prize := _complete_prize_revealed(state, stack)
		if not bool(finalized_prize.get("success", false)):
			return finalized_prize
		events.append_array(finalized_prize.get("events", []))
		finalized_prize["events"] = events
		return finalized_prize
	var batch: Dictionary = stack.context.get("ko_batch", {})
	if str(batch.get("stage", "")) != "trigger_resolving":
		return VMResult.fail("KO触发批状态无效。", "invalid_trigger_batch")
	batch["stage"] = "discard"
	stack.context["ko_batch"] = batch
	var continued := _continue_knockout_batch(state, stack, events, trigger_rng)
	continued["events"] = events
	return continued


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
	rng: PortableRandomSource = null,
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
	var trigger_candidates: Array[Dictionary] = []
	var collected := trigger_command_runner.collect_on_prize_revealed_triggers(
		card_id, player_idx, source_index, trigger_candidates)
	if not bool(collected.get("success", false)):
		return collected
	if not trigger_candidates.is_empty():
		if effect_engine == null:
			return VMResult.fail("奖赏卡触发缺少VM解释器。", "missing_effect_engine")
		var source_ref := EntityRef.new(
			"card", player_idx, "prizes", "", source_index, "", card_id).to_dict()
		stack.push_finalize_prize_revealed(source_ref)
		if not stack.validation_error.is_empty():
			return stack.validation_result()
		var queued := trigger_command_runner.queue_candidates(
			stack,
			trigger_candidates,
			"ON_PRIZE_REVEALED",
			state.active_player_idx,
			"apnap",
			"knockout",
		)
		if not bool(queued.get("success", false)):
			return queued
		stack.pending_request = null
		var trigger_rng := rng if rng != null else PortableRandomSource.new(0)
		var step := effect_engine.resolve(state, stack, trigger_rng)
		if not step.success:
			return VMResult.fail(step.message, step.error_code)
		var trigger_result := VMResult.ok(step.message)
		trigger_result["events"] = step.events
		if step.pending_choice != null:
			trigger_result["pending_choice"] = step.pending_choice
			trigger_result["finished"] = false
			return trigger_result
		var finalized := _complete_prize_revealed(state, stack)
		if not bool(finalized.get("success", false)):
			return finalized
		var finalized_events: Array[Dictionary] = []
		finalized_events.append_array(step.events)
		finalized_events.append_array(finalized.get("events", []))
		finalized["events"] = finalized_events
		return finalized
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


func _complete_prize_revealed(
	state: GameState,
	stack: ResolutionStack,
) -> Dictionary:
	var data := stack.pop_finalize_prize_revealed()
	var source_ref_value: Variant = data.get("source_ref", {})
	if not source_ref_value is Dictionary:
		return VMResult.fail("奖赏卡触发收口帧无效。", "invalid_stack_barrier")
	var source_ref: Dictionary = source_ref_value
	var player_idx := int(source_ref.get("player", -1))
	var prize_index := int(source_ref.get("index", -1))
	var card_id := str(source_ref.get("card_id", ""))
	if (
		str(source_ref.get("kind", "")) != "card"
		or str(source_ref.get("zone", "")) != "prizes"
		or player_idx not in [0, 1]
		or prize_index < 0
	):
		return VMResult.fail("奖赏卡触发来源引用无效。", "invalid_trigger_ref")
	var player := state.get_player(player_idx)
	var resolved: Dictionary = stack.context.get("resolved_prize_reveals", {})
	var resolved_key := VMEnergyCommands._prize_ref_key(player_idx, prize_index, card_id)
	var was_attached := str(resolved.get(resolved_key, "")) == "attached"
	var events: Array[Dictionary] = []
	if was_attached:
		resolved.erase(resolved_key)
		if resolved.is_empty():
			stack.context.erase("resolved_prize_reveals")
		else:
			stack.context["resolved_prize_reveals"] = resolved
	elif (
		prize_index >= player.prizes.size()
		or str(player.prizes[prize_index]) != card_id
	):
		return VMResult.fail("奖赏卡触发来源已变化。", "stale_choice")
	else:
		var hand_index := player.hand.size()
		player.hand.append(str(player.prizes.pop_at(prize_index)))
		events.append({
			"event_type": "prize_taken",
			"actor": player_idx,
			"visibility": "owner",
			"card_id": card_id,
			"source": {"player": player_idx, "zone": "prizes", "index": prize_index},
			"target": {"player": player_idx, "zone": "hand", "index": hand_index},
			"data": {
				"player": player_idx, "count": 1, "card_id": card_id,
				"source_index": prize_index, "target_index": hand_index,
			},
		})
	_consume_current_prize_award(stack)
	stack.pending_request = null
	var next_request := request_next_prize(state, stack)
	var result := VMResult.ok("奖赏卡触发已结算。")
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
