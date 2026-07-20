class_name VMInterpreter
extends RefCounted

var command_registry: VMCommandRegistry
var continuation_registry: VMContinuationRegistry
var trigger_scheduler: VMTriggerScheduler
var _registry_errors: Array[String] = []


func _init() -> void:
	command_registry = VMCommandRegistry.new()
	continuation_registry = VMContinuationRegistry.new()
	trigger_scheduler = VMTriggerScheduler.new()


func register_command_ops(ops: Array) -> bool:
	return command_registry.register_many(ops)


func register_command_descriptors(descriptors: Dictionary) -> bool:
	return command_registry.register_descriptors(descriptors)


func register_command_handler(op: String, handler: Callable) -> bool:
	return command_registry.register_handler(op, handler)


func register_continuation(operation: String, handler: Callable) -> bool:
	return continuation_registry.register(operation, handler)


func freeze(expected_ops: Array = []) -> Array[String]:
	_registry_errors = command_registry.freeze(expected_ops)
	_registry_errors.append_array(continuation_registry.freeze())
	return _registry_errors.duplicate()


func is_ready() -> bool:
	return (
		_registry_errors.is_empty()
		and command_registry.is_frozen()
		and continuation_registry.is_frozen()
	)


func registry_errors() -> Array[String]:
	return _registry_errors.duplicate()


func supports_command_spec(spec: Dictionary) -> bool:
	var op := str(spec.get("op", ""))
	return (
		is_ready()
		and command_registry.has_handler(op)
		and command_registry.validate_spec(spec).is_empty()
	)


func supports_command_handler(op: String) -> bool:
	return command_registry.has_handler(op)


func supports_continuation(operation: String) -> bool:
	return continuation_registry.supports(operation)


func execute_command_spec(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	spec: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary]
) -> Dictionary:
	var op := str(spec.get("op", ""))
	if not is_ready():
		return VMResult.fail(
			"VM注册表未就绪。",
			"vm_registry_not_ready",
		)
	if not command_registry.supports_op(op):
		var unsupported := VMResult.fail(
			"不支持的VM指令: %s" % op,
			"unsupported_vm_op",
		)
		unsupported["_handled"] = false
		return unsupported
	var args_value: Variant = spec.get("args", {})
	if args_value is Dictionary and Dictionary(args_value).has("effect_type"):
		return {
			"_handled": true,
			"success": false,
			"message": "VM command specs must not carry legacy effect_type args.",
			"error_code": "legacy_effect_type_arg",
		}
	var execution_context := _execution_context(stack, op)
	var spec_errors := command_registry.validate_spec(spec, execution_context)
	if not spec_errors.is_empty():
		var invalid := VMResult.fail(
			"VM指令结构无效: %s" % "; ".join(spec_errors),
			"invalid_vm_spec",
		)
		invalid["_handled"] = true
		return invalid
	return command_registry.execute(state, stack, rng, spec, player_idx, source_slot, events)


func _execution_context(stack: ResolutionStack, op: String) -> String:
	var descriptor := command_registry.descriptor(op)
	if str(descriptor.get("implementation_kind", "")) == "test_only":
		return "test"
	if bool(descriptor.get("internal", false)) or not stack.current_trigger_id().is_empty():
		return "trigger"
	if bool(stack.context.get("finish_attack", false)):
		return "attack"
	var source_kind := str(stack.context.get("effect_source_kind", "ability"))
	if source_kind == "stadium":
		return "trainer"
	# The execution contract is independent from whether primary attack damage
	# is still being accumulated. Post-hit attack commands and isolated rules
	# harnesses remain in the attack context after ``finish_attack`` is cleared.
	if source_kind in ["ability", "trainer", "attack"]:
		return source_kind
	return "ability"


func execute_effect(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	effect: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary]
) -> Dictionary:
	if effect.has("op"):
		var native := execute_command_spec(state, stack, rng, effect, player_idx, source_slot, events)
		native.erase("_handled")
		return VMResult.require_explicit(
			native,
			"interpreter:%s" % str(effect.get("op", "")),
		)
	var effect_type := str(effect.get("effect_type", ""))
	return VMResult.fail("结算栈效果缺少VM op: %s" % effect_type, "missing_vm_op")


