class_name DeepAIRuntime
extends RefCounted

const MANIFEST_PATH := "res://data/ai_models_runtime.json"
const RELEASE_MANIFEST_PATH := "res://data/release_manifest.json"
const RUNTIME_FORMAT_VERSION := 4
const ENCODER_VERSION := 8
const CHECKPOINT_VERSION := 13
const PLANNER_VERSION := 3
const MODEL_VARIANT := "universal_infoset_transformer_v3"

var manifest: Dictionary = {}
var release_manifest: Dictionary = {}
var backend: Variant
var last_error := ""
var loaded_deck := ""
var loaded_model := ""
var runtime_enabled := false
var manifest_path := MANIFEST_PATH
var release_manifest_path := RELEASE_MANIFEST_PATH


func _init(
	p_manifest_path: String = MANIFEST_PATH,
	p_release_manifest_path: String = RELEASE_MANIFEST_PATH,
) -> void:
	manifest_path = p_manifest_path
	release_manifest_path = p_release_manifest_path
	release_manifest = _read_json(release_manifest_path, "release_manifest")
	manifest = _read_json(manifest_path, "runtime_manifest")
	runtime_enabled = bool(
		release_manifest.get("deep_runtime_enabled", false))
	if not runtime_enabled:
		last_error = "deep_runtime_disabled"
	elif not ClassDB.class_exists("OnnxInference"):
		last_error = "onnx_extension_unavailable"
	else:
		backend = ClassDB.instantiate("OnnxInference")


func is_available() -> bool:
	return (
		runtime_enabled
		and backend != null
		and not manifest.is_empty()
		and not release_manifest.is_empty()
	)


func load_for_deck(deck_key: String) -> bool:
	unload()
	if not runtime_enabled:
		last_error = "deep_runtime_disabled"
		return false
	if not is_available():
		if last_error.is_empty():
			last_error = "deep_runtime_unavailable"
		return false
	if not _release_contract_matches():
		return false
	if int(manifest.get("format_version", 0)) != RUNTIME_FORMAT_VERSION:
		last_error = "runtime_manifest_format_mismatch"
		return false
	if (
		int(manifest.get("opset", 0))
		!= int(Dictionary(release_manifest.get("onnx", {})).get("opset", 0))
		or str(manifest.get("onnx_runtime_version", ""))
		!= str(Dictionary(release_manifest.get(
			"onnx", {})).get("runtime_version", ""))
	):
		last_error = "runtime_onnx_contract_mismatch"
		return false
	var source_schemas_value: Variant = manifest.get("source_schemas", {})
	if not source_schemas_value is Dictionary:
		last_error = "source_schemas_invalid"
		return false
	var source_schemas: Dictionary = source_schemas_value
	var schemas: Dictionary = release_manifest.get("schemas", {})
	if (
		int(source_schemas.get("python_rules_version", 0))
		!= int(schemas.get("python_rules", 0))
		or int(source_schemas.get("python_action_version", 0))
		!= int(schemas.get("python_actions", 0))
		or int(source_schemas.get("python_encoder_version", 0))
		!= ENCODER_VERSION
	):
		last_error = "source_schemas_mismatch"
		return false
	var contract_value: Variant = manifest.get("contract", {})
	if not contract_value is Dictionary:
		last_error = "v3_contract_missing"
		return false
	var contract: Dictionary = contract_value
	if (
		int(contract.get("encoder_version", 0)) != ENCODER_VERSION
		or int(contract.get("checkpoint_version", 0)) != CHECKPOINT_VERSION
		or int(contract.get("deep_planner_version", 0)) != PLANNER_VERSION
		or str(contract.get("model_variant", "")) != MODEL_VARIANT
	):
		last_error = "v3_contract_mismatch"
		return false
	if not _planner_matches():
		return false
	var routes_value: Variant = manifest.get("deck_routes", {})
	var models_value: Variant = manifest.get("models", {})
	if not routes_value is Dictionary or not models_value is Dictionary:
		last_error = "universal_model_routes_invalid"
		return false
	var route := str(Dictionary(routes_value).get(deck_key, ""))
	if route != "universal":
		last_error = "model_route_missing"
		return false
	var row_value: Variant = Dictionary(models_value).get(route, {})
	if not row_value is Dictionary or Dictionary(row_value).is_empty():
		last_error = "universal_model_missing"
		return false
	var row: Dictionary = row_value
	if (
		str(row.get("model_variant", "")) != MODEL_VARIANT
		or int(row.get("checkpoint_version", 0)) != CHECKPOINT_VERSION
		or int(row.get("encoder_version", 0)) != ENCODER_VERSION
		or int(row.get("planner_version", 0)) != PLANNER_VERSION
	):
		last_error = "universal_model_schema_mismatch"
		return false
	var evidence_sha := str(
		Dictionary(manifest.get("deep_planner", {})).get(
			"evidence_sha256", "")).to_lower()
	if (
		evidence_sha.is_empty()
		or evidence_sha != str(
			Dictionary(release_manifest.get("deep_planner", {})).get(
				"evidence_sha256", "")).to_lower()
	):
		last_error = "model_evidence_mismatch"
		return false
	var model_manifest := {
		"format_version": RUNTIME_FORMAT_VERSION,
		"opset": int(manifest.get("opset", 0)),
		"model_variant": MODEL_VARIANT,
		"state_global_size": 192,
		"entity_slots": 160,
		"entity_numeric_size": 24,
		"entity_type_fields": 4,
		"candidate_numeric_size": 48,
		"candidate_ref_fields": 8,
		"onnx_sha256": str(row.get("onnx_sha256", "")),
	}
	if not backend.call(
		"load_model",
		str(row.get("onnx_path", "")),
		model_manifest,
	):
		last_error = str(backend.call("get_last_error"))
		return false
	if (
		str(backend.call("get_runtime_version"))
		!= str(Dictionary(release_manifest.get(
			"onnx", {})).get("runtime_version", ""))
	):
		backend.call("unload_model")
		last_error = "onnx_runtime_version_mismatch"
		return false
	loaded_deck = deck_key
	loaded_model = route
	last_error = ""
	return true


