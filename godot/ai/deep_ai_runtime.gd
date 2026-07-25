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
var expected_checkpoint_version := 0
var expected_state_numeric_size := 0
var expected_state_card_slots := 0
var expected_action_numeric_size := 0
var expected_card_semantic_size := 0
var expected_card_identity_mode := ""
var expected_card_vocab_version := 0
var expected_card_vocab_size := 0
var expected_card_vocab_sha256 := ""
var expected_onnx_opset := 0
var expected_onnx_runtime_version := ""
var expected_deep_planner_version := 0
var expected_deep_planner: Dictionary = {}
var expected_deep_model: Dictionary = {}
var runtime_enabled := false
var manifest_path := MANIFEST_PATH
var release_manifest_path := RELEASE_MANIFEST_PATH


func _init(
	p_manifest_path: String = MANIFEST_PATH,
	p_release_manifest_path: String = RELEASE_MANIFEST_PATH,
) -> void:
	manifest_path = p_manifest_path
	release_manifest_path = p_release_manifest_path
	release_manifest = _read_json(
		release_manifest_path, "release_manifest")
	if not release_manifest.is_empty():
		runtime_enabled = bool(release_manifest.get("deep_runtime_enabled", false))
		var schemas: Dictionary = release_manifest.get("schemas", {})
		var onnx: Dictionary = release_manifest.get("onnx", {})
		var deep_encoder: Dictionary = release_manifest.get(
			"deep_encoder", {})
		expected_python_rules_version = int(schemas.get("python_rules", 0))
		expected_python_action_version = int(schemas.get("python_actions", 0))
		expected_python_encoder_version = int(schemas.get("encoder", 0))
		expected_checkpoint_version = int(schemas.get("checkpoint", 0))
		expected_state_numeric_size = int(
			deep_encoder.get("state_numeric_size", 0))
		expected_state_card_slots = int(
			deep_encoder.get("state_card_slots", 0))
		expected_action_numeric_size = int(
			deep_encoder.get("action_numeric_size", 0))
		expected_card_semantic_size = int(
			deep_encoder.get("card_semantic_size", 0))
		expected_card_identity_mode = str(
			deep_encoder.get("card_identity_mode", ""))
		expected_card_vocab_version = int(
			schemas.get("card_vocab", 0))
		expected_card_vocab_size = int(
			deep_encoder.get("card_vocab_size", 0))
		expected_card_vocab_sha256 = str(
			deep_encoder.get("card_vocab_sha256", "")).to_lower()
		expected_deep_planner_version = int(
			schemas.get("deep_planner", 0))
		expected_deep_planner = Dictionary(
			release_manifest.get("deep_planner", {})).duplicate(true)
		expected_deep_model = Dictionary(
			release_manifest.get("deep_model", {})).duplicate(true)
		expected_onnx_opset = int(onnx.get("opset", 0))
		expected_onnx_runtime_version = str(onnx.get("runtime_version", ""))
	manifest = _read_json(manifest_path, "runtime_manifest")
	if not runtime_enabled:
		last_error = "deep_runtime_disabled"
	elif ClassDB.class_exists("OnnxInference"):
		backend = ClassDB.instantiate("OnnxInference")
	else:
		last_error = "onnx_extension_unavailable"


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
		return false
	var semantic_sizes_value: Variant = manifest.get(
		"semantic_feature_sizes", {})
	if not semantic_sizes_value is Dictionary:
		last_error = "runtime_release_manifest_mismatch"
		return false
	var semantic_sizes: Dictionary = semantic_sizes_value
	if (
		int(manifest.get("opset", 0)) != expected_onnx_opset
		or str(manifest.get("onnx_runtime_version", ""))
		!= expected_onnx_runtime_version
		or int(manifest.get("state_numeric_size", 0))
		!= expected_state_numeric_size
		or int(manifest.get("state_card_slots", 0))
		!= expected_state_card_slots
		or int(manifest.get("action_numeric_size", 0))
		!= expected_action_numeric_size
		or int(semantic_sizes.get("known_card", 0))
		!= expected_card_semantic_size
		or str(manifest.get("card_identity_mode", ""))
		!= expected_card_identity_mode
		or int(manifest.get("card_vocab_version", 0))
		!= expected_card_vocab_version
		or int(manifest.get("card_vocab_size", 0))
		!= expected_card_vocab_size
		or str(manifest.get(
			"card_vocab_sha256", "")).to_lower()
		!= expected_card_vocab_sha256
	):
		last_error = "runtime_release_manifest_mismatch"
		return false
	var runtime_planner_value: Variant = manifest.get("deep_planner", {})
	if (
		not runtime_planner_value is Dictionary
		or not _deep_planner_matches(
			expected_deep_planner, Dictionary(runtime_planner_value))
	):
		last_error = "deep_planner_manifest_mismatch"
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
	if int(row.get("checkpoint_version", 0)) != expected_checkpoint_version:
		last_error = "model_checkpoint_version_mismatch"
		return false
	if (
		int(row.get("card_vocab_version", 0))
		!= expected_card_vocab_version
		or int(row.get("card_vocab_size", 0))
		!= expected_card_vocab_size
		or str(row.get("card_vocab_sha256", "")).to_lower()
		!= expected_card_vocab_sha256
	):
		last_error = "model_card_vocab_mismatch"
		return false
	var row_model_config_value: Variant = row.get("model_config", {})
	var expected_model_config_value: Variant = expected_deep_model.get(
		"config", {})
	if (
		expected_deep_model.is_empty()
		or not row_model_config_value is Dictionary
		or not expected_model_config_value is Dictionary
		or int(expected_deep_model.get("checkpoint_version", 0))
		!= expected_checkpoint_version
		or int(expected_deep_model.get("encoder_version", 0))
		!= expected_python_encoder_version
		or int(expected_deep_model.get("card_vocab_version", 0))
		!= expected_card_vocab_version
		or int(expected_deep_model.get("card_vocab_size", 0))
		!= expected_card_vocab_size
		or str(expected_deep_model.get(
			"card_vocab_sha256", "")).to_lower()
		!= expected_card_vocab_sha256
	):
		last_error = "deep_model_manifest_mismatch"
		return false
	var row_model_config: Dictionary = row_model_config_value
	var expected_model_config: Dictionary = expected_model_config_value
	if (
		row_model_config.size() != expected_model_config.size()
		or not _dictionary_values_match(
			row_model_config, expected_model_config)
	):
		last_error = "model_config_mismatch"
		return false
	var expected_cross_attention := (
		str(expected_deep_model.get("variant", ""))
		== "v6_cross_attention"
	)
	if (
		str(expected_deep_model.get("variant", ""))
		not in ["v6_pooled", "v6_cross_attention"]
		or bool(row_model_config.get(
			"candidate_cross_attention", false))
		!= expected_cross_attention
	):
		last_error = "model_variant_mismatch"
		return false
	var evidence_sha := str(
		expected_deep_planner.get("evidence_sha256", "")).to_lower()
	if (
		evidence_sha.is_empty()
		or str(row.get("evidence_sha256", "")).to_lower() != evidence_sha
	):
		last_error = "model_evidence_mismatch"
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


