class_name ResolutionStack
extends RefCounted

var frames: Array[Dictionary] = []
var pending_request: ChoiceRequest
var sequence := 0
var context: Dictionary = {}
var validation_error: Dictionary = {}


func push_effect(effect: Dictionary, player_idx: int, source_slot: String) -> void:
	push_command(effect, player_idx, source_slot)


func push_command(
	spec: Dictionary,
	player_idx: int,
	source_slot: String,
	origin: Dictionary = {},
) -> void:
	_append_frame(VMResolutionFrameCodec.command_frame(
		spec, player_idx, source_slot, origin))


func push_effects(effects: Array, player_idx: int, source_slot: String) -> void:
	for index in range(effects.size() - 1, -1, -1):
		push_effect(Dictionary(effects[index]), player_idx, source_slot)


func push_continuation(operation: String, data: Dictionary) -> void:
	var continuation_data := data.duplicate(true)
	if not continuation_data.has("kind"):
		continuation_data["kind"] = operation
	_append_frame(VMResolutionFrameCodec.continuation_frame(
		operation, continuation_data))


func push_finalize_attack(actor: int, stage: String = "primary_hit") -> void:
	push_barrier("finalize_attack", {"actor": actor, "stage": stage})


func push_finalize_attack_turn(actor: int) -> void:
	push_barrier("finalize_attack_turn", {"actor": actor})


func push_finalize_prize_revealed(source_ref: Dictionary) -> void:
	push_barrier("finalize_prize_revealed", {"source_ref": source_ref.duplicate(true)})


func has_finalize_attack_frame() -> bool:
	return _top_is_barrier("finalize_attack")


func has_finalize_attack_turn_frame() -> bool:
	return _top_is_barrier("finalize_attack_turn")


func has_finalize_prize_revealed_frame() -> bool:
	return _top_is_barrier("finalize_prize_revealed")


func pop_finalize_attack() -> Dictionary:
	if not has_finalize_attack_frame():
		return {}
	return Dictionary(pop_frame().get("data", {})).duplicate(true)


func pop_finalize_attack_turn() -> Dictionary:
	if not has_finalize_attack_turn_frame():
		return {}
	return Dictionary(pop_frame().get("data", {})).duplicate(true)


func pop_finalize_prize_revealed() -> Dictionary:
	if not has_finalize_prize_revealed_frame():
		return {}
	return Dictionary(pop_frame().get("data", {})).duplicate(true)


func pop_frame() -> Dictionary:
	if frames.is_empty():
		return {}
	return frames.pop_back()


func push_trigger_batch(frame: Dictionary) -> bool:
	if str(frame.get("kind", "")) != "trigger_batch":
		validation_error = VMResult.fail("触发批帧类型无效。", "invalid_trigger_batch")
		return false
	return _append_frame(frame)


func push_trigger(candidate: Dictionary) -> bool:
	return _append_frame(VMResolutionFrameCodec.trigger_frame(candidate))


func push_barrier(operation: String, data: Dictionary = {}) -> bool:
	return _append_frame(VMResolutionFrameCodec.barrier_frame(operation, data))


func validation_result() -> Dictionary:
	if not validation_error.is_empty():
		return validation_error.duplicate(true)
	return VMResolutionFrameCodec.validate_stack_payload(to_dict())


func consume_vm_step() -> Dictionary:
	var budget: Dictionary = context.get("vm_budget", {})
	var used := int(budget.get("steps_used", 0))
	if used >= VMContract.MAX_VM_STEPS:
		return VMResult.fail(
			"VM执行步数超过上限%d。" % VMContract.MAX_VM_STEPS,
			"vm_step_limit",
		)
	budget["steps_used"] = used + 1
	context["vm_budget"] = budget
	return {}


func current_trigger_id() -> String:
	var trigger_stack: Array = context.get("trigger_stack", [])
	return "" if trigger_stack.is_empty() else str(trigger_stack[-1])


func current_trigger_depth() -> int:
	var trigger_stack: Array = context.get("trigger_stack", [])
	return trigger_stack.size()


