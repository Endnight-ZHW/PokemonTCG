class_name DeepAIRuntime
extends RefCounted

const MANIFEST_PATH := "res://data/ai_models_runtime.json"
const RELEASE_MANIFEST_PATH := "res://data/release_manifest.json"

var manifest: Dictionary = {}
var release_manifest: Dictionary = {}
var backend: Variant
var last_error := ""
var loaded_deck := ""
var expected_python_rules_version := 0
var expected_python_action_version := 0
var expected_python_encoder_version := 0
var expected_onnx_opset := 0
var expected_onnx_runtime_version := ""


func _init() -> void:
	release_manifest = _read_json(RELEASE_MANIFEST_PATH, "release_manifest")
	if not release_manifest.is_empty():
		var schemas: Dictionary = release_manifest.get("schemas", {})
		var onnx: Dictionary = release_manifest.get("onnx", {})
		expected_python_rules_version = int(schemas.get("python_rules", 0))
		expected_python_action_version = int(schemas.get("python_actions", 0))
		expected_python_encoder_version = int(schemas.get("encoder", 0))
		expected_onnx_opset = int(onnx.get("opset", 0))
		expected_onnx_runtime_version = str(onnx.get("runtime_version", ""))
	manifest = _read_json(MANIFEST_PATH, "runtime_manifest")
	if ClassDB.class_exists("OnnxInference"):
		backend = ClassDB.instantiate("OnnxInference")
	else:
		last_error = "onnx_extension_unavailable"


func is_available() -> bool:
	return (
		backend != null
		and not manifest.is_empty()
		and not release_manifest.is_empty()
	)


func load_for_deck(deck_key: String) -> bool:
	unload()
	if not is_available():
		return false
	if (
		int(manifest.get("opset", 0)) != expected_onnx_opset
		or str(manifest.get("onnx_runtime_version", ""))
		!= expected_onnx_runtime_version
	):
		last_error = "runtime_release_manifest_mismatch"
		return false
	var bridge_value: Variant = manifest.get("compatibility_bridge", {})
	if not bridge_value is Dictionary:
		last_error = "compatibility_bridge_invalid"
		return false
	var bridge: Dictionary = bridge_value
	if (
		int(bridge.get("version", 0)) != 1
		or int(bridge.get("python_rules_version", 0)) != expected_python_rules_version
		or int(bridge.get("python_action_version", 0)) != expected_python_action_version
		or int(bridge.get("python_encoder_version", 0))
		!= expected_python_encoder_version
		or int(bridge.get("godot_rules_version", 0)) != AppState.RULES_SCHEMA_VERSION
		or int(bridge.get("godot_action_version", 0)) != AppState.ACTION_SCHEMA_VERSION
	):
		last_error = "compatibility_bridge_mismatch"
		return false
	var models_value: Variant = manifest.get("models", {})
	if not models_value is Dictionary:
		last_error = "model_manifest_invalid"
		return false
	var model_value: Variant = Dictionary(models_value).get(deck_key, {})
	if not model_value is Dictionary:
		last_error = "model_manifest_missing"
		return false
	var row: Dictionary = model_value
	if row.is_empty():
		last_error = "model_manifest_missing"
		return false
	if int(row.get("encoder_version", 0)) != expected_python_encoder_version:
		last_error = "model_encoder_version_mismatch"
		return false
	var model_manifest := {
		"opset": int(manifest.get("opset", 0)),
		"state_numeric_size": int(manifest.get("state_numeric_size", 0)),
		"state_card_slots": int(manifest.get("state_card_slots", 0)),
		"action_numeric_size": int(manifest.get("action_numeric_size", 0)),
		"onnx_sha256": str(row.get("onnx_sha256", "")),
		"choice_head_enabled": bool(row.get("choice_head_enabled", false)),
	}
	var path := str(row.get("onnx_path", ""))
	if not backend.call("load_model", path, model_manifest):
		last_error = str(backend.call("get_last_error"))
		return false
	if str(backend.call("get_runtime_version")) != expected_onnx_runtime_version:
		backend.call("unload_model")
		last_error = "onnx_runtime_version_mismatch"
		return false
	loaded_deck = deck_key
	last_error = ""
	return true


func unload() -> void:
	if backend != null:
		backend.call("unload_model")
	loaded_deck = ""


func get_backend() -> Variant:
	return backend if backend != null and backend.call("is_loaded") else null


func _read_json(path: String, error_prefix: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		last_error = error_prefix + "_missing"
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		return parsed
	last_error = error_prefix + "_invalid"
	return {}