func availability_reason() -> String:
	if is_available():
		return ""
	return last_error if not last_error.is_empty() else "deep_runtime_unavailable"


func _dictionary_values_match(
	actual: Dictionary,
	expected: Dictionary,
) -> bool:
	for key in expected:
		if not actual.has(key) or actual.get(key) != expected.get(key):
			return false
	return true


func _deep_planner_matches(
	release_value: Dictionary,
	runtime_value: Dictionary,
) -> bool:
	if (
		expected_deep_planner_version != DeepRootISMCTS.SCHEMA_VERSION
		or int(release_value.get("schema_version", 0))
		!= expected_deep_planner_version
	):
		return false
	for key in [
		"schema_version",
		"planner_id",
		"root_inference_calls",
		"neural_prior_weight",
		"challenge_prior_weight",
		"simulations",
		"c_puct",
		"max_depth",
		"opponent_branch_limit",
		"watchdog_seconds",
		"value_head_mode",
		"leaf_evaluator",
		"visit_tiebreak",
		"evidence_sha256",
	]:
		if release_value.get(key) != runtime_value.get(key):
			return false
	return (
		str(release_value.get("planner_id", ""))
		== DeepRootISMCTS.PLANNER_ID
		and int(release_value.get("simulations", 0))
		== DeepRootISMCTS.SIMULATIONS
		and int(release_value.get("max_depth", 0))
		== DeepRootISMCTS.MAX_DEPTH
		and int(release_value.get("opponent_branch_limit", 0))
		== DeepRootISMCTS.OPPONENT_BRANCH_LIMIT
		and is_equal_approx(
			float(release_value.get("c_puct", 0.0)),
			DeepRootISMCTS.C_PUCT)
		and is_equal_approx(
			float(release_value.get("neural_prior_weight", 0.0)),
			DeepRootISMCTS.NEURAL_PRIOR_WEIGHT)
		and is_equal_approx(
			float(release_value.get("watchdog_seconds", 0.0)),
			float(DeepRootISMCTS.WATCHDOG_USEC) / 1000000.0)
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
