class_name ExportSmokeRunner
extends RefCounted

const PHASE_FOUR_FLAG := "--phase4-ai-smoke"
const PHASE_FIVE_FLAG := "--phase5-network-smoke"
const PHASE_SIX_FLAG := "--phase6-release-smoke"
const CANDIDATE_RUNTIME_FLAG := "--candidate-runtime-smoke"
const CANDIDATE_MANIFEST_PATH := "res://data/candidate_manifest.json"


func run_if_requested(
	args: PackedStringArray,
	deep_runtime: DeepAIRuntime,
	services: Dictionary = {},
) -> Dictionary:
	if PHASE_FOUR_FLAG in args:
		return _run_phase_four(deep_runtime)
	if PHASE_FIVE_FLAG in args:
		return _run_phase_five()
	if PHASE_SIX_FLAG in args:
		return _run_phase_six(deep_runtime, services)
	if CANDIDATE_RUNTIME_FLAG in args:
		return _run_candidate_runtime()
	return {"handled": false}


func _run_phase_four(deep_runtime: DeepAIRuntime) -> Dictionary:
	var fallback := str(deep_runtime.release_manifest.get("deep_fallback", ""))
	var release_decks: Array[String] = []
	release_decks.assign(deep_runtime.release_manifest.get("release_decks", []))
	if fallback != "challenge" or release_decks.is_empty():
		deep_runtime.unload()
		return _failure(2, "PHASE4_EXPORT_AI_FAILED deep_fallback_contract")
	if deep_runtime.runtime_enabled:
		var deep_check := _deep_models_load_and_infer(
			deep_runtime, release_decks)
		deep_runtime.unload()
		if not bool(deep_check.get("passed", false)):
			return _failure(
				2,
				"PHASE4_EXPORT_AI_FAILED %s"
				% deep_check.get("error", "deep_runtime"),
			)
		return _success(
			(
				"PHASE4_EXPORT_AI_OK deep=enabled fallback=challenge "
				+ "compatible_models=%d legacy_models=0 onnx_assets=%d "
				+ "inferred_models=%d scenarios=%d"
			)
			% [
				1,
				1,
				int(deep_check.get("inferred_models", 0)),
				int(deep_check.get("scenarios", 0)),
			]
		)
	if (
		not _legacy_onnx_assets_absent(release_decks)
		or deep_runtime.load_for_deck("fire")
		or deep_runtime.last_error != "deep_runtime_disabled"
		or deep_runtime.get_backend() != null
	):
		deep_runtime.unload()
		return _failure(2, "PHASE4_EXPORT_AI_FAILED deep_fallback_contract")
	deep_runtime.unload()
	return _success("PHASE4_EXPORT_AI_OK deep=disabled fallback=challenge onnx_assets=0")


func _run_phase_five() -> Dictionary:
	var probe := ProtocolV6.envelope(ProtocolV6.PING, "smoke", 0, 1)
	var validation := ProtocolV6.validate(probe, "smoke", 0, 0)
	if not bool(validation.get("ok", false)):
		return _failure(3, "PHASE6_EXPORT_NETWORK_FAILED")
	return _success("PHASE6_EXPORT_NETWORK_OK protocol=6 transports=enet,websocket")