func execute_continuation(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	operation: String,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary]
) -> Dictionary:
	if not is_ready():
		return VMResult.fail(
			"VM注册表未就绪。",
			"vm_registry_not_ready",
		)
	return VMResult.require_explicit(
		continuation_registry.execute(
			state, stack, rng, operation, data, selected, events),
		"interpreter-continuation:%s" % operation,
	)


func resolve(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
) -> StepResult:
	return _resolve(state, stack, rng)


func _resolve(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
) -> StepResult:
	var events: Array[Dictionary] = []
	var messages: Array[String] = []
	var stack_error := _validate_stack_depth(stack)
	if not stack_error.is_empty():
		state.resolution_stack = stack.to_dict()
		return _error_step(state, stack_error, events)
	while not stack.frames.is_empty():
		stack_error = _validate_stack_depth(stack)
		if not stack_error.is_empty():
			state.resolution_stack = stack.to_dict()
			return _error_step(state, stack_error, events)
		if (
			stack.has_finalize_attack_frame()
			or stack.has_finalize_attack_turn_frame()
			or stack.has_finalize_prize_revealed_frame()
		):
			state.resolution_stack = stack.to_dict()
			return StepResult.new(
				true,
				" ".join(messages),
				null,
				events,
				state.winner,
				state.is_terminal(),
			)
		var budget_error := stack.consume_vm_step()
		if not budget_error.is_empty():
			state.resolution_stack = stack.to_dict()
			return _error_step(state, budget_error, events)
		var frame := stack.pop_frame()
		var frame_kind := str(frame.get("kind", ""))
		if frame_kind == "continuation":
			return StepResult.new(
				false,
				"结算栈包含未响应的选择。",
				null,
				events,
				state.winner,
				false,
				"missing_choice",
			)
		var outcome: Dictionary
		match frame_kind:
			"command":
				var effect: Dictionary = frame.get("spec", {})
				var player_idx := int(frame.get("player_idx", state.active_player_idx))
				var source_slot := str(frame.get("source_slot", "active"))
				stack.context["vm_execution_active"] = true
				outcome = execute_effect(
					state, stack, rng, effect, player_idx, source_slot, events)
				stack.context.erase("vm_execution_active")
			"trigger_batch":
				outcome = trigger_scheduler.advance_batch(state, stack, frame)
			"trigger":
				outcome = trigger_scheduler.expand_trigger(state, stack, frame)
			"barrier":
				if str(frame.get("operation", "")) == "trigger_complete":
					outcome = trigger_scheduler.complete_trigger(
						stack, Dictionary(frame.get("data", {})))
				else:
					outcome = VMResult.fail(
						"未知VM屏障: %s" % str(frame.get("operation", "")),
						"invalid_stack_barrier",
					)
			_:
				outcome = VMResult.fail(
					"未知结算栈帧类型: %s" % frame_kind,
					"invalid_stack_frame",
				)
		stack_error = _validate_stack_depth(stack)
		if not stack_error.is_empty():
			state.resolution_stack = stack.to_dict()
			return _error_step(state, stack_error, events)
		var message := str(outcome.get("message", ""))
		if not message.is_empty():
			messages.append(message)
		if not bool(outcome.get("success", false)):
			state.resolution_stack = stack.to_dict()
			return StepResult.new(
				false,
				" ".join(messages),
				null,
				events,
				state.winner,
				state.is_terminal(),
				str(outcome.get("error_code", "effect_failed")),
			)
		if bool(outcome.get("attack_failed", false)):
			stack.context["attack_failed"] = true
		if stack.pending_request:
			state.resolution_stack = stack.to_dict()
			return StepResult.new(
				true,
				" ".join(messages),
				stack.pending_request,
				events,
				state.winner,
				state.is_terminal(),
			)
	state.resolution_stack = stack.to_dict()
	return StepResult.new(
		true,
		" ".join(messages),
		null,
		events,
		state.winner,
		state.is_terminal(),
	)


