class_name VMActionSettlement
extends RefCounted

var knockout_settlement: VMKnockoutSettlement
var transaction_manager: VMTransactionManager


func _init(
	p_knockout_settlement: VMKnockoutSettlement,
	p_transaction_manager: VMTransactionManager,
) -> void:
	knockout_settlement = p_knockout_settlement
	transaction_manager = p_transaction_manager


func apply_action(
	state: GameState,
	action: GameAction,
	actor: int,
	rng: PortableRandomSource,
	dispatch_action: Callable,
	disposable_state: bool = false,
) -> StepResult:
	# Beam-search children are private clones that are discarded immediately when
	# settlement fails.  They do not need a full rollback snapshot unless the
	# successful action may expose a cancellable continuation whose later Choice
	# must restore the pre-action state.
	var needs_cancel_checkpoint := action.action in ["PLAY_TRAINER", "RETREAT"]
	var checkpoint := (
		transaction_manager.capture_transaction(state, rng)
		if not disposable_state or needs_cancel_checkpoint
		else {}
	)
	var pre_action_phase := state.phase
	var pre_action_winner := state.winner
	var pre_action_terminal := state.is_terminal()
	state.revision += 1
	var result: StepResult = dispatch_action.call(state, action, actor, rng)
	if not result.success:
		return (
			transaction_manager.rollback_failed_step(
				state, rng, checkpoint, result)
			if not checkpoint.is_empty()
			else _discardable_failed_step(
				result, pre_action_winner, pre_action_terminal)
		)
	if result.pending_choice != null and action.action == "DECLARE_ATTACK":
		var attack_stack := ResolutionStack.from_dict(state.resolution_stack)
		_mark_attack_pending_choice(result.pending_choice, attack_stack, actor)
		if attack_stack.pending_request != null:
			_mark_attack_pending_choice(attack_stack.pending_request, attack_stack, actor)
			state.resolution_stack = attack_stack.to_dict()
	if (
		result.pending_choice == null
		and action.action not in ["DECLARE_ATTACK", "END_TURN"]
		and pre_action_phase != "SETUP"
	):
		var ko_stack := ResolutionStack.from_dict(state.resolution_stack)
		var ko_result := knockout_settlement.resolve_knockouts(
			state, actor, result.events, false, ko_stack, rng)
		if not bool(ko_result.get("success", false)):
			var failed_step := StepResult.new(
				false,
				str(ko_result.get("message", "触发命令结算失败。")),
				null,
				result.events,
				state.winner,
				false,
				str(ko_result.get("error_code", "trigger_command_failed")),
			)
			return (
				transaction_manager.rollback_failed_step(
					state, rng, checkpoint, failed_step)
				if not checkpoint.is_empty()
				else _discardable_failed_step(
					failed_step, pre_action_winner, pre_action_terminal)
			)
		var prize_request: Variant = ko_result.get("pending_choice", null)
		if prize_request is ChoiceRequest:
			result.pending_choice = prize_request
		else:
			# Some effects remove their source from play without creating a KO row.
			# Result evaluation belongs after the complete KO/prize batch, not inside
			# the effect continuation that performed the removal.
			knockout_settlement.resolve_empty_boards_and_promotions(state)
			if state.is_terminal():
				knockout_settlement.append_game_over_event(result.events, state)
				state.resolution_stack = ResolutionStack.new().to_dict()
	if (
		result.pending_choice
		and result.pending_choice.can_cancel
		and action.action in ["PLAY_TRAINER", "RETREAT"]
	):
		var cancellable_stack := ResolutionStack.from_dict(state.resolution_stack)
		result.pending_choice.metadata["cancels_action"] = true
		if cancellable_stack.pending_request != null:
			cancellable_stack.pending_request.metadata["cancels_action"] = true
		# The chooser may see the optimistic play immediately, but opponents must
		# not learn it until the cancellable multi-step transaction commits. Fixed
		# IDs let the chooser harmlessly de-duplicate the committed replay.
		transaction_manager.append_deferred_public_events(
			cancellable_stack, result.events, state.revision)
		transaction_manager.store_cancel_action_checkpoint(cancellable_stack, checkpoint)
		state.resolution_stack = cancellable_stack.to_dict()
	if not action.action_id.is_empty():
		state.processed_action_ids.append(action.action_id)
		if state.processed_action_ids.size() > 256:
			state.processed_action_ids.pop_front()
	result.winner = state.winner
	result.terminal = state.is_terminal()
	return result


static func _discardable_failed_step(
	step: StepResult,
	pre_action_winner: int,
	pre_action_terminal: bool,
) -> StepResult:
	# Match rollback_failed_step's public result exactly. The mutated search child
	# and its local RNG are intentionally left alone because the caller discards
	# both as soon as this failed StepResult is observed.
	step.pending_choice = null
	step.events = []
	step.winner = pre_action_winner
	step.terminal = pre_action_terminal
	return step


func _mark_attack_pending_choice(
	request: ChoiceRequest,
	stack: ResolutionStack,
	actor: int,
) -> void:
	request.metadata["finish_attack_actor"] = actor
	var continuation := _top_continuation_data(stack)
	if not continuation.is_empty():
		request.metadata["continuation"] = continuation


func _top_continuation_data(stack: ResolutionStack) -> Dictionary:
	var summary: Dictionary = {}
	for frame in stack.frames:
		if str(frame.get("kind", "")) == "continuation":
			summary = Dictionary(frame.get("data", {})).duplicate(true)
			if not summary.has("kind"):
				summary["kind"] = str(frame.get("operation", ""))
	return summary
