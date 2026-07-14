class_name MotionPolicy
extends RefCounted

const BASE_DURATIONS := {
	"hand_reflow": 0.22,
	"draw_flight": 0.42,
	"draw_landing": 0.12,
	"card_place": 0.46,
	"energy_attach": 0.42,
	"switch": 0.48,
	"evolution": 0.65,
	"damage": 0.26,
	"ko": 0.75,
	"return": 0.28,
	"multi_card_stagger": 0.10,
	"panel": 0.16,
}

const MODE_SCALES := {
	"cinematic": 1.0,
	"standard": 0.82,
	"fast": 0.58,
	"reduced": 0.0,
}


static func duration(kind: String, mode: String = "") -> float:
	var resolved_mode := mode
	if resolved_mode.is_empty():
		var settings := _settings()
		resolved_mode = (
			str(settings.get("animation_mode"))
			if settings != null
			else "cinematic"
		)
	var scale: float = float(MODE_SCALES.get(resolved_mode, 1.0))
	return float(BASE_DURATIONS.get(kind, 0.0)) * scale


static func reduced() -> bool:
	var settings := _settings()
	if settings == null:
		return false
	return (
		str(settings.get("animation_mode")) == "reduced"
		or bool(settings.get("reduced_motion"))
	)


static func _settings() -> Node:
	# MotionPolicy is also compiled as a dependency of command-line SceneTree
	# contracts, before autoload singleton identifiers are guaranteed to be in
	# lexical scope. Resolve the runtime node instead of coupling this reusable
	# RefCounted policy to that compile order.
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		return (main_loop as SceneTree).root.get_node_or_null("AppSettings")
	return null