func unload() -> void:
	if backend != null:
		backend.call("unload_model")
	loaded_deck = ""
	loaded_model = ""


func get_backend() -> Variant:
	return backend if backend != null and backend.call("is_loaded") else null


func availability_reason() -> String:
	if is_available():
		return ""
	return last_error if not last_error.is_empty() else "deep_runtime_unavailable"


func _release_contract_matches() -> bool:
	var schemas_value: Variant = release_manifest.get("schemas", {})
	var deep_model_value: Variant = release_manifest.get("deep_model", {})
	if not schemas_value is Dictionary or not deep_model_value is Dictionary:
		last_error = "release_contract_invalid"
		return false
	var schemas: Dictionary = schemas_value
	var deep_model: Dictionary = deep_model_value
	if (
		int(schemas.get("encoder", 0)) != ENCODER_VERSION
		or int(schemas.get("checkpoint", 0)) != CHECKPOINT_VERSION
		or int(schemas.get("deep_planner", 0)) != PLANNER_VERSION
		or str(deep_model.get("variant", "")) != MODEL_VARIANT
		or not bool(deep_model.get("universal", false))
	):
		last_error = "release_contract_mismatch"
		return false
	return true


func _planner_matches() -> bool:
	var runtime_value: Variant = manifest.get("deep_planner", {})
	var release_value: Variant = release_manifest.get("deep_planner", {})
	if not runtime_value is Dictionary or not release_value is Dictionary:
		last_error = "deep_planner_manifest_invalid"
		return false
	var runtime: Dictionary = runtime_value
	var release: Dictionary = release_value
	for key in [
		"planner_id",
		"schema_version",
		"leaf_evaluator",
		"value_head_mode",
		"challenge_prior_weight",
		"full_turn_rollout",
		"c_puct",
		"training_simulations",
		"evidence_sha256",
	]:
		if runtime.get(key) != release.get(key):
			last_error = "deep_planner_manifest_mismatch"
			return false
	return (
		str(runtime.get("planner_id", "")) == InformationSetPUCT.PLANNER_ID
		and int(runtime.get("schema_version", 0))
		== InformationSetPUCT.SCHEMA_VERSION
		and is_equal_approx(
			float(runtime.get("c_puct", 0.0)),
			InformationSetPUCT.C_PUCT)
		and str(runtime.get("leaf_evaluator", "")) == "neural_wdl"
		and str(runtime.get("value_head_mode", "")) == "search_backup"
		and is_zero_approx(float(
			runtime.get("challenge_prior_weight", 1.0)))
		and not bool(runtime.get("full_turn_rollout", true))
	)


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
