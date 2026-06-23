class_name PresentationDirector
extends Node

signal sequence_started(event_count: int)
signal event_started(event: Dictionary)
signal event_finished(event: Dictionary)
signal sequence_finished
signal floating_text_requested(text: String, target: Dictionary, color: Color)
signal burst_requested(kind: String, target: Dictionary, color: Color)
signal card_motion_requested(event: Dictionary, duration: float)
signal audio_requested(cue: String)
signal camera_impulse_requested(strength: float, duration: float)

@export_category("Playback Timing")
@export_group("Speed Modes")
@export_range(0.05, 2.0, 0.01) var cinematic_speed_scale := 1.0
@export_range(0.05, 2.0, 0.01) var standard_speed_scale := 0.72
@export_range(0.05, 2.0, 0.01) var fast_speed_scale := 0.38
@export_range(0.01, 1.0, 0.01) var reduced_motion_speed_scale := 0.08

var _queue: Array[Dictionary] = []
var _seen_event_ids: Dictionary = {}
var _playing := false
var _cancelled := false
var _speed_scale := 1.0
var _generation := 0


func is_playing() -> bool:
	return _playing


func pending_count() -> int:
	return _queue.size()


func play(events: Array[Dictionary]) -> void:
	if not is_inside_tree():
		return
	for event in events:
		var event_id := str(event.get("event_id", ""))
		if not event_id.is_empty() and _seen_event_ids.has(event_id):
			continue
		if not event_id.is_empty():
			_seen_event_ids[event_id] = true
		_queue.append(event.duplicate(true))
	_trim_seen()
	if not _playing and not _queue.is_empty():
		_run_queue()


func clear_for_resync() -> void:
	_generation += 1
	_cancelled = true
	_queue.clear()
	_playing = false
	sequence_finished.emit()


func set_speed_mode(mode: String) -> void:
	_speed_scale = {
		"cinematic": cinematic_speed_scale,
		"standard": standard_speed_scale,
		"fast": fast_speed_scale,
		"reduced": reduced_motion_speed_scale,
	}.get(mode, 1.0)


func _run_queue() -> void:
	var run_generation := _generation
	_playing = true
	_cancelled = false
	sequence_started.emit(_queue.size())
	while (
		not _queue.is_empty()
		and not _cancelled
		and run_generation == _generation
	):
		if not is_inside_tree() or get_tree() == null:
			_queue.clear()
			break
		var event: Dictionary = _queue.pop_front()
		event_started.emit(event)
		_dispatch(event)
		var duration := _duration_for(event)
		if duration > 0.0:
			var tree := get_tree()
			if tree == null:
				break
			await tree.create_timer(duration, true, false, true).timeout
		if run_generation != _generation:
			return
		event_finished.emit(event)
	if run_generation != _generation:
		return
	_playing = false
	if not _cancelled:
		sequence_finished.emit()