func apply_choice(
	state: GameState,
	stack: ResolutionStack,
	response: ChoiceResponse,
	rng: PortableRandomSource,
) -> StepResult:
	var request := stack.pending_request
	if request == null or request.request_id != response.request_id:
		return StepResult.new(false, "选择请求已过期。", null, [], state.winner, false, "stale_choice")
	if response.cancelled and not request.can_cancel:
		return StepResult.new(
			false,
			"该选择不可取消。",
			null,
			[],
			state.winner,
			false,
			"choice_not_cancellable",
		)
	if stack.frames.is_empty() or stack.frames[-1].get("kind", "") != "continuation":
		return StepResult.new(
			false,
			"选择请求缺少续执行帧。",
			null,
			[],
			state.winner,
			false,
			"missing_continuation",
		)
	var stack_error := _validate_stack_depth(stack)
	if not stack_error.is_empty():
		state.resolution_stack = stack.to_dict()
		return _error_step(state, stack_error, [])

	var option_map: Dictionary = {}
	for option in request.options:
		option_map[str(option.get("option_id", ""))] = option
	var selected: Array[Dictionary] = []
	for option_id in response.option_ids:
		if not option_map.has(option_id):
			return StepResult.new(false, "包含无效选择项。", null, [], state.winner, false, "invalid_choice")
		selected.append(option_map[option_id])
	if not request.allow_duplicates:
		var unique: Dictionary = {}
		for option_id in response.option_ids:
			if unique.has(option_id):
				return StepResult.new(
					false,
					"该选择不允许重复。",
					null,
					[],
					state.winner,
					false,
					"duplicate_choice",
				)
			unique[option_id] = true
	if not response.cancelled and (
		selected.size() < request.min_select or selected.size() > request.max_select
	):
		return StepResult.new(false, "选择数量不符合要求。", null, [], state.winner, false, "choice_count")

	var continuation := stack.pop_frame()
	stack.pending_request = null
	var events: Array[Dictionary] = []
	var outcome := VMResult.ok("操作已取消。")
	# A zero-minimum choice means "choose up to N". Cancelling it selects
	# zero targets but must still run the continuation (for example Cobalion
	# still shuffles the deck). Trainer cancellation is restored earlier by
	# VMChoiceSettlement when an action checkpoint exists.
	var continuation_operation := str(continuation.get("operation", ""))
	var budget_error := stack.consume_vm_step()
	if not budget_error.is_empty():
		state.resolution_stack = stack.to_dict()
		return _error_step(state, budget_error, events)
	if continuation_operation in ["trigger_order", "trigger_confirm"]:
		outcome = trigger_scheduler.apply_trigger_choice(
			state,
			stack,
			continuation_operation,
			Dictionary(continuation.get("data", {})),
			selected,
			response.cancelled,
		)
	elif not response.cancelled or request.min_select == 0:
		outcome = execute_continuation(
			state,
			stack,
			rng,
			continuation_operation,
			Dictionary(continuation.get("data", {})),
			selected,
			events,
		)
	stack_error = _validate_stack_depth(stack)
	if not stack_error.is_empty():
		state.resolution_stack = stack.to_dict()
		return _error_step(state, stack_error, events)
	if not bool(outcome.get("success", false)):
		state.resolution_stack = stack.to_dict()
		return StepResult.new(
			false,
			str(outcome.get("message", "")),
			null,
			events,
			state.winner,
			false,
			str(outcome.get("error_code", "choice_failed")),
		)
	if stack.pending_request:
		state.resolution_stack = stack.to_dict()
		return StepResult.new(
			true,
			str(outcome.get("message", "")),
			stack.pending_request,
			events,
			state.winner,
			state.is_terminal(),
		)
	var resumed := _resolve(state, stack, rng)
	resumed.events = events + resumed.events
	var prefix := str(outcome.get("message", ""))
	if not prefix.is_empty():
		resumed.message = "%s %s" % [prefix, resumed.message]
	return resumed


func _validate_stack_depth(stack: ResolutionStack) -> Dictionary:
	var validation := stack.validation_result()
	if not validation.is_empty():
		return validation
	if stack.frames.size() <= VMContract.MAX_FRAME_DEPTH:
		return {}
	return VMResult.fail(
		"VM结算栈深度超过上限%d。" % VMContract.MAX_FRAME_DEPTH,
		"vm_frame_depth_limit",
	)


func _error_step(
	state: GameState,
	outcome: Dictionary,
	events: Array[Dictionary],
) -> StepResult:
	return StepResult.new(
		false,
		str(outcome.get("message", "VM执行失败。")),
		null,
		events,
		state.winner,
		state.is_terminal(),
		str(outcome.get("error_code", "vm_error")),
	)
