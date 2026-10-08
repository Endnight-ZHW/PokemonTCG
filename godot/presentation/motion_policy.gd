class_name MotionPolicy
extends RefCounted

const PROFILE: BattleAnimationProfile = preload("res://presentation/default_battle_animation.tres")
const DEFAULT_MODE: String = preload("res://autoload/app_settings.gd").DEFAULT_ANIMATION_MODE


static func mode() -> String:
	var settings := _settings()
	return str(settings.get("animation_mode")) if settings != null else DEFAULT_MODE


static func duration(kind: String, speed_mode: String = "") -> float:
	return PROFILE.duration(kind, mode() if speed_mode.is_empty() else speed_mode)


static func event_duration(event: Dictionary, speed_mode: String = "", queue_size: int = 0) -> float:
	var resolved := mode() if speed_mode.is_empty() else speed_mode
	var kind := str(event.get("event_type", ""))
	if kind == "cards_selected" and int(event.get("amount", 0)) <= 0:
		return 0.0
	var readable := kind == "cards_revealed" or (kind == "cards_selected" and str(event.get("visibility", "public")) == "public")
	if readable:
		return PROFILE.reduced_public_hold if resolved == "reduced" else maxf(PROFILE.public_reveal_floor, duration("cards_revealed", resolved))
	if kind in ["turn_end", "checkup", "turn_start", "turn_order_chosen", "setup_revealed", "deck_exhausted"]:
		var timing := announcement_timings(resolved)
		return timing.x + timing.y + timing.z
	var result := duration(kind, resolved)
	if kind == "damage_dealt" and str(Dictionary(event.get("data", {})).get("damage_kind", "")) == "attack_damage":
		result = duration("attack_impact", resolved)
	if queue_size > 8 and kind not in ["pokemon_evolved", "attack_declared", "pokemon_ko"]:
		result *= 0.55
	return result


static func announcement_timings(speed_mode: String = "") -> Vector3:
	var resolved := mode() if speed_mode.is_empty() else speed_mode
	if resolved == "reduced":
		return Vector3(0.0, PROFILE.reduced_announcement_hold, 0.0)
	var total := maxf(0.24, duration("announcement", resolved))
	return Vector3(total * 0.24, total * 0.60, total * 0.16)


static func landing_duration(event_type: String, total: float) -> float:
	var fraction := 0.40 if event_type == "pokemon_evolved" else 0.36 if event_type == "energy_attached" else 0.22
	return maxf(0.0, total) * fraction


static func reduced() -> bool:
	return mode() == "reduced"


static func _settings() -> Node:
	# MotionPolicy is also compiled as a dependency of command-line SceneTree
	# contracts, before autoload singleton identifiers are guaranteed to be in
	# lexical scope. Resolve the runtime node instead of coupling this reusable
	# RefCounted policy to that compile order.
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		return (main_loop as SceneTree).root.get_node_or_null("AppSettings")
	return null
