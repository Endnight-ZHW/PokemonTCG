class_name CandidateRuntimeVerifier
extends RefCounted

const FORMAT_VERSION := 1
const DEFAULT_ENCODER_FIXTURE := (
	"res://tests/fixtures/ai_encoder_golden.json"
)


func verify(
	runtime_path: String,
	release_path: String,
	candidate_path: String,
	encoder_fixture_path: String = DEFAULT_ENCODER_FIXTURE,
) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var runtime := DeepAIRuntime.new(runtime_path, release_path)
	var release_decks: Array[String] = []
	release_decks.assign(runtime.release_manifest.get("release_decks", []))
	var model_rows_value: Variant = runtime.manifest.get("models", {})
	var model_rows: Dictionary = (
		model_rows_value if model_rows_value is Dictionary else {}
	)
	var rows := {}
	var errors: Array[String] = []
	var encoder_golden_passed := _encoder_golden_passed(
		encoder_fixture_path)
	if not encoder_golden_passed:
		errors.append("encoder_golden")
	if (
		not runtime.runtime_enabled
		or release_decks.size()
		!= int(runtime.release_manifest.get("model_count", 0))
		or model_rows.size() != release_decks.size()
	):
		errors.append("candidate_manifest_contract")

	for deck_key in release_decks:
		var row_value: Variant = model_rows.get(deck_key, {})
		var row: Dictionary = (
			row_value if row_value is Dictionary else {}
		)
		var model_path := str(row.get("onnx_path", ""))
		var actual_hash := FileAccess.get_sha256(model_path)
		var loaded := runtime.load_for_deck(deck_key)
		var scenarios: Array = []
		if loaded:
			var backend: Variant = runtime.get_backend()
			scenarios.append(_infer_scenario(
				backend, runtime.manifest, false))
			scenarios.append(_infer_scenario(
				backend, runtime.manifest, true))
			for scenario in scenarios:
				if not bool(Dictionary(scenario).get("passed", false)):
					errors.append("%s:inference" % deck_key)
					break
		else:
			errors.append("%s:%s" % [deck_key, runtime.last_error])
		rows[deck_key] = {
			"loaded": loaded,
			"runtime_error": runtime.last_error,
			"onnx_path": model_path,
			"onnx_sha256": actual_hash,
			"expected_onnx_sha256": str(row.get("onnx_sha256", "")),
			"hash_matches": (
				not actual_hash.is_empty()
				and actual_hash == str(row.get("onnx_sha256", ""))
			),
			"scenarios": scenarios,
		}
		if not bool(rows[deck_key]["hash_matches"]):
			errors.append("%s:hash" % deck_key)
		runtime.unload()

	var backend_available := ClassDB.class_exists("OnnxInference")
	return {
		"format_version": FORMAT_VERSION,
		"kind": "candidate_runtime_inference_v1",
		"platform": OS.get_name().to_lower(),
		"architecture": Engine.get_architecture_name(),
		"native_extension": backend_available,
		"encoder_golden_passed": encoder_golden_passed,
		"candidate_manifest_sha256": FileAccess.get_sha256(candidate_path),
		"runtime_manifest_sha256": FileAccess.get_sha256(runtime_path),
		"release_manifest_sha256": FileAccess.get_sha256(release_path),
		"deep_planner": runtime.manifest.get("deep_planner", {}),
		"model_count": rows.size(),
		"models": rows,
		"errors": errors,
		"passed": errors.is_empty() and backend_available,
		"elapsed_ms": round(
			float(Time.get_ticks_usec() - started_usec) / 1000.0 * 1000.0
		) / 1000.0,
	}


