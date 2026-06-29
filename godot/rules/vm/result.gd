class_name VMResult
extends RefCounted


static func ok(message: String = "") -> Dictionary:
	return {"success": true, "message": message}


static func fail(message: String, error_code: String = "effect_failed") -> Dictionary:
	return {"success": false, "message": message, "error_code": error_code}
