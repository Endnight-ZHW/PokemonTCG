class_name VMResolutionFrameCodec
extends RefCounted

const STACK_SCHEMA_VERSION := 3
const MAX_TRIGGER_CANDIDATES := 256
const MAX_TRIGGER_COMMANDS := 256
const MAX_TRIGGER_DEPTH := 64
const MAX_SERIALIZED_BYTES := 1024 * 1024

const FRAME_KEYS := {
	"command": ["kind", "spec", "player_idx", "source_slot", "origin"],
	"continuation": ["kind", "operation", "data"],
	"trigger_batch": [
		"kind", "batch_id", "hook", "active_player", "order_policy",
		"candidates", "parent_trigger_id", "depth", "choice_domain",
	],
	"trigger": ["kind", "candidate"],
	"barrier": ["kind", "operation", "data"],
}

const TRIGGER_KEYS := [
	"trigger_id",
	"hook",
	"controller",
	"priority",
	"source_ref",
	"optional",
	"liveness",
	"guards",
	"commands",
	"parent_trigger_id",
	"depth",
]

const TRUSTED_INTERNAL_TRIGGER_OPS := [
	"trigger_draw_cards",
	"trigger_place_damage_counters",
	"trigger_move_basic_energy",
	"trigger_switch_with_active",
]


static func command_frame(
	spec: Dictionary,
	player_idx: int,
	source_slot: String,
	origin: Dictionary = {},
) -> Dictionary:
	return {
		"kind": "command",
		"spec": spec.duplicate(true),
		"player_idx": player_idx,
		"source_slot": source_slot,
		"origin": origin.duplicate(true),
	}


static func continuation_frame(operation: String, data: Dictionary) -> Dictionary:
	return {
		"kind": "continuation",
		"operation": operation,
		"data": data.duplicate(true),
	}


static func trigger_batch_frame(
	batch_id: String,
	hook: String,
	active_player: int,
	order_policy: String,
	candidates: Array[Dictionary],
	parent_trigger_id: String,
	depth: int,
	choice_domain: String,
) -> Dictionary:
	return {
		"kind": "trigger_batch",
		"batch_id": batch_id,
		"hook": hook,
		"active_player": active_player,
		"order_policy": order_policy,
		"candidates": candidates.duplicate(true),
		"parent_trigger_id": parent_trigger_id,
		"depth": depth,
		"choice_domain": choice_domain,
	}


static func trigger_frame(candidate: Dictionary) -> Dictionary:
	return {"kind": "trigger", "candidate": candidate.duplicate(true)}


static func barrier_frame(operation: String, data: Dictionary = {}) -> Dictionary:
	return {
		"kind": "barrier",
		"operation": operation,
		"data": data.duplicate(true),
	}