func _infer_scenario(
	backend: Variant,
	manifest: Dictionary,
	empty_slots: bool,
) -> Dictionary:
	if backend == null:
		return {"passed": false, "error": "backend_unavailable"}
	var state_size := int(manifest.get("state_numeric_size", 0))
	var state_slots := int(manifest.get("state_card_slots", 0))
	var candidate_size := int(manifest.get("action_numeric_size", 0))
	var state_numeric := PackedFloat32Array()
	state_numeric.resize(state_size)
	var state_cards := PackedInt64Array()
	state_cards.resize(state_slots)
	if not empty_slots:
		for index in range(state_slots):
			state_cards[index] = 1 + index % 31
	var action_numeric := PackedFloat32Array()
	action_numeric.resize(candidate_size * 2)
	var choice_numeric := PackedFloat32Array()
	choice_numeric.resize(candidate_size * 2)
	var inferred: Dictionary = backend.call(
		"infer",
		state_numeric,
		state_cards,
		action_numeric,
		PackedInt64Array([1, 2]),
		choice_numeric,
		PackedInt64Array([3, 4]),
	)
	var finite: bool = is_finite(float(inferred.get("value", NAN)))
	for output_name in ["action_logits", "choice_logits"]:
		for value in inferred.get(output_name, []):
			finite = finite and is_finite(float(value))
	var passed: bool = (
		bool(inferred.get("success", false))
		and inferred.get("action_logits", []).size() == 2
		and inferred.get("choice_logits", []).size() == 2
		and finite
		and str(backend.call("get_execution_provider"))
		== "CPUExecutionProvider"
	)
	return {
		"name": "empty_slots" if empty_slots else "ordinary",
		"passed": passed,
		"error": str(inferred.get("error", "")),
		"finite": finite,
		"action_outputs": inferred.get("action_logits", []).size(),
		"choice_outputs": inferred.get("choice_logits", []).size(),
		"execution_provider": str(
			backend.call("get_execution_provider")),
	}


func _encoder_golden_passed(fixture_path: String) -> bool:
	var fixture_file := FileAccess.open(fixture_path, FileAccess.READ)
	if fixture_file == null:
		return false
	var parsed: Variant = JSON.parse_string(fixture_file.get_as_text())
	if not parsed is Dictionary:
		return false
	var fixture: Dictionary = parsed
	var catalog := CardCatalog.new()
	var encoder := AIActionEncoder.new(catalog)
	var observation: Dictionary = fixture.get("observation", {})
	var encoded_state := encoder.encode_observation(
		observation, str(fixture.get("deck_key", "")))
	if (
		not _deep_equal(
			encoded_state.get("numeric", []),
			Dictionary(fixture.get("expected", {})).get(
				"state_numeric", []))
		or not _deep_equal(
			encoded_state.get("card_ids", []),
			Dictionary(fixture.get("expected", {})).get(
				"state_cards", []))
	):
		return false
	var actions: Array = fixture.get("actions", [])
	var expected_actions: Array = Dictionary(
		fixture.get("expected", {})).get("actions", [])
	if actions.size() != expected_actions.size():
		return false
	for index in range(actions.size()):
		var action := GameAction.from_dict(actions[index])
		if not _deep_equal(
			encoder.encode_action(
				observation, action, str(fixture.get("deck_key", ""))),
			expected_actions[index],
		):
			return false
	var choice := ChoiceView.from_dict(fixture.get("choice", {}))
	var expected_choices: Array = Dictionary(
		fixture.get("expected", {})).get("choices", [])
	if choice.options.size() != expected_choices.size():
		return false
	for index in range(choice.options.size()):
		if not _deep_equal(
			encoder.encode_choice(
				observation, choice, choice.options[index], index),
			expected_choices[index],
		):
			return false
	return true


func _deep_equal(left: Variant, right: Variant) -> bool:
	if (
		(left is int or left is float)
		and (right is int or right is float)
	):
		return is_equal_approx(float(left), float(right))
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size():
			return false
		for key in left:
			if not right.has(key) or not _deep_equal(left[key], right[key]):
				return false
		return true
	if left is Array and right is Array:
		if left.size() != right.size():
			return false
		for index in range(left.size()):
			if not _deep_equal(left[index], right[index]):
				return false
		return true
	return left == right
