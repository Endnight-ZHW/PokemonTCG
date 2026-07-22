class_name AIStrategyRegistry
extends RefCounted

const DATA_PATH := "res://data/ai_strategies.json"
const CATALOG_SCHEMA := "ptcg.ai_strategy_catalog"
const CATALOG_VERSION := 1
const STRATEGY_SCHEMA := "ptcg.ai_deck_strategy"
const STRATEGY_VERSION := 1
const RELEASE_DECK_KEYS: Array[String] = [
	"colorless", "darkness", "dragon", "fighting", "fire",
	"grass", "lightning", "psychic", "steel", "water",
]

const GENERIC_SCRIPT := preload("res://ai/strategies/generic_strategy.gd")
const STRATEGY_SCRIPTS_BY_ID: Dictionary = {
	"fire_infernape_v1": preload("res://ai/strategies/fire_strategy.gd"),
	"water_greninja_v1": preload("res://ai/strategies/water_strategy.gd"),
	"psychic_xatu_v1": preload("res://ai/strategies/psychic_strategy.gd"),
	"lightning_pikachu_v1": preload("res://ai/strategies/lightning_strategy.gd"),
	"fighting_lucario_v1": preload("res://ai/strategies/fighting_strategy.gd"),
	"colorless_maushold_v1": preload("res://ai/strategies/colorless_strategy.gd"),
	"dragon_altaria_v1": preload("res://ai/strategies/dragon_strategy.gd"),
	"grass_torterra_v1": preload("res://ai/strategies/grass_strategy.gd"),
	"steel_zacian_zamazenta_v1": preload("res://ai/strategies/steel_strategy.gd"),
	"darkness_mabosstiff_v1": preload("res://ai/strategies/darkness_strategy.gd"),
}

static var _shared: AIStrategyRegistry

var _catalog: Dictionary = {}
var _strategies: Dictionary = {}
var _fallback: DeckStrategy
var _validation_errors: Array[String] = []


func _init(catalog_override: Dictionary = {}) -> void:
	var source := catalog_override.duplicate(true)
	if source.is_empty():
		source = _read_catalog(DATA_PATH)
	_install(source)


static func shared() -> AIStrategyRegistry:
	if _shared == null:
		_shared = AIStrategyRegistry.new()
	return _shared


func strategy_for(deck_key: String) -> DeckStrategy:
	var value: Variant = _strategies.get(deck_key)
	return value if value is DeckStrategy else _fallback


func profile_for(deck_key: String) -> Dictionary:
	return strategy_for(deck_key).profile()


func strategy_id_for(deck_key: String) -> String:
	return strategy_for(deck_key).strategy_id()


func known_deck_keys() -> Array[String]:
	var result: Array[String] = []
	for deck_key_value in _strategies:
		result.append(str(deck_key_value))
	result.sort()
	return result


func catalog_hash() -> String:
	return str(_catalog.get("content_hash", ""))


func is_valid() -> bool:
	return _validation_errors.is_empty() and known_deck_keys() == RELEASE_DECK_KEYS


func validation_errors() -> Array[String]:
	return _validation_errors.duplicate()


func _install(source: Dictionary) -> void:
	_validation_errors.clear()
	_strategies = {}
	if str(source.get("schema", "")) != CATALOG_SCHEMA:
		_validation_errors.append("AI strategy catalog schema is invalid")
	if int(source.get("version", 0)) != CATALOG_VERSION:
		_validation_errors.append("AI strategy catalog version is invalid")
	if str(source.get("content_hash", "")).length() != 64:
		_validation_errors.append("AI strategy catalog content hash is invalid")

	var archetypes: Dictionary = {}
	if source.get("deck_archetypes") is Dictionary:
		archetypes = Dictionary(source["deck_archetypes"]).duplicate(true)
	else:
		_validation_errors.append("AI strategy catalog archetypes are missing")
	if _sorted_string_keys(archetypes) != RELEASE_DECK_KEYS:
		_validation_errors.append("AI strategy catalog archetypes do not cover release decks")
	var fallback_profile := _fallback_profile(source)
	_fallback = GENERIC_SCRIPT.new(fallback_profile, archetypes)

	var rows: Dictionary = {}
	if source.get("strategies") is Dictionary:
		rows = source["strategies"]
	else:
		_validation_errors.append("AI strategy catalog strategies are missing")
	if _sorted_string_keys(rows) != RELEASE_DECK_KEYS:
		_validation_errors.append("AI strategy catalog does not cover release decks")
	for deck_key_value in rows:
		var deck_key := str(deck_key_value)
		var profile_value: Variant = rows[deck_key_value]
		if not profile_value is Dictionary:
			_validation_errors.append("AI strategy profile is not an object: %s" % deck_key)
			continue
		var profile: Dictionary = profile_value
		var error := _profile_error(deck_key, profile)
		if not error.is_empty():
			_validation_errors.append(error)
			continue
		var strategy_id := str(profile["strategy_id"])
		var strategy_script: Variant = STRATEGY_SCRIPTS_BY_ID.get(strategy_id)
		if strategy_script == null:
			_validation_errors.append("AI strategy script is missing: %s" % strategy_id)
			continue
		var strategy_value: Variant = strategy_script.new(profile, archetypes)
		if not strategy_value is DeckStrategy:
			_validation_errors.append("AI strategy script has an invalid base: %s" % strategy_id)
			continue
		_strategies[deck_key] = strategy_value

	if _strategies.size() != STRATEGY_SCRIPTS_BY_ID.size():
		_validation_errors.append(
			"AI strategy catalog must load exactly %d release strategies" % STRATEGY_SCRIPTS_BY_ID.size())
	_catalog = source.duplicate(true)
	_deep_make_read_only(_catalog)
	_strategies.make_read_only()


