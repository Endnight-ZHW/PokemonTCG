class_name CardCatalog
extends RefCounted

const CARDS_PATH := "res://data/cards.json"
const DECKS_PATH := "res://data/decks.json"

var cards: Dictionary = {}
var decks: Dictionary = {}


func _init() -> void:
	cards = _read_json(CARDS_PATH)
	decks = _read_json(DECKS_PATH)


func get_card(card_id: String) -> Dictionary:
	return Dictionary(cards.get(card_id, {}))


func get_deck(deck_key: String) -> Dictionary:
	return Dictionary(decks.get(deck_key, {}))


func expand_deck(deck_key: String) -> Array[String]:
	var result: Array[String] = []
	var deck := get_deck(deck_key)
	for row in deck.get("cards", []):
		for _index in range(int(row.get("count", 0))):
			result.append(str(row.get("card_id", "")))
	return result


func card_name(card_id: String) -> String:
	return str(get_card(card_id).get("name", card_id))


func is_pokemon(card_id: String) -> bool:
	return get_card(card_id).get("supertype", "") == "Pokémon"


func is_basic_pokemon(card_id: String) -> bool:
	var card := get_card(card_id)
	return card.get("supertype", "") == "Pokémon" and "Basic" in card.get("subtypes", [])


func is_stage1(card_id: String) -> bool:
	var card := get_card(card_id)
	return card.get("supertype", "") == "Pokémon" and "Stage 1" in card.get("subtypes", [])


func is_stage2(card_id: String) -> bool:
	var card := get_card(card_id)
	return card.get("supertype", "") == "Pokémon" and "Stage 2" in card.get("subtypes", [])


func is_energy(card_id: String) -> bool:
	return get_card(card_id).get("supertype", "") == "Energy"


func is_basic_energy(card_id: String) -> bool:
	var card := get_card(card_id)
	return card.get("supertype", "") == "Energy" and "Basic" in card.get("subtypes", [])


func is_special_energy(card_id: String) -> bool:
	var card := get_card(card_id)
	return card.get("supertype", "") == "Energy" and "Special" in card.get("subtypes", [])


func is_trainer(card_id: String) -> bool:
	return get_card(card_id).get("supertype", "") == "Trainer"


func is_item(card_id: String) -> bool:
	var card := get_card(card_id)
	return card.get("supertype", "") == "Trainer" and "Item" in card.get("subtypes", [])


func is_supporter(card_id: String) -> bool:
	var card := get_card(card_id)
	return card.get("supertype", "") == "Trainer" and "Supporter" in card.get("subtypes", [])


func is_stadium(card_id: String) -> bool:
	var card := get_card(card_id)
	return card.get("supertype", "") == "Trainer" and "Stadium" in card.get("subtypes", [])


func is_tool(card_id: String) -> bool:
	var card := get_card(card_id)
	return card.get("supertype", "") == "Trainer" and "Tool" in card.get("subtypes", [])


func provides_energy(card_id: String) -> Array[String]:
	var result: Array[String] = []
	result.assign(get_card(card_id).get("provides_energy", []))
	return result


func prize_value(card_id: String) -> int:
	return int(get_card(card_id).get("prize_value", 1))


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
				matches = is_pokemon(card_id) or is_energy(card_id)
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


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Unable to open %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		return parsed
	push_error("Invalid JSON dictionary in %s" % path)
	return {}
