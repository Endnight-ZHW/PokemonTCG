class_name VMInterpreter
extends RefCounted

var command_registry: VMCommandRegistry
var continuation_registry: VMContinuationRegistry


func _init() -> void:
	command_registry = VMCommandRegistry.new()
	continuation_registry = VMContinuationRegistry.new()


func register_command_ops(ops: Array) -> void:
	command_registry.register_many(ops)


func register_command_handler(op: String, handler: Callable) -> void:
	command_registry.register_handler(op, handler)


func register_continuation(operation: String, handler: Callable) -> void:
	continuation_registry.register(operation, handler)


func supports_command_spec(spec: Dictionary) -> bool:
	return VMContract.validate_command_spec(spec, command_registry.supported_ops()).is_empty()


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
	if not command_registry.supports_op(op):
		return {"_handled": false}
	var args := Dictionary(spec.get("args", {}))
	if args.has("effect_type"):
		return {
			"_handled": true,
			"success": false,
			"message": "VM command specs must not carry legacy effect_type args.",
			"error_code": "legacy_effect_type_arg",
		}
	return command_registry.execute(state, stack, rng, spec, player_idx, source_slot, events)


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
		if bool(native.get("_handled", false)):
			native.erase("_handled")
			return native
		return VMResult.fail("不支持的VM指令: %s" % str(effect.get("op", "")), "unsupported_vm_op")
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
	return continuation_registry.execute(state, stack, rng, operation, data, selected, events)


func resolve(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
) -> StepResult:
	var events: Array[Dictionary] = []
	var messages: Array[String] = []
	while not stack.frames.is_empty():
		if stack.has_finalize_attack_frame():
			state.resolution_stack = stack.to_dict()
			return StepResult.new(
				true,
				" ".join(messages),
				null,
				events,
				state.winner,
				state.winner >= 0,
			)
		var frame := stack.pop_frame()
		if frame.get("kind", "") == "continuation":
			return StepResult.new(
				false,
				"结算栈包含未响应的选择。",
				null,
				events,
				state.winner,
				false,
				"missing_choice",
			)
		var effect: Dictionary = frame.get("effect", {})
		var player_idx := int(frame.get("player_idx", state.active_player_idx))
		var source_slot := str(frame.get("source_slot", "active"))
		var outcome := execute_effect(state, stack, rng, effect, player_idx, source_slot, events)
		var message := str(outcome.get("message", ""))
		if not message.is_empty():
			messages.append(message)
		if not bool(outcome.get("success", true)):
			state.resolution_stack = stack.to_dict()
			return StepResult.new(
				false,
				" ".join(messages),
				null,
				events,
				state.winner,
				state.winner >= 0,
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
				state.winner >= 0,
			)
	state.resolution_stack = stack.to_dict()
	return StepResult.new(
		true,
		" ".join(messages),
		null,
		events,
		state.winner,
		state.winner >= 0,
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
	if not response.cancelled:
		outcome = execute_continuation(
			state,
			stack,
			rng,
			str(continuation.get("operation", "")),
			Dictionary(continuation.get("data", {})),
			selected,
			events,
		)
	if not bool(outcome.get("success", true)):
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
			state.winner >= 0,
		)
	var resumed := resolve(state, stack, rng)
	resumed.events = events + resumed.events
	var prefix := str(outcome.get("message", ""))
	if not prefix.is_empty():
		resumed.message = "%s %s" % [prefix, resumed.message]
	return resumed