static func validate_frame(frame: Dictionary) -> Dictionary:
	var kind := str(frame.get("kind", ""))
	if not FRAME_KEYS.has(kind):
		return VMResult.fail("未知结算栈帧类型: %s" % kind, "invalid_stack_frame")
	var expected: Array = FRAME_KEYS[kind]
	for key_value in frame.keys():
		var key := str(key_value)
		if key not in expected:
			return VMResult.fail(
				"结算栈%s帧包含多余字段: %s" % [kind, key],
				"invalid_stack_frame",
			)
	for key_value in expected:
		var key := str(key_value)
		if not frame.has(key):
			return VMResult.fail(
				"结算栈%s帧缺少字段: %s" % [kind, key],
				"invalid_stack_frame",
			)
	if not _is_json_safe(frame):
		return VMResult.fail("结算栈帧包含不可序列化值。", "invalid_stack_frame")
	match kind:
		"command":
			if (
				not frame.get("spec") is Dictionary
				or not _is_wire_integer(frame.get("player_idx"))
				or not frame.get("source_slot") is String
				or not frame.get("origin") is Dictionary
			):
				return VMResult.fail("command帧spec必须是对象。", "invalid_stack_frame")
			if int(frame.get("player_idx", -1)) not in [0, 1]:
				return VMResult.fail("command帧玩家无效。", "invalid_stack_frame")
		"continuation":
			if str(frame.get("operation", "")).is_empty() or not frame.get("data") is Dictionary:
				return VMResult.fail("continuation帧结构无效。", "invalid_stack_frame")
		"trigger_batch":
			if (
				not frame.get("batch_id") is String
				or str(frame.get("batch_id", "")).is_empty()
				or not frame.get("hook") is String
				or str(frame.get("hook", "")).is_empty()
				or not _is_wire_integer(frame.get("active_player"))
				or int(frame.get("active_player", -1)) not in [0, 1]
				or not frame.get("order_policy") is String
				or str(frame.get("order_policy", "")) not in ["apnap", "incoming_first"]
				or not frame.get("parent_trigger_id") is String
				or not _is_wire_integer(frame.get("depth"))
				or not frame.get("choice_domain") is String
				or str(frame.get("choice_domain", "")) not in ["effect", "knockout"]
			):
				return VMResult.fail("trigger_batch字段类型无效。", "invalid_trigger_batch")
			var candidates_value: Variant = frame.get("candidates")
			if not candidates_value is Array:
				return VMResult.fail("trigger_batch候选必须是数组。", "invalid_trigger_batch")
			var candidates: Array = candidates_value
			if candidates.size() > MAX_TRIGGER_CANDIDATES:
				return VMResult.fail(
					"同批触发超过上限%d。" % MAX_TRIGGER_CANDIDATES,
					"trigger_batch_limit",
				)
			if int(frame.get("depth", 0)) < 0 or int(frame.get("depth", 0)) > MAX_TRIGGER_DEPTH:
				return VMResult.fail("触发深度无效。", "trigger_depth_limit")
			for candidate_value in candidates:
				if not candidate_value is Dictionary:
					return VMResult.fail("触发候选必须是对象。", "invalid_trigger_candidate")
				var candidate_error := validate_trigger_candidate(candidate_value)
				if not candidate_error.is_empty():
					return candidate_error
				if str(candidate_value.get("hook", "")) != str(frame.get("hook", "")):
					return VMResult.fail("触发候选hook与批次不一致。", "invalid_trigger_candidate")
				if (
					str(candidate_value.get("parent_trigger_id", ""))
					!= str(frame.get("parent_trigger_id", ""))
					or int(candidate_value.get("depth", 0)) != int(frame.get("depth", 0))
				):
					return VMResult.fail("触发候选来源层级与批次不一致。", "invalid_trigger_origin")
		"trigger":
			if not frame.get("candidate") is Dictionary:
				return VMResult.fail("trigger帧候选无效。", "invalid_trigger_candidate")
			return validate_trigger_candidate(frame.get("candidate"))
		"barrier":
			if str(frame.get("operation", "")).is_empty() or not frame.get("data") is Dictionary:
				return VMResult.fail("barrier帧结构无效。", "invalid_stack_frame")
			if str(frame.get("operation", "")) not in [
				"finalize_attack", "finalize_attack_turn", "finalize_prize_revealed",
				"trigger_complete",
			]:
				return VMResult.fail("未知barrier操作。", "invalid_stack_barrier")
	return {}


static func validate_trigger_candidate(candidate: Dictionary) -> Dictionary:
	for key_value in candidate.keys():
		var key := str(key_value)
		if key not in TRIGGER_KEYS:
			return VMResult.fail(
				"触发候选包含多余字段: %s" % key,
				"invalid_trigger_candidate",
			)
	for key_value in TRIGGER_KEYS:
		var key := str(key_value)
		if not candidate.has(key):
			return VMResult.fail(
				"触发候选缺少字段: %s" % key,
				"invalid_trigger_candidate",
			)
	if (
		str(candidate.get("trigger_id", "")).is_empty()
		or str(candidate.get("hook", "")).is_empty()
		or not candidate.get("trigger_id") is String
		or not candidate.get("hook") is String
		or not _is_wire_integer(candidate.get("controller"))
		or int(candidate.get("controller", -1)) not in [0, 1]
		or not _is_wire_integer(candidate.get("priority"))
		or not candidate.get("source_ref") is Dictionary
		or not candidate.get("optional") is bool
		or not candidate.get("liveness") is Dictionary
		or not candidate.get("guards") is Array
		or not candidate.get("commands") is Array
		or not candidate.get("parent_trigger_id") is String
		or not _is_wire_integer(candidate.get("depth"))
	):
		return VMResult.fail("触发候选字段类型无效。", "invalid_trigger_candidate")
	var ref_error := EntityRef.validate_dict(candidate.get("source_ref"))
	if not ref_error.is_empty():
		return VMResult.fail("触发来源引用无效: %s" % ref_error, "invalid_trigger_ref")
	var depth := int(candidate.get("depth", 0))
	if depth < 1 or depth > MAX_TRIGGER_DEPTH:
		return VMResult.fail("触发深度超过上限。", "trigger_depth_limit")
	if not _is_json_safe(candidate):
		return VMResult.fail("触发候选包含不可序列化值。", "invalid_trigger_candidate")
	var liveness_error := _validate_liveness(Dictionary(candidate.get("liveness", {})))
	if not liveness_error.is_empty():
		return liveness_error
	for guard_value in candidate.get("guards", []):
		if not guard_value is Dictionary:
			return VMResult.fail("触发guard必须是对象。", "invalid_trigger_guard")
		var guard_error := _validate_guard(guard_value)
		if not guard_error.is_empty():
			return guard_error
	var commands: Array = candidate.get("commands", [])
	if commands.size() > MAX_TRIGGER_COMMANDS:
		return VMResult.fail("单个触发命令数超过上限。", "trigger_command_limit")
	for command_index in range(commands.size()):
		if not commands[command_index] is Dictionary:
			return VMResult.fail("触发命令必须是对象。", "invalid_trigger_payload")
		var command: Dictionary = commands[command_index]
		var op := str(command.get("op", ""))
		var descriptor := VMContract.command_descriptor(op)
		if bool(descriptor.get("internal", false)) and op not in TRUSTED_INTERNAL_TRIGGER_OPS:
			return VMResult.fail("触发候选不得调用内部VM指令。", "internal_vm_op")
		var command_errors := VMContract.validate_command_spec(
			command,
			_ops_dictionary(),
			"$.commands[%d]" % command_index,
			VMContract.native_command_descriptors(),
			"trigger",
		)
		if not command_errors.is_empty():
			return VMResult.fail(
				"触发命令结构无效: %s" % "; ".join(command_errors),
				"invalid_trigger_payload",
			)
	return {}


