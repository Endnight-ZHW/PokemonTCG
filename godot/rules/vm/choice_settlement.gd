class_name VMChoiceSettlement
extends RefCounted

var effect_engine: EffectEngine
var attack_settlement: VMAttackSettlement
var knockout_settlement: VMKnockoutSettlement
var transaction_manager: VMTransactionManager


func _init(
	p_effect_engine: EffectEngine,
	p_attack_settlement: VMAttackSettlement,
	p_knockout_settlement: VMKnockoutSettlement,
	p_transaction_manager: VMTransactionManager,
) -> void:
	effect_engine = p_effect_engine
	attack_settlement = p_attack_settlement
	knockout_settlement = p_knockout_settlement
	transaction_manager = p_transaction_manager


func apply_choice(
	state: GameState,
	request: ChoiceRequest,
	response: ChoiceResponse,
	rng: PortableRandomSource,
) -> StepResult:
	var stack := ResolutionStack.from_dict(state.resolution_stack)
	if stack.pending_request == null:
		return _error("当前没有待处理选择。", "stale_choice", state)
	if stack.pending_request.request_id != request.request_id:
		return _error("选择请求已过期。", "stale_choice", state)
	if int(request.metadata.get("revision", state.revision)) != state.revision:
		return _error("局面已变化，选择请求已过期。", "stale_choice", state)
	var cancel_checkpoint := transaction_manager.cancel_action_checkpoint(stack)
	if response.cancelled and request.can_cancel and not cancel_checkpoint.is_empty():
		var rollback_event := transaction_manager.cancelled_trainer_return_event(
			stack, request.player)
		var cancelled_step := transaction_manager.restore_cancelled_action(
			state, rng, cancel_checkpoint)
		if not rollback_event.is_empty():
			cancelled_step.events.append(rollback_event)
		return cancelled_step
	var checkpoint := transaction_manager.capture_transaction(state, rng)
	state.revision += 1
	var step := effect_engine.apply_choice(state, stack, response, rng)
	if not step.success:
		return transaction_manager.rollback_failed_step(state, rng, checkpoint, step)
	var has_deferred_public_events := not transaction_manager.deferred_public_events(
		stack).is_empty()
	if has_deferred_public_events and step.pending_choice != null:
		step.pending_choice.metadata["cancels_action"] = true
		if stack.pending_request != null:
			stack.pending_request.metadata["cancels_action"] = true
		transaction_manager.append_deferred_public_events(
			stack, step.events, state.revision)
		state.resolution_stack = stack.to_dict()
	if step.pending_choice == null and stack.has_finalize_attack_frame():
		step = attack_settlement.merge_attack_presentation(
			step,
			attack_settlement.complete_attack_context(state, stack, rng),
		)
	elif step.pending_choice == null:
		var ko_result := knockout_settlement.resolve_knockouts(
			state, request.player, step.events, false, stack)
		if not bool(ko_result.get("success", false)):
			return transaction_manager.rollback_failed_step(
				state,
				rng,
				checkpoint,
				StepResult.new(
					false,
					str(ko_result.get("message", "触发命令结算失败。")),
					null,
					step.events,
					state.winner,
					false,
					str(ko_result.get("error_code", "trigger_command_failed")),
				),
			)
		var prize_request: Variant = ko_result.get("pending_choice", null)
		if prize_request is ChoiceRequest:
			step.pending_choice = prize_request
		else:
			# Choice-driven effects may remove their own last Pokemon.  Evaluate only
			# after target KOs have completed, and never before a Prize choice pauses.
			knockout_settlement.resolve_empty_boards_and_promotions(state)
			if state.is_terminal():
				knockout_settlement.append_game_over_event(step.events, state)
				state.resolution_stack = ResolutionStack.new().to_dict()
	if step.pending_choice != null and bool(stack.context.get("finish_attack", false)):
		var attack_actor := int(stack.context.get("actor", request.player))
		step.pending_choice.metadata["finish_attack_actor"] = attack_actor
		if stack.pending_request != null:
			stack.pending_request.metadata["finish_attack_actor"] = attack_actor
		state.resolution_stack = stack.to_dict()
	if step.pending_choice == null and has_deferred_public_events:
		var committed_events := transaction_manager.deferred_public_events(stack)
		transaction_manager.clear_deferred_public_events(stack)
		step.events = committed_events + step.events
		state.resolution_stack = stack.to_dict()
	step.winner = state.winner
	step.terminal = state.is_terminal()
	if not step.success:
		return transaction_manager.rollback_failed_step(state, rng, checkpoint, step)
	return step


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


func _error(
	message: String,
	code: String,
	state: GameState,
) -> StepResult:
	return StepResult.new(false, message, null, [], state.winner, false, code)