func begin_trigger(trigger_id: String) -> Dictionary:
	var trigger_stack: Array = context.get("trigger_stack", []).duplicate()
	if trigger_stack.size() >= VMResolutionFrameCodec.MAX_TRIGGER_DEPTH:
		return VMResult.fail("触发嵌套超过64层。", "trigger_depth_limit")
	trigger_stack.append(trigger_id)
	context["trigger_stack"] = trigger_stack
	return {}


func end_trigger(trigger_id: String) -> Dictionary:
	var trigger_stack: Array = context.get("trigger_stack", []).duplicate()
	if trigger_stack.is_empty() or str(trigger_stack[-1]) != trigger_id:
		return VMResult.fail("触发栈来源不一致。", "invalid_trigger_origin")
	trigger_stack.pop_back()
	context["trigger_stack"] = trigger_stack
	return {}


func is_blockable_opponent_attack_effect(
	source_player_idx: int,
	target_player_idx: int,
) -> bool:
	# Attack protection applies to every damage/effect packet produced by the
	# opponent's attack. Trainer/Ability stacks deliberately have no
	# finish_attack context, while reactive commands can share an attack stack
	# but use a different source player. Both distinctions matter here.
	return (
		bool(context.get("finish_attack", false))
		and int(context.get("actor", -1)) == source_player_idx
		and target_player_idx != source_player_idx
		and not bool(context.get(
			"ignore_defender_damage_effects",
			context.get("ignore_defender_effects", false),
		))
	)


func next_request_id(state: GameState, player_idx: int, request_type: String) -> String:
	sequence = maxi(sequence, state.choice_sequence)
	var request_id := "choice:%d:%d:%s:%d" % [
		state.revision,
		player_idx,
		request_type,
		sequence,
	]
	sequence += 1
	state.choice_sequence = sequence
	return request_id


func to_dict() -> Dictionary:
	return {
		"schema_version": VMResolutionFrameCodec.STACK_SCHEMA_VERSION,
		"frames": frames.duplicate(true),
		"pending_request": pending_request.to_dict() if pending_request else null,
		"sequence": sequence,
		"context": context.duplicate(true),
	}


static func from_dict(data: Dictionary) -> ResolutionStack:
	var result := ResolutionStack.new()
	# Empty pre-match states are normalized into Snapshot 3. Non-empty legacy
	# stacks are rejected instead of guessing at executable frame semantics.
	var normalized := data.duplicate(true)
	if normalized.is_empty() or (
		not normalized.has("schema_version")
		and Array(normalized.get("frames", [])).is_empty()
	):
		normalized = {
			"schema_version": VMResolutionFrameCodec.STACK_SCHEMA_VERSION,
			"frames": [],
			"pending_request": normalized.get("pending_request", null),
			"sequence": int(normalized.get("sequence", 0)),
			"context": Dictionary(normalized.get("context", {})).duplicate(true),
		}
	result.frames.assign(normalized.get("frames", []))
	if normalized.get("pending_request") is Dictionary:
		result.pending_request = ChoiceRequest.from_dict(normalized["pending_request"])
	result.sequence = int(normalized.get("sequence", 0))
	result.context = Dictionary(normalized.get("context", {})).duplicate(true)
	result.validation_error = VMResolutionFrameCodec.validate_stack_payload(normalized)
	return result


func _append_frame(frame: Dictionary) -> bool:
	var error := VMResolutionFrameCodec.validate_frame(frame)
	if not error.is_empty():
		validation_error = error
		return false
	if frames.size() >= VMContract.MAX_FRAME_DEPTH:
		validation_error = VMResult.fail(
			"VM结算栈深度超过上限%d。" % VMContract.MAX_FRAME_DEPTH,
			"vm_frame_depth_limit",
		)
		return false
	frames.append(frame)
	return true


func _top_is_barrier(operation: String) -> bool:
	return (
		not frames.is_empty()
		and str(frames[-1].get("kind", "")) == "barrier"
		and str(frames[-1].get("operation", "")) == operation
	)