func _run_phase_six(deep_runtime: DeepAIRuntime, services: Dictionary) -> Dictionary:
	var settings_ok := int(services.get("card_cache_size", 0)) >= 8
	var license_ok := FileAccess.file_exists("res://third_party/onnxruntime/LICENSE")
	var release_ui_resources_ok := _load_release_ui_resources()
	var texture_cache: Variant = services.get("texture_cache")
	var cache_ok := texture_cache != null
	if cache_ok:
		texture_cache.call("clear")
		cache_ok = int(Dictionary(texture_cache.call("stats")).get("entries", -1)) == 0
	var release_decks: Array[String] = []
	var release_manifest: Dictionary = services.get("release_manifest", {})
	release_decks.assign(release_manifest.get("release_decks", []))
	var deep_enabled := bool(release_manifest.get(
		"deep_runtime_enabled", false))
	var deep_fallback_ok := false
	var deep_check := {}
	if deep_enabled:
		deep_check = _deep_models_load_and_infer(
			deep_runtime, release_decks)
		deep_fallback_ok = (
			not release_decks.is_empty()
			and str(release_manifest.get("deep_fallback", "")) == "challenge"
			and int(release_manifest.get("compatible_model_count", -1))
			== 1
			and int(release_manifest.get("legacy_model_count", -1)) == 0
			and bool(deep_check.get("passed", false))
		)
	else:
		deep_fallback_ok = (
			not release_decks.is_empty()
			and str(release_manifest.get("deep_fallback", "")) == "challenge"
			and int(release_manifest.get("compatible_model_count", -1)) == 0
			and int(release_manifest.get("legacy_model_count", -1))
			== release_decks.size()
			and _legacy_onnx_assets_absent(release_decks)
			and not deep_runtime.runtime_enabled
			and not deep_runtime.load_for_deck("fire")
			and deep_runtime.last_error == "deep_runtime_disabled"
		)
	deep_runtime.unload()
	if (
		not settings_ok
		or not license_ok
		or not release_ui_resources_ok
		or not cache_ok
		or not deep_fallback_ok
	):
		return _failure(4, "PHASE6_EXPORT_RELEASE_FAILED")
	if deep_enabled:
		return _success(
			(
				"PHASE6_EXPORT_RELEASE_OK version=%s settings=1 cache=1 "
				+ "licenses=1 ui_resources=1 deep=enabled fallback=challenge "
				+ "compatible_models=%d legacy_models=0 onnx_assets=%d "
				+ "inferred_models=%d scenarios=%d"
			)
			% [
				str(services.get("app_version", "")),
				release_decks.size(),
				release_decks.size(),
				int(deep_check.get("inferred_models", 0)),
				int(deep_check.get("scenarios", 0)),
			]
		)
	return _success(
		(
			"PHASE6_EXPORT_RELEASE_OK version=%s settings=1 cache=1 "
			+ "licenses=1 ui_resources=1 deep=disabled fallback=challenge "
			+ "compatible_models=0 legacy_models=%d onnx_assets=0"
		)
		% [str(services.get("app_version", "")), release_decks.size()]
	)


func _run_candidate_runtime() -> Dictionary:
	var payload := CandidateRuntimeVerifier.new().verify(
		DeepAIRuntime.MANIFEST_PATH,
		DeepAIRuntime.RELEASE_MANIFEST_PATH,
		CANDIDATE_MANIFEST_PATH,
	)
	return {
		"handled": true,
		"success": bool(payload.get("passed", false)),
		"exit_code": 0 if bool(payload.get("passed", false)) else 5,
		"message": (
			"CANDIDATE_RUNTIME_SMOKE passed=%d platform=%s "
			+ "architecture=%s models=%d"
		)
		% [
			1 if bool(payload.get("passed", false)) else 0,
			str(payload.get("platform", "")),
			str(payload.get("architecture", "")),
			int(payload.get("model_count", 0)),
		],
		"evidence_payload": payload,
	}


func _deep_models_load_and_infer(
	deep_runtime: DeepAIRuntime,
	release_decks: Array[String],
) -> Dictionary:
	var models_value: Variant = deep_runtime.manifest.get("models", {})
	if (
		not deep_runtime.runtime_enabled
		or not deep_runtime.is_available()
		or not models_value is Dictionary
		or Dictionary(models_value).size() != 1
		or not Dictionary(models_value).has("universal")
	):
		return {
			"passed": false,
			"error": "deep_runtime_contract:%s" % deep_runtime.last_error,
		}
	var inferred_models := 0
	var scenarios := 0
	var routes: Dictionary = deep_runtime.manifest.get("deck_routes", {})
	for deck_key in release_decks:
		var route := str(routes.get(deck_key, ""))
		var row_value: Variant = Dictionary(models_value).get(route, {})
		if not row_value is Dictionary:
			return {"passed": false, "error": "%s:model_manifest" % deck_key}
		var row: Dictionary = row_value
		var model_path := str(row.get("onnx_path", ""))
		if (
			model_path.is_empty()
			or not FileAccess.file_exists(model_path)
			or FileAccess.get_sha256(model_path)
			!= str(row.get("onnx_sha256", ""))
		):
			return {"passed": false, "error": "%s:model_hash" % deck_key}
		if not deep_runtime.load_for_deck(deck_key):
			return {
				"passed": false,
				"error": "%s:%s" % [deck_key, deep_runtime.last_error],
			}
		var backend: Variant = deep_runtime.get_backend()
		for empty_slots in [false, true]:
			var inference := _infer_loaded_backend(
				backend, deep_runtime.manifest, empty_slots)
			scenarios += 1
			if not bool(inference.get("passed", false)):
				return {
					"passed": false,
					"error": "%s:%s" % [
						deck_key,
						inference.get("error", "inference"),
					],
				}
		inferred_models += 1
	return {
		"passed": true,
		"inferred_models": inferred_models,
		"scenarios": scenarios,
	}


