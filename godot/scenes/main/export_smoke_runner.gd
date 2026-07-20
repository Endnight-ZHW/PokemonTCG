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
	var fallback := str(deep_runtime.release_manifest.get("deep_fallback", ""))
	var release_decks: Array[String] = []
	release_decks.assign(deep_runtime.release_manifest.get("release_decks", []))
	if (
		deep_runtime.runtime_enabled
		or fallback != "challenge"
		or release_decks.is_empty()
		or not _legacy_onnx_assets_absent(release_decks)
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
	var deep_fallback_ok := (
		not release_decks.is_empty()
		and not bool(release_manifest.get("deep_runtime_enabled", true))
		and str(release_manifest.get("deep_fallback", "")) == "challenge"
		and int(release_manifest.get("compatible_model_count", -1)) == 0
		and int(release_manifest.get("legacy_model_count", -1))
		== int(release_manifest.get("model_count", -2))
		and int(release_manifest.get("legacy_model_count", -1)) == release_decks.size()
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
	return _success(
		(
			"PHASE6_EXPORT_RELEASE_OK version=%s settings=1 cache=1 "
			+ "licenses=1 ui_resources=1 deep=disabled fallback=challenge "
			+ "compatible_models=0 legacy_models=%d onnx_assets=0"
		)
		% [str(services.get("app_version", "")), release_decks.size()]
	)


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
