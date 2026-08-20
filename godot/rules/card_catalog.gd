class_name CardCatalog
extends RefCounted

const CARDS_PATH := "res://data/cards.json"
const DECKS_PATH := "res://data/decks.json"
const CARD_IR_PATH := "res://data/card_ir_v3.json"

static var _shared_cards: Dictionary = {}
static var _shared_decks: Dictionary = {}
static var _shared_card_ir: Dictionary = {}
static var _shared_loaded := false
static var _shared_load_count := 0
static var _shared_repository: CardCatalog

var cards: Dictionary = {}
var decks: Dictionary = {}
var card_ir: Dictionary = {}
var _read_only_repository := false
var _expanded_deck_cache: Dictionary = {}
var _card_supertype_cache: Dictionary = {}
var _card_subtypes_cache: Dictionary = {}
var _provides_energy_cache: Dictionary = {}
var _prize_value_cache: Dictionary = {}


func _init(isolated: bool = false, read_only: bool = false) -> void:
	_ensure_shared_data()
	if isolated:
		cards = _shared_cards.duplicate(true)
		decks = _shared_decks.duplicate(true)
		card_ir = _shared_card_ir.duplicate(true)
	else:
		# Normal callers share one parsed data set. Tests that inject synthetic cards
		# request an isolated catalog explicitly.
		cards = _shared_cards
		decks = _shared_decks
		card_ir = _shared_card_ir
	if read_only:
		if not isolated:
			cards = cards.duplicate(true)
			decks = decks.duplicate(true)
			card_ir = card_ir.duplicate(true)
		_prepare_read_only_repository()


static func shared() -> CardCatalog:
	"""Return the one deeply read-only catalog used by release runtime paths."""
	if _shared_repository == null:
		# The runtime repository owns one isolated, immutable snapshot; mutable
		# synthetic fixtures use an explicitly isolated catalog.
		_shared_repository = CardCatalog.new(true, true)
	return _shared_repository


func is_read_only_repository() -> bool:
	return (
		_read_only_repository
		and cards.is_read_only()
		and decks.is_read_only()
		and card_ir.is_read_only()
		and _expanded_deck_cache.is_read_only()
		and _card_supertype_cache.is_read_only()
		and _card_subtypes_cache.is_read_only()
		and _provides_energy_cache.is_read_only()
		and _prize_value_cache.is_read_only()
	)


func native_rules_catalog() -> Dictionary:
	## Release matches consume the source-mapped Card IR v3 envelope. Isolated
	## synthetic test catalogs may provide raw cards without release IR.
	var ir_cards: Variant = card_ir.get("cards")
	if (
		str(card_ir.get("format", "")) == "ptcg_card_ir/3"
		and int(card_ir.get("vm_ir_version", 0)) == 3
		and ir_cards is Dictionary
		and Dictionary(ir_cards).size() == cards.size()
	):
		var same_ids := true
		for card_id_value in cards:
			if not Dictionary(ir_cards).has(str(card_id_value)):
				same_ids = false
				break
		if same_ids:
			return {"cards": cards, "card_ir": card_ir}
	return cards


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
	if not _read_only_repository:
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
		if _read_only_repository:
			return cached
		_provides_energy_cache[card_id] = cached
	result.assign(_provides_energy_cache.get(card_id, []))
	return result


func prize_value(card_id: String) -> int:
	if not _prize_value_cache.has(card_id):
		var value := int(get_card(card_id).get("prize_value", 1))
		if _read_only_repository:
			return value
		_prize_value_cache[card_id] = value
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
		var value := str(get_card(card_id).get("supertype", ""))
		if _read_only_repository:
			return value
		_card_supertype_cache[card_id] = value
	return str(_card_supertype_cache[card_id])


func _card_has_subtype(card_id: String, subtype: String) -> bool:
	if not _card_subtypes_cache.has(card_id):
		var cached: Array[String] = []
		cached.assign(get_card(card_id).get("subtypes", []))
		if _read_only_repository:
			return subtype in cached
		_card_subtypes_cache[card_id] = cached
	return subtype in _card_subtypes_cache[card_id]


static func shared_load_count() -> int:
	return _shared_load_count


func _prepare_read_only_repository() -> void:
	# Fill every derived lookup before publishing the repository to worker
	# threads. Once frozen, known and unknown reads never mutate shared state.
	for deck_key_value in decks:
		expand_deck(str(deck_key_value))
	for card_id_value in cards:
		var card_id := str(card_id_value)
		_card_supertype(card_id)
		_card_has_subtype(card_id, "")
		provides_energy(card_id)
		prize_value(card_id)
	for value in [
		cards,
		decks,
		card_ir,
		_expanded_deck_cache,
		_card_supertype_cache,
		_card_subtypes_cache,
		_provides_energy_cache,
		_prize_value_cache,
	]:
		_deep_make_read_only(value)
	_read_only_repository = true


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


static func _ensure_shared_data() -> void:
	if _shared_loaded:
		return
	_shared_cards = _read_json(CARDS_PATH)
	_shared_decks = _read_json(DECKS_PATH)
	_shared_card_ir = _read_json(CARD_IR_PATH)
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
