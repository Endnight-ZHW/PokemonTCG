extends Node

signal status_changed(message: String)

const RELEASE_MANIFEST_PATH := "res://data/release_manifest.json"
const RULES_SCHEMA_VERSION := 6
const ACTION_SCHEMA_VERSION := 4
const PROTOCOL_VERSION := 6

var APP_VERSION := ""
var startup_checks: Dictionary = {}


func _init() -> void:
	APP_VERSION = _load_release_version()


func _ready() -> void:
	startup_checks = {
		"godot_version": Engine.get_version_info().get("string", "unknown"),
		"platform": OS.get_name(),
		"locale": TranslationServer.get_locale(),
	}
	status_changed.emit("PokemonTCG Godot client initialized")


func _load_release_version() -> String:
	var file := FileAccess.open(RELEASE_MANIFEST_PATH, FileAccess.READ)
	if file == null:
		push_error("Unable to open %s" % RELEASE_MANIFEST_PATH)
		return ""
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		push_error("Invalid release manifest: %s" % RELEASE_MANIFEST_PATH)
		return ""
	var version := str(Dictionary(parsed).get("version", "")).strip_edges()
	if version.is_empty():
		push_error("Release manifest has no version: %s" % RELEASE_MANIFEST_PATH)
	return version