func _profile_error(deck_key: String, profile: Dictionary) -> String:
	if str(profile.get("schema", "")) != STRATEGY_SCHEMA:
		return "AI strategy schema is invalid: %s" % deck_key
	if int(profile.get("version", 0)) != STRATEGY_VERSION:
		return "AI strategy version is invalid: %s" % deck_key
	if str(profile.get("deck_key", "")) != deck_key:
		return "AI strategy deck key is invalid: %s" % deck_key
	if str(profile.get("strategy_id", "")).is_empty():
		return "AI strategy id is missing: %s" % deck_key
	if str(profile.get("content_hash", "")).length() != 64:
		return "AI strategy content hash is invalid: %s" % deck_key
	if str(profile.get("runtime_hook_hash", "")).length() != 64:
		return "AI strategy runtime hook hash is invalid: %s" % deck_key
	if not profile.get("card_roles") is Dictionary or Dictionary(profile["card_roles"]).is_empty():
		return "AI strategy card roles are missing: %s" % deck_key
	if not profile.get("stage_goals") is Array or Array(profile["stage_goals"]).is_empty():
		return "AI strategy stage goals are missing: %s" % deck_key
	if (
		not profile.get("golden_scenarios") is Array
		or Array(profile["golden_scenarios"]).size() < 8
		or Array(profile["golden_scenarios"]).size() > 12
	):
		return "AI strategy golden scenarios are invalid: %s" % deck_key
	if not profile.get("weights") is Dictionary or Dictionary(profile["weights"]).is_empty():
		return "AI strategy weights are missing: %s" % deck_key
	if not profile.get("matchup_weights") is Dictionary or Dictionary(profile["matchup_weights"]).is_empty():
		return "AI strategy matchup weights are missing: %s" % deck_key
	return ""


func _fallback_profile(source: Dictionary) -> Dictionary:
	var value: Variant = source.get("fallback")
	if value is Dictionary:
		var profile: Dictionary = value
		if (
			str(profile.get("schema", "")) == STRATEGY_SCHEMA
			and int(profile.get("version", 0)) == STRATEGY_VERSION
			and not str(profile.get("strategy_id", "")).is_empty()
		):
			return profile
	return {
		"schema": STRATEGY_SCHEMA,
		"version": STRATEGY_VERSION,
		"strategy_id": "generic_balanced_v1",
		"deck_key": "generic",
		"content_hash": "",
		"runtime_hook_hash": "",
		"card_roles": {},
		"stage_goals": [
			{"id": "setup", "priority": 100, "description": "Setup", "targets": {}},
			{"id": "develop", "priority": 80, "description": "Develop", "targets": {}},
			{"id": "closeout", "priority": 60, "description": "Closeout", "targets": {}},
		],
		"weights": {},
		"matchup_weights": {},
	}


static func _read_catalog(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func _sorted_string_keys(value: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for key_value in value:
		result.append(str(key_value))
	result.sort()
	return result


static func _deep_make_read_only(value: Variant) -> void:
	if value is Dictionary:
		var dictionary: Dictionary = value
		for nested_value in dictionary.values():
			_deep_make_read_only(nested_value)
		dictionary.make_read_only()
	elif value is Array:
		var array: Array = value
		for nested_value in array:
			_deep_make_read_only(nested_value)
		array.make_read_only()