func _dispatch(event: Dictionary) -> void:
	var event_type := str(event.get("event_type", ""))
	var target: Dictionary = event.get("target", {})
	if target.get("slot", "") == "":
		target = event.get("source", {})
	var amount := int(event.get("amount", 0))
	var data: Dictionary = event.get("data", {})
	match event_type:
		"cards_drawn":
			audio_requested.emit("card_draw")
			card_motion_requested.emit(event, _duration_for(event))
		"cards_discarded":
			audio_requested.emit("card_discard")
			card_motion_requested.emit(event, _duration_for(event))
		"card_moved":
			audio_requested.emit("card_move")
			card_motion_requested.emit(event, _duration_for(event))
		"pokemon_played":
			audio_requested.emit("card_place")
			card_motion_requested.emit(event, _duration_for(event))
			burst_requested.emit("card_place", target, DesignTokens.CYAN)
		"trainer_played", "stadium_changed", "tool_attached":
			audio_requested.emit("card_place")
			card_motion_requested.emit(event, _duration_for(event))
			burst_requested.emit("trainer", target, DesignTokens.BLUE)
		"energy_attached":
			audio_requested.emit("energy_attach")
			card_motion_requested.emit(event, _duration_for(event))
			burst_requested.emit(
				"energy",
				target,
				DesignTokens.GOLD,
			)
		"pokemon_evolved":
			audio_requested.emit("evolution")
			camera_impulse_requested.emit(0.35, 0.28)
			burst_requested.emit("evolution", target, DesignTokens.CYAN)
			card_motion_requested.emit(event, _duration_for(event))
		"attack_declared":
			audio_requested.emit("attack_charge")
			camera_impulse_requested.emit(0.25, 0.2)
			burst_requested.emit("charge", event.get("source", {}), DesignTokens.GOLD)
		"damage_dealt", "damage_counters_placed":
			audio_requested.emit("attack_hit")
			camera_impulse_requested.emit(0.75, 0.24)
			floating_text_requested.emit(
				"-%d" % max(10, amount),
				target,
				DesignTokens.RED,
			)
			burst_requested.emit("impact", target, DesignTokens.RED)
		"healed":
			audio_requested.emit("heal")
			floating_text_requested.emit(
				"+%d" % max(10, amount),
				target,
				DesignTokens.GREEN,
			)
			burst_requested.emit("heal", target, DesignTokens.GREEN)
		"status_applied":
			audio_requested.emit("status")
			floating_text_requested.emit(
				str(data.get("status", "状态")),
				target,
				DesignTokens.status_color(str(data.get("status", ""))),
			)
		"retreat", "switched", "promoted":
			audio_requested.emit("card_move")
			card_motion_requested.emit(event, _duration_for(event))
		"pokemon_ko":
			audio_requested.emit("pokemon_ko")
			camera_impulse_requested.emit(1.0, 0.38)
			floating_text_requested.emit("击倒", target, DesignTokens.PURPLE)
			burst_requested.emit("ko", target, DesignTokens.PURPLE)
			card_motion_requested.emit(event, _duration_for(event))
		"prize_taken":
			audio_requested.emit("prize")
			card_motion_requested.emit(event, _duration_for(event))
		"coin_flip":
			audio_requested.emit("coin")
			burst_requested.emit("coin", target, DesignTokens.GOLD)
		"deck_shuffled":
			audio_requested.emit("card_move")
			var deck_target := {
				"player": int(data.get("player", event.get("actor", -1))),
				"zone": "deck",
			}
			burst_requested.emit("shuffle", deck_target, DesignTokens.CYAN)
		"turn_start":
			audio_requested.emit("turn_change")
			floating_text_requested.emit(
				"第 %d 回合" % int(data.get("turn", 0)),
				target,
				DesignTokens.GOLD,
			)
		"game_over":
			audio_requested.emit("victory")


func _duration_for(event: Dictionary) -> float:
	var event_type := str(event.get("event_type", ""))
	var base: float = float({
		"cards_drawn": 0.48,
		"cards_discarded": 0.68,
		"card_moved": 0.58,
		"pokemon_played": 0.62,
		"trainer_played": 0.62,
		"stadium_changed": 0.72,
		"energy_attached": 0.58,
		"pokemon_evolved": 1.55,
		"attack_declared": 0.72,
		"damage_dealt": 0.72,
		"damage_counters_placed": 0.52,
		"healed": 0.65,
		"status_applied": 0.58,
		"retreat": 0.72,
		"switched": 0.72,
		"promoted": 0.82,
		"pokemon_ko": 1.35,
		"prize_taken": 0.58,
		"coin_flip": 0.9,
		"turn_start": 0.8,
	}.get(event_type, 0.28))
	if _queue.size() > 8 and event_type not in [
		"pokemon_evolved",
		"attack_declared",
		"pokemon_ko",
	]:
		base *= 0.55
	return maxf(0.02, float(base) * _speed_scale)


func _trim_seen() -> void:
	if _seen_event_ids.size() <= 512:
		return
	var keys := _seen_event_ids.keys()
	for index in range(mini(256, keys.size())):
		_seen_event_ids.erase(keys[index])
