extends Node

signal status_changed(message: String)

const APP_VERSION := "0.3.1"
const RULES_SCHEMA_VERSION := 3
const ACTION_SCHEMA_VERSION := 3
const PROTOCOL_VERSION := 3

var startup_checks: Dictionary = {}


func _ready() -> void:
	startup_checks = {
		"godot_version": Engine.get_version_info().get("string", "unknown"),
		"platform": OS.get_name(),
		"locale": TranslationServer.get_locale(),
	}
	status_changed.emit("PokemonTCG Godot client initialized")