static func validate_stack_payload(payload: Dictionary) -> Dictionary:
	if int(payload.get("schema_version", -1)) != STACK_SCHEMA_VERSION:
		return VMResult.fail("结算栈快照版本不兼容。", "incompatible_snapshot")
	var allowed := ["schema_version", "frames", "pending_request", "sequence", "context"]
	for required_key in allowed:
		if not payload.has(required_key):
			return VMResult.fail("结算栈快照缺少字段。", "invalid_stack_snapshot")
	for key_value in payload.keys():
		if str(key_value) not in allowed:
			return VMResult.fail("结算栈快照包含未知字段。", "invalid_stack_snapshot")
	var frames_value: Variant = payload.get("frames")
	if not frames_value is Array:
		return VMResult.fail("结算栈frames必须是数组。", "invalid_stack_snapshot")
	var frames: Array = frames_value
	if frames.size() > VMContract.MAX_FRAME_DEPTH:
		return VMResult.fail(
			"VM结算栈深度超过上限%d。" % VMContract.MAX_FRAME_DEPTH,
			"vm_frame_depth_limit",
		)
	for frame_value in frames:
		if not frame_value is Dictionary:
			return VMResult.fail("结算栈帧必须是对象。", "invalid_stack_frame")
		var error := validate_frame(frame_value)
		if not error.is_empty():
			return error
	if not _is_json_safe(payload):
		return VMResult.fail("结算栈快照包含不可序列化值。", "invalid_stack_snapshot")
	var encoded := JSON.stringify(payload)
	if encoded.to_utf8_buffer().size() > MAX_SERIALIZED_BYTES:
		return VMResult.fail(
			"结算栈快照超过%d字节。" % MAX_SERIALIZED_BYTES,
			"stack_snapshot_size_limit",
		)
	return {}


static func _validate_liveness(liveness: Dictionary) -> Dictionary:
	if liveness.size() != 1 or not liveness.has("kind") or not liveness["kind"] is String:
		return VMResult.fail("触发liveness结构无效。", "invalid_trigger_liveness")
	if str(liveness["kind"]) not in ["always", "source_exists"]:
		return VMResult.fail("未知触发liveness。", "invalid_trigger_liveness")
	return {}


static func _validate_guard(guard: Dictionary) -> Dictionary:
	if not guard.has("kind") or not guard["kind"] is String:
		return VMResult.fail("触发guard结构无效。", "invalid_trigger_guard")
	match str(guard["kind"]):
		"always":
			if guard.size() != 1:
				return VMResult.fail("always guard包含多余字段。", "invalid_trigger_guard")
		"ref_exists":
			if guard.size() != 2 or not guard.has("ref"):
				return VMResult.fail("ref_exists guard结构无效。", "invalid_trigger_guard")
			var ref_error := EntityRef.validate_dict(guard.get("ref"))
			if not ref_error.is_empty():
				return VMResult.fail("guard引用无效。", "invalid_trigger_guard")
		_:
			return VMResult.fail("未知触发guard。", "invalid_trigger_guard")
	return {}


static func _ops_dictionary() -> Dictionary:
	var result: Dictionary = {}
	for op in VMContract.native_command_ops():
		result[str(op)] = true
	return result


static func _is_wire_integer(value: Variant) -> bool:
	return (
		value is int
		or (
			value is float
			and is_finite(float(value))
			and float(value) == floor(float(value))
		)
	)


static func _is_json_safe(value: Variant, depth: int = 0) -> bool:
	if depth > 128:
		return false
	if value == null or value is bool or value is String:
		return true
	if value is int:
		return true
	if value is float:
		return is_finite(float(value))
	if value is Array:
		for child in value:
			if not _is_json_safe(child, depth + 1):
				return false
		return true
	if value is Dictionary:
		for key_value in value.keys():
			if not key_value is String or not _is_json_safe(value[key_value], depth + 1):
				return false
		return true
	return false
