extends Node

signal loaded
signal load_failed(message: String)

const CARDS_PATH := "res://data/cards.json"
const DECKS_PATH := "res://data/decks.json"
const EFFECTS_PATH := "res://data/effects.json"
const BUCKETS_PATH := "res://data/card_buckets.json"
const MODELS_PATH := "res://data/ai_models.json"

var cards: Dictionary = {}
var decks: Dictionary = {}
var effects: Dictionary = {}
var card_buckets: Dictionary = {}
var ai_models: Dictionary = {}
var is_loaded := false


func _ready() -> void:
	load_all()


func load_all() -> bool:
	var datasets := {
		"cards": CARDS_PATH,
		"decks": DECKS_PATH,
		"effects": EFFECTS_PATH,
		"card_buckets": BUCKETS_PATH,
		"ai_models": MODELS_PATH,
	}
	var loaded_values: Dictionary = {}
	for key in datasets:
		var result := _read_json(datasets[key])
		if not result["ok"]:
			load_failed.emit(result["error"])
			return false
		loaded_values[key] = result["value"]

	cards = loaded_values["cards"]
	decks = loaded_values["decks"]
	effects = loaded_values["effects"]
	card_buckets = loaded_values["card_buckets"]
	ai_models = loaded_values["ai_models"]
	is_loaded = true
	loaded.emit()
	return true


func get_card(card_id: String) -> Dictionary:
	return Dictionary(cards.get(card_id, {}))


func get_deck(deck_key: String) -> Dictionary:
	return Dictionary(decks.get(deck_key, {}))


func get_card_bucket(card_id: String) -> int:
	return int(card_buckets.get(card_id, 0))


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "Unable to open %s" % path}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed == null:
		return {"ok": false, "error": "Invalid JSON in %s" % path}
	return {"ok": true, "value": parsed}
