class_name ResolutionStack
extends RefCounted

var frames: Array[Dictionary] = []
var pending_request: ChoiceRequest
var sequence := 0
var context: Dictionary = {}


func push_effect(effect: Dictionary, player_idx: int, source_slot: String) -> void:
	frames.append({
		"kind": "effect",
		"effect": effect.duplicate(true),
		"player_idx": player_idx,
		"source_slot": source_slot,
	})


func push_effects(effects: Array, player_idx: int, source_slot: String) -> void:
	for index in range(effects.size() - 1, -1, -1):
		push_effect(Dictionary(effects[index]), player_idx, source_slot)


func push_continuation(operation: String, data: Dictionary) -> void:
	var continuation_data := data.duplicate(true)
	if not continuation_data.has("kind"):
		continuation_data["kind"] = operation
	frames.append({
		"kind": "continuation",
		"operation": operation,
		"data": continuation_data,
	})


func push_finalize_attack(actor: int) -> void:
	frames.append({
		"kind": "finalize_attack",
		"actor": actor,
	})


func push_finalize_attack_turn(actor: int) -> void:
	frames.append({
		"kind": "finalize_attack_turn",
		"actor": actor,
	})


func has_finalize_attack_frame() -> bool:
	return not frames.is_empty() and str(frames[-1].get("kind", "")) == "finalize_attack"


func has_finalize_attack_turn_frame() -> bool:
	return not frames.is_empty() and str(frames[-1].get("kind", "")) == "finalize_attack_turn"


func pop_finalize_attack() -> Dictionary:
	if not has_finalize_attack_frame():
		return {}
	return pop_frame()


func pop_finalize_attack_turn() -> Dictionary:
	if not has_finalize_attack_turn_frame():
		return {}
	return pop_frame()


func pop_frame() -> Dictionary:
	if frames.is_empty():
		return {}
	return frames.pop_back()


func next_request_id(state: GameState, player_idx: int, request_type: String) -> String:
	var request_id := "choice:%d:%d:%s:%d" % [
		state.revision,
		player_idx,
		request_type,
		sequence,
	]
	sequence += 1
	return request_id


func to_dict() -> Dictionary:
	return {
		"frames": frames.duplicate(true),
		"pending_request": pending_request.to_dict() if pending_request else null,
		"sequence": sequence,
		"context": context.duplicate(true),
	}


static func from_dict(data: Dictionary) -> ResolutionStack:
	var result := ResolutionStack.new()
	result.frames.assign(data.get("frames", []))
	if data.get("pending_request") is Dictionary:
		result.pending_request = ChoiceRequest.from_dict(data["pending_request"])
	result.sequence = int(data.get("sequence", 0))
	result.context = Dictionary(data.get("context", {})).duplicate(true)
	return result
