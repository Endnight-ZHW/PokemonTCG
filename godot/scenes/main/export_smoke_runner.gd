class_name ExportSmokeRunner
extends RefCounted

const PHASE_FOUR_FLAG := "--phase4-ai-smoke"
const PHASE_FIVE_FLAG := "--phase5-network-smoke"
const PHASE_SIX_FLAG := "--phase6-release-smoke"


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
	return {"handled": false}


func _run_phase_four(deep_runtime: DeepAIRuntime) -> Dictionary:
	if not deep_runtime.load_for_deck("fire"):
		return _failure(2, "PHASE4_EXPORT_AI_FAILED %s" % deep_runtime.last_error)
	var backend: Variant = deep_runtime.get_backend()
	if backend == null:
		deep_runtime.unload()
		return _failure(2, "PHASE4_EXPORT_AI_FAILED runtime_unavailable")
	var message := (
		"PHASE4_EXPORT_AI_OK provider=%s runtime=%s"
		% [
			backend.call("get_execution_provider"),
			backend.call("get_runtime_version"),
		]
	)
	deep_runtime.unload()
	return _success(message)


func _run_phase_five() -> Dictionary:
	var probe := ProtocolV3.envelope(ProtocolV3.PING, "smoke", 0, 1)
	var validation := ProtocolV3.validate(probe, "smoke", 0, 0)
	if not bool(validation.get("ok", false)):
		return _failure(3, "PHASE5_EXPORT_NETWORK_FAILED")
	return _success("PHASE5_EXPORT_NETWORK_OK protocol=3 transports=enet,websocket")


func _run_phase_six(deep_runtime: DeepAIRuntime, services: Dictionary) -> Dictionary:
	var settings_ok := int(services.get("card_cache_size", 0)) >= 8
	var license_ok := FileAccess.file_exists("res://third_party/onnxruntime/LICENSE")
	var texture_cache: Variant = services.get("texture_cache")
	var cache_ok := texture_cache != null
	if cache_ok:
		texture_cache.call("clear")
		cache_ok = int(Dictionary(texture_cache.call("stats")).get("entries", -1)) == 0
	var release_decks: Array[String] = []
	var release_manifest: Dictionary = services.get("release_manifest", {})
	release_decks.assign(release_manifest.get("release_decks", []))
	var model_count_ok := (
		release_decks.size()
		== int(release_manifest.get("model_count", -1))
	)
	var inference_ok := model_count_ok and not release_decks.is_empty()
	var state_numeric := PackedFloat32Array()
	state_numeric.resize(int(deep_runtime.manifest.get("state_numeric_size", 0)))
	var state_cards := PackedInt64Array()
	state_cards.resize(int(deep_runtime.manifest.get("state_card_slots", 0)))
	var action_numeric := PackedFloat32Array()
	action_numeric.resize(int(deep_runtime.manifest.get("action_numeric_size", 0)))
	var action_cards := PackedInt64Array([0])
	var choice_numeric := PackedFloat32Array()
	choice_numeric.resize(int(deep_runtime.manifest.get("action_numeric_size", 0)))
	var choice_cards := PackedInt64Array([0])
	if (
		state_numeric.is_empty()
		or state_cards.is_empty()
		or action_numeric.is_empty()
		or choice_numeric.is_empty()
	):
		inference_ok = false
	for deck_key in release_decks:
		if not inference_ok or not deep_runtime.load_for_deck(deck_key):
			inference_ok = false
			break
		var backend: Variant = deep_runtime.get_backend()
		if backend == null:
			inference_ok = false
			break
		var result: Dictionary = backend.call(
			"infer",
			state_numeric,
			state_cards,
			action_numeric,
			action_cards,
			choice_numeric,
			choice_cards,
		)
		var finite := is_finite(float(result.get("value", NAN)))
		for output_name in ["action_logits", "choice_logits"]:
			for value in result.get(output_name, []):
				finite = finite and is_finite(float(value))
		if (
			not bool(result.get("success", false))
			or result.get("action_logits", []).size() != 1
			or result.get("choice_logits", []).size() != 1
			or not finite
		):
			inference_ok = false
			break
		deep_runtime.unload()
	deep_runtime.unload()
	if not settings_ok or not license_ok or not cache_ok or not inference_ok:
		return _failure(4, "PHASE6_EXPORT_RELEASE_FAILED")
	return _success(
		"PHASE6_EXPORT_RELEASE_OK version=%s settings=1 cache=1 licenses=1 models=%d"
		% [str(services.get("app_version", "")), release_decks.size()]
	)


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
