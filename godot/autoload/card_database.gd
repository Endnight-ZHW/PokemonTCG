extends Node

signal loaded
signal load_failed(message: String)

const CARDS_PATH := "res://data/cards.json"
const DECKS_PATH := "res://data/decks.json"
const EFFECTS_PATH := "res://data/effects.json"
const RELEASE_MANIFEST_PATH := "res://data/release_manifest.json"

var cards: Dictionary = {}
var decks: Dictionary = {}
var effects: Dictionary = {}
var release_manifest: Dictionary = {}
var is_loaded := false
var catalog: CardCatalog = CardCatalog.shared()


func _ready() -> void:
	load_all()


func load_all() -> bool:
	var datasets := {
		"effects": EFFECTS_PATH,
		"release_manifest": RELEASE_MANIFEST_PATH,
	}
	var loaded_values: Dictionary = {
		"cards": catalog.cards,
		"decks": catalog.decks,
	}
	for key in datasets:
		var result := _read_json(datasets[key])
		if not result["ok"]:
			load_failed.emit(result["error"])
			return false
		loaded_values[key] = result["value"]

	cards = loaded_values["cards"]
	decks = loaded_values["decks"]
	effects = loaded_values["effects"]
	release_manifest = loaded_values["release_manifest"]
	is_loaded = true
	loaded.emit()
	return true


func get_card(card_id: String) -> Dictionary:
	return Dictionary(cards.get(card_id, {}))


func get_deck(deck_key: String) -> Dictionary:
	return Dictionary(decks.get(deck_key, {}))


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "Unable to open %s" % path}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed == null:
		return {"ok": false, "error": "Invalid JSON in %s" % path}
	return {"ok": true, "value": parsed}
