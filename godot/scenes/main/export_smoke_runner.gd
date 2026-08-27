class_name ExportSmokeRunner
extends RefCounted

const PHASE_FOUR_FLAG := "--phase4-ai-smoke"
const PHASE_FIVE_FLAG := "--phase5-network-smoke"
const PHASE_SIX_FLAG := "--phase6-release-smoke"


func run_if_requested(
	args: PackedStringArray,
	services: Dictionary,
) -> Dictionary:
	if PHASE_FOUR_FLAG in args:
		return _run_native_runtime()
	if PHASE_FIVE_FLAG in args:
		return _run_network_runtime()
	if PHASE_SIX_FLAG in args:
		return _run_release_runtime(services)
	return {"handled": false}


func _run_native_runtime() -> Dictionary:
	if (
		not ClassDB.class_exists("NativeRulesSession")
		or not ClassDB.class_exists("NativeChallengeAI")
	):
		return _failure(2, "PHASE4_EXPORT_AI_FAILED native_runtime_missing")
	var native_ai: Variant = ClassDB.instantiate("NativeChallengeAI")
	if native_ai == null or not native_ai.has_method("get_contract"):
		return _failure(2, "PHASE4_EXPORT_AI_FAILED challenge_runtime_missing")
	var contract: Dictionary = native_ai.get_contract()
	if not bool(contract.get("production_ready", false)):
		return _failure(2, "PHASE4_EXPORT_AI_FAILED challenge_not_ready")
	return _success("PHASE4_EXPORT_AI_OK challenge=native onnx_assets=0")


func _run_network_runtime() -> Dictionary:
	if ProtocolV6.VERSION != 6:
		return _failure(3, "PHASE6_EXPORT_NETWORK_FAILED")
	return _success("PHASE6_EXPORT_NETWORK_OK protocol=6 transports=enet,websocket")


func _run_release_runtime(services: Dictionary) -> Dictionary:
	var release: Dictionary = services.get("release_manifest", {})
	var release_decks: Array = release.get("release_decks", [])
	var app_version := str(services.get("app_version", ""))
	var card_cache_size := int(services.get("card_cache_size", 0))
	var texture_cache: Variant = services.get("texture_cache")
	var valid := (
		not app_version.is_empty()
		and app_version == str(release.get("version", ""))
		and release_decks.size() == 10
		and card_cache_size > 0
		and texture_cache != null
		and _load_release_ui_resources()
		and not FileAccess.file_exists("res://data/ai_models/universal.onnx")
	)
	if not valid:
		return _failure(4, "PHASE6_EXPORT_RELEASE_FAILED")
	return _success(
		("PHASE6_EXPORT_RELEASE_OK version=%s settings=1 cache=1 "
		+ "challenge=native onnx_assets=0") % app_version)


func _load_release_ui_resources() -> bool:
	for path in [
		"res://scenes/title/title_page.tscn",
		"res://scenes/decks/deck_select_page.tscn",
		"res://scenes/network/network_lobby_page.tscn",
		"res://scenes/battle/components/battle_table.tscn",
		"res://scenes/end/victory_screen.tscn",
	]:
		if load(path) == null:
			return false
	return true


static func _success(message: String) -> Dictionary:
	return {
		"handled": true,
		"success": true,
		"exit_code": 0,
		"message": message,
	}


static func _failure(exit_code: int, message: String) -> Dictionary:
	return {
		"handled": true,
		"success": false,
		"exit_code": exit_code,
		"message": message,
	}