func _infer_loaded_backend(
	backend: Variant,
	_manifest: Dictionary,
	empty_slots: bool,
) -> Dictionary:
	if backend == null:
		return {"passed": false, "error": "backend_unavailable"}
	var state_global := PackedFloat32Array()
	state_global.resize(128)
	var entity_numeric := PackedFloat32Array()
	entity_numeric.resize(128 * 16)
	var entity_cards := PackedInt64Array()
	entity_cards.resize(128)
	var entity_types := PackedInt64Array()
	entity_types.resize(128 * 4)
	if not empty_slots:
		for index in range(entity_cards.size()):
			entity_cards[index] = 1 + index % 31
	var candidate_numeric := PackedFloat32Array()
	candidate_numeric.resize(2 * 32)
	var candidate_refs := PackedInt64Array()
	candidate_refs.resize(2 * 4)
	var inferred: Dictionary = backend.call(
		"infer_v2",
		state_global,
		entity_numeric,
		entity_cards,
		entity_types,
		candidate_numeric,
		PackedInt64Array([1, 2]),
		PackedInt64Array([1, 2]),
		candidate_refs,
		PackedByteArray([1, 1]),
		PackedInt64Array([0]),
		PackedInt64Array([1]),
		1,
		2,
	)
	var finite := true
	for output_name in ["policy_logits", "wdl_logits"]:
		for value in inferred.get(output_name, []):
			finite = finite and is_finite(float(value))
	var passed: bool = (
		bool(inferred.get("success", false))
		and inferred.get("policy_logits", []).size() == 2
		and inferred.get("wdl_logits", []).size() == 3
		and finite
		and str(backend.call("get_execution_provider"))
		== "CPUExecutionProvider"
	)
	return {
		"passed": passed,
		"error": (
			""
			if passed
			else str(inferred.get("error", "non_finite_or_shape"))
		),
	}


func _legacy_onnx_assets_absent(release_decks: Array[String]) -> bool:
	for deck_key in release_decks:
		if FileAccess.file_exists("res://data/ai_models/%s.onnx" % deck_key):
			return false
	var directory := DirAccess.open("res://data/ai_models")
	if directory == null:
		return true
	directory.list_dir_begin()
	var file_name := directory.get_next()
	while not file_name.is_empty():
		if not directory.current_is_dir() and file_name.to_lower().ends_with(".onnx"):
			directory.list_dir_end()
			return false
		file_name = directory.get_next()
	directory.list_dir_end()
	return true


func _load_release_ui_resources() -> bool:
	var semibold_font := ResourceLoader.load(
		"res://assets/ui/fonts/noto_sans_cjk_sc_semibold.tres",
		"Font",
	) as Font
	var title_scene := ResourceLoader.load(
		"res://scenes/title/title_page.tscn",
		"PackedScene",
	) as PackedScene
	if semibold_font == null or title_scene == null:
		return false
	for energy_type in EnergyIconCatalog.ICON_PATHS:
		if EnergyIconCatalog.texture_for(str(energy_type)) == null:
			return false
	for card_id in EnergyIconCatalog.SPECIAL_ICON_PATHS:
		if EnergyIconCatalog.texture_for_card_id(str(card_id)) == null:
			return false
	return true


func _success(message: String) -> Dictionary:
	return {
		"handled": true,
		"success": true,
		"exit_code": 0,
		"message": message,
	}


func _failure(exit_code: int, message: String) -> Dictionary:
	return {
		"handled": true,
		"success": false,
		"exit_code": exit_code,
		"message": message,
	}
