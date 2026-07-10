class_name CardCatalog
extends RefCounted

const CARDS_PATH := "res://data/cards.json"
const DECKS_PATH := "res://data/decks.json"

static var _shared_cards: Dictionary = {}
static var _shared_decks: Dictionary = {}
static var _shared_loaded := false
static var _shared_load_count := 0

var cards: Dictionary = {}
var decks: Dictionary = {}
var _expanded_deck_cache: Dictionary = {}
var _card_supertype_cache: Dictionary = {}
var _card_subtypes_cache: Dictionary = {}
var _provides_energy_cache: Dictionary = {}
var _prize_value_cache: Dictionary = {}


func _init(isolated: bool = false) -> void:
	_ensure_shared_data()
	if isolated:
		cards = _shared_cards.duplicate(true)
		decks = _shared_decks.duplicate(true)
	else:
		# Runtime catalogs are read-only views over one parsed data set. Tests that
		# inject synthetic cards can request an isolated catalog explicitly.
		cards = _shared_cards
		decks = _shared_decks


func get_card(card_id: String) -> Dictionary:
	return Dictionary(cards.get(card_id, {}))


func get_deck(deck_key: String) -> Dictionary:
	return Dictionary(decks.get(deck_key, {}))


func expand_deck(deck_key: String) -> Array[String]:
	if _expanded_deck_cache.has(deck_key):
		var cached: Array = _expanded_deck_cache[deck_key]
		var cached_copy: Array[String] = []
		cached_copy.assign(cached.duplicate())
		return cached_copy
	var result: Array[String] = []
	var deck := get_deck(deck_key)
	for row in deck.get("cards", []):
		for _index in range(int(row.get("count", 0))):
			result.append(str(row.get("card_id", "")))
	_expanded_deck_cache[deck_key] = result.duplicate()
	return result


func card_name(card_id: String) -> String:
	return str(get_card(card_id).get("name", card_id))


func is_pokemon(card_id: String) -> bool:
	return _card_supertype(card_id) == "Pokémon"


func is_basic_pokemon(card_id: String) -> bool:
	return _card_supertype(card_id) == "Pokémon" and _card_has_subtype(card_id, "Basic")


func is_stage1(card_id: String) -> bool:
	return _card_supertype(card_id) == "Pokémon" and _card_has_subtype(card_id, "Stage 1")


func is_stage2(card_id: String) -> bool:
	return _card_supertype(card_id) == "Pokémon" and _card_has_subtype(card_id, "Stage 2")


func is_energy(card_id: String) -> bool:
	return _card_supertype(card_id) == "Energy"


func is_basic_energy(card_id: String) -> bool:
	return _card_supertype(card_id) == "Energy" and _card_has_subtype(card_id, "Basic")


func is_special_energy(card_id: String) -> bool:
	return _card_supertype(card_id) == "Energy" and _card_has_subtype(card_id, "Special")


func is_trainer(card_id: String) -> bool:
	return _card_supertype(card_id) == "Trainer"


func is_item(card_id: String) -> bool:
	return _card_supertype(card_id) == "Trainer" and _card_has_subtype(card_id, "Item")


func is_supporter(card_id: String) -> bool:
	return _card_supertype(card_id) == "Trainer" and _card_has_subtype(card_id, "Supporter")


func is_stadium(card_id: String) -> bool:
	return _card_supertype(card_id) == "Trainer" and _card_has_subtype(card_id, "Stadium")


func is_tool(card_id: String) -> bool:
	return _card_supertype(card_id) == "Trainer" and _card_has_subtype(card_id, "Tool")


func provides_energy(card_id: String) -> Array[String]:
	var result: Array[String] = []
	if not _provides_energy_cache.has(card_id):
		var cached: Array[String] = []
		cached.assign(get_card(card_id).get("provides_energy", []))
		_provides_energy_cache[card_id] = cached
	result.assign(_provides_energy_cache[card_id])
	return result


func prize_value(card_id: String) -> int:
	if not _prize_value_cache.has(card_id):
		_prize_value_cache[card_id] = int(get_card(card_id).get("prize_value", 1))
	return int(_prize_value_cache[card_id])


func filter_cards(card_ids: Array[String], filter_type: String, filter_name: String = "") -> Array[String]:
	var result: Array[String] = []
	for card_id in card_ids:
		var card := get_card(card_id)
		if not filter_name.is_empty() and card.get("name", "") != filter_name:
			continue
		var matches := false
		match filter_type:
			"", "any":
				matches = true
			"basic_pokemon":
				matches = is_basic_pokemon(card_id)
			"pokemon":
				matches = is_pokemon(card_id)
			"basic", "basic_energy":
				matches = is_basic_energy(card_id)
			"energy":
				matches = is_energy(card_id)
			"supporter":
				matches = is_supporter(card_id)
			"item":
				matches = is_item(card_id)
			"item_or_tool":
				matches = is_item(card_id) or is_tool(card_id)
			"pokemon_and_energy":
				matches = is_pokemon(card_id) or is_basic_energy(card_id)
			"grass_pokemon":
				matches = is_pokemon(card_id) and "Grass" in card.get("energy_types", [])
			"water_pokemon_and_energy":
				matches = (
					(is_pokemon(card_id) and "Water" in card.get("energy_types", []))
					or (is_basic_energy(card_id) and "Water" in provides_energy(card_id))
				)
			"lightning_energy":
				matches = is_basic_energy(card_id) and "Lightning" in provides_energy(card_id)
			_:
				matches = true
		if matches:
			result.append(card_id)
	return result


func _card_supertype(card_id: String) -> String:
	if not _card_supertype_cache.has(card_id):
		_card_supertype_cache[card_id] = str(get_card(card_id).get("supertype", ""))
	return str(_card_supertype_cache[card_id])


func _card_has_subtype(card_id: String, subtype: String) -> bool:
	if not _card_subtypes_cache.has(card_id):
		var cached: Array[String] = []
		cached.assign(get_card(card_id).get("subtypes", []))
		_card_subtypes_cache[card_id] = cached
	return subtype in _card_subtypes_cache[card_id]


static func shared_load_count() -> int:
	return _shared_load_count


static func _ensure_shared_data() -> void:
	if _shared_loaded:
		return
	_shared_cards = _read_json(CARDS_PATH)
	_shared_decks = _read_json(DECKS_PATH)
	_shared_loaded = true
	_shared_load_count += 1


static func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Unable to open %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		return parsed
	push_error("Invalid JSON dictionary in %s" % path)
	return {}
