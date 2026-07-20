class_name VMResult
extends RefCounted


static func ok(message: String = "") -> Dictionary:
	return {"success": true, "message": message}


static func fail(message: String, error_code: String = "effect_failed") -> Dictionary:
	return {"success": false, "message": message, "error_code": error_code}


static func require_explicit(
	result: Variant,
	source: String,
) -> Dictionary:
	if not result is Dictionary:
		return fail(
			"VM处理器必须返回结果字典: %s" % source,
			"invalid_vm_result",
		)
	var outcome := Dictionary(result).duplicate(true)
	if not outcome.has("success") or typeof(outcome["success"]) != TYPE_BOOL:
		return fail(
			"VM处理器必须返回显式布尔success: %s" % source,
			"invalid_vm_result",
		)
	if not outcome.has("message"):
		outcome["message"] = ""
	elif typeof(outcome["message"]) != TYPE_STRING:
		return fail(
			"VM处理器message必须是字符串: %s" % source,
			"invalid_vm_result",
		)
	if not bool(outcome["success"]):
		if not outcome.has("error_code") or str(outcome["error_code"]).is_empty():
			outcome["error_code"] = "effect_failed"
		elif typeof(outcome["error_code"]) != TYPE_STRING:
			return fail(
				"VM处理器error_code必须是字符串: %s" % source,
				"invalid_vm_result",
			)
	return outcome
