class_name PresentationDirector
extends Node

class EventCompletion:
	extends RefCounted

	signal completed

	var fallback_duration := 0.0
	var _held := false
	var _finished := false


	func _init(duration: float = 0.0) -> void:
		fallback_duration = maxf(0.0, duration)


	func hold() -> void:
		if not _finished:
			_held = true


	func is_held() -> bool:
		return _held


	func is_finished() -> bool:
		return _finished


	func finish() -> void:
		if _finished:
			return
		_finished = true
		completed.emit()


	func arm_fallback(tree: SceneTree) -> void:
		if _finished or _held:
			return
		if tree == null or fallback_duration <= 0.0:
			finish()
			return
		tree.create_timer(
			fallback_duration,
			true,
			false,
			true,
		).timeout.connect(finish, CONNECT_ONE_SHOT)

signal sequence_started(event_count: int)
signal event_started(event: Dictionary)
signal event_finished(event: Dictionary)
signal sequence_finished
signal event_completion_requested(event: Dictionary, completion: EventCompletion)
signal floating_text_requested(text: String, target: Dictionary, color: Color)
signal burst_requested(kind: String, target: Dictionary, color: Color)
signal card_motion_requested(event: Dictionary, duration: float)
signal audio_requested(cue: String)
signal camera_impulse_requested(strength: float, duration: float)
## This signal schedules metadata for the card-motion executor. It must not play
## the feedback immediately: the executor owns the exact contact frame and
## should emit the requested burst/camera impulse when the proxy lands.
signal card_landing_feedback_scheduled(event: Dictionary, feedback: Dictionary)
signal event_ignored(event: Dictionary)

const FEEDBACK_CHANNEL_KEY := "feedback_channel"
const FEEDBACK_CHANNEL_ANNOUNCEMENT := "announcement"
const ANNOUNCEMENT_EVENT_TYPES := ["turn_end", "checkup", "turn_start"]
const ANNOUNCEMENT_DURATIONS := {
	"cinematic": 0.46,
	"standard": 0.37,
	"fast": 0.27,
	"reduced": 0.22,
}
const STATUS_DISPLAY_NAMES := {
	"POISONED": "中毒",
	"BURNED": "灼伤",
	"ASLEEP": "睡眠",
	"PARALYZED": "麻痹",
	"CONFUSED": "混乱",
}
const EVENT_DURATIONS := {
	"cards_drawn": 0.54,
	"cards_discarded": 0.48,
	"card_moved": 0.46,
	"cards_selected": 0.42,
	"pokemon_played": 0.46,
	"trainer_played": 0.46,
	"stadium_changed": 0.50,
	"tool_attached": 0.46,
	"energy_attached": 0.46,
	"pokemon_evolved": 0.65,
	"attack_declared": 0.30,
	"confusion_failed": 0.34,
	"damage_dealt": 0.26,
	"damage_counters_placed": 0.26,
	"damage_prevented": 0.28,
	"healed": 0.30,
	"status_applied": 0.28,
	"retreat": 0.46,
	"switched": 0.46,
	"promoted": 0.48,
	"pokemon_ko": 0.75,
	"prize_taken": 0.42,
	"deck_shuffled": 0.54,
	"coin_flip": 0.50,
	"turn_end": 0.20,
	"checkup": 0.22,
	"turn_start": 0.35,
	"game_over": 0.45,
}

@export_category("Playback Timing")
@export_group("Speed Modes")
@export_range(0.05, 2.0, 0.01) var cinematic_speed_scale := 1.0
@export_range(0.05, 2.0, 0.01) var standard_speed_scale := 0.82
@export_range(0.05, 2.0, 0.01) var fast_speed_scale := 0.58
@export_range(0.0, 1.0, 0.01) var reduced_motion_speed_scale := 0.0

var _queue: Array[Dictionary] = []
var _seen_event_ids: Dictionary = {}
var _playing := false
var _cancelled := false
var _speed_scale := 1.0
var _speed_mode := "cinematic"
var _generation := 0
var _active_completion: EventCompletion
var _active_feedback_group: MotionGroup
var _feedback_registration_open := false


func is_playing() -> bool:
	return _playing


func pending_count() -> int:
	return _queue.size()


func has_handler(event_type: String) -> bool:
	return PresentationEvent.canonical_event_type(event_type) in EVENT_DURATIONS


func wait_until_idle() -> void:
	if _playing:
		await sequence_finished


## Feedback signal handlers call this synchronously after creating their
## MotionHandle. Non-card events then use the real visual lifetime as their
## barrier instead of guessing with a Timer. Card-motion events already own a
## completion barrier; their feedback is bounded to finish within that motion.
func register_feedback_motion(handle: MotionHandle) -> bool:
	if (
		handle == null
		or handle.is_finished()
		or not _feedback_registration_open
		or _active_feedback_group == null
	):
		return false
	_active_feedback_group.add(handle)
	return true


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
	_feedback_registration_open = false
	if _active_feedback_group != null:
		_active_feedback_group.cancel()
		_active_feedback_group = null
	if _active_completion != null:
		_active_completion.finish()
		_active_completion = null
	_playing = false
	sequence_finished.emit()


func set_speed_mode(mode: String) -> void:
	_speed_mode = mode if mode in ANNOUNCEMENT_DURATIONS else "cinematic"
	_speed_scale = {
		"cinematic": cinematic_speed_scale,
		"standard": standard_speed_scale,
		"fast": fast_speed_scale,
		"reduced": reduced_motion_speed_scale,
	}.get(_speed_mode, 1.0)


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
		var duration := _duration_for(event)
		var completion := EventCompletion.new(duration)
		_active_completion = completion
		var feedback_group := MotionGroup.new()
		_active_feedback_group = feedback_group
		_feedback_registration_open = true
		event_completion_requested.emit(event, completion)
		_dispatch(event)
		_feedback_registration_open = false
		feedback_group.seal()
		if not feedback_group.is_completed() and not completion.is_held():
			completion.hold()
			feedback_group.completed.connect(
				_on_feedback_group_completed.bind(completion),
				CONNECT_ONE_SHOT,
			)
		completion.arm_fallback(get_tree())
		if not completion.is_finished():
			await completion.completed
		if _active_completion == completion:
			_active_completion = null
		if _active_feedback_group == feedback_group:
			_active_feedback_group = null
		if run_generation != _generation:
			return
		event_finished.emit(event)
	if run_generation != _generation:
		return
	_playing = false
	if not _cancelled:
		sequence_finished.emit()


func _dispatch(event: Dictionary) -> void:
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	var target: Dictionary = event.get("target", {})
	if (
		str(target.get("slot", "")).is_empty()
		and str(target.get("zone", "")).is_empty()
	):
		target = event.get("source", {})
	var source: Dictionary = event.get("source", {})
	var amount := int(event.get("amount", 0))
	var data: Dictionary = event.get("data", {})
	match event_type:
		"cards_drawn":
			audio_requested.emit("card_draw")
			card_motion_requested.emit(event, _duration_for(event))
		"cards_discarded":
			audio_requested.emit("card_discard")
			if not str(source.get("attachment_type", "")).is_empty():
				burst_requested.emit(
					"attachment_release",
					source,
					DesignTokens.GOLD,
				)
			card_motion_requested.emit(event, _duration_for(event))
		"card_moved":
			audio_requested.emit("card_move")
			card_motion_requested.emit(event, _duration_for(event))
		"cards_selected":
			if amount > 0:
				audio_requested.emit("card_move")
				card_motion_requested.emit(event, _duration_for(event))
		"pokemon_played":
			audio_requested.emit("card_place")
			_schedule_card_landing_feedback(
				event,
				"card_place",
				DesignTokens.CYAN,
			)
			card_motion_requested.emit(event, _duration_for(event))
		"trainer_played", "stadium_changed", "tool_attached":
			audio_requested.emit("card_place")
			_schedule_card_landing_feedback(
				event,
				"trainer",
				DesignTokens.BLUE,
			)
			card_motion_requested.emit(event, _duration_for(event))
		"energy_attached":
			audio_requested.emit("energy_attach")
			if not str(source.get("slot", "")).is_empty():
				burst_requested.emit(
					"attachment_release",
					source,
					DesignTokens.GOLD,
				)
			_schedule_card_landing_feedback(
				event,
				"energy",
				DesignTokens.GOLD,
			)
			card_motion_requested.emit(event, _duration_for(event))
		"pokemon_evolved":
			audio_requested.emit("evolution")
			_schedule_card_landing_feedback(
				event,
				"evolution",
				DesignTokens.CYAN,
				0.35,
				0.28,
			)
			card_motion_requested.emit(event, _duration_for(event))
		"attack_declared":
			audio_requested.emit("attack_charge")
			camera_impulse_requested.emit(
				0.25,
				_bounded_camera_duration(event, 0.2),
			)
			burst_requested.emit("charge", event.get("source", {}), DesignTokens.GOLD)
		"confusion_failed":
			audio_requested.emit("attack_hit")
			camera_impulse_requested.emit(
				0.48,
				_bounded_camera_duration(event, 0.2),
			)
			floating_text_requested.emit(
				"混乱 -%d" % max(30, amount),
				target,
				DesignTokens.PURPLE,
			)
			burst_requested.emit("status", target, DesignTokens.PURPLE)
		"damage_dealt", "damage_counters_placed":
			audio_requested.emit("attack_hit")
			camera_impulse_requested.emit(
				0.75,
				_bounded_camera_duration(event, 0.24),
			)
			floating_text_requested.emit(
				"-%d" % max(10, amount),
				target,
				DesignTokens.RED,
			)
			burst_requested.emit("impact", target, DesignTokens.RED)
		"damage_prevented":
			audio_requested.emit("status")
			floating_text_requested.emit("伤害无效", target, DesignTokens.CYAN)
			burst_requested.emit("shield", target, DesignTokens.CYAN)
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
			var status := str(data.get("status", ""))
			floating_text_requested.emit(
				_status_display_name(status),
				target,
				DesignTokens.status_color(status),
			)
		"retreat", "switched", "promoted":
			audio_requested.emit("card_move")
			card_motion_requested.emit(event, _duration_for(event))
		"pokemon_ko":
			audio_requested.emit("pokemon_ko")
			camera_impulse_requested.emit(
				1.0,
				_bounded_camera_duration(event, 0.38),
			)
			var ko_target := _ko_feedback_target(event, source, target)
			floating_text_requested.emit("击倒", ko_target, DesignTokens.PURPLE)
			burst_requested.emit("ko", ko_target, DesignTokens.PURPLE)
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
			card_motion_requested.emit(event, _duration_for(event))
			burst_requested.emit("shuffle", deck_target, DesignTokens.CYAN)
		"turn_start":
			audio_requested.emit("turn_change")
			floating_text_requested.emit(
				"第 %d 回合" % int(data.get("turn", 0)),
				_feedback_target(target, FEEDBACK_CHANNEL_ANNOUNCEMENT),
				DesignTokens.GOLD,
			)
		"turn_end":
			floating_text_requested.emit(
				"回合结束",
				_feedback_target(target, FEEDBACK_CHANNEL_ANNOUNCEMENT),
				DesignTokens.BLUE,
			)
		"checkup":
			audio_requested.emit("status")
			floating_text_requested.emit(
				"宝可梦检查",
				_feedback_target(target, FEEDBACK_CHANNEL_ANNOUNCEMENT),
				DesignTokens.CYAN,
			)
		"game_over":
			audio_requested.emit("victory")
		_:
			event_ignored.emit(event)


func _feedback_target(target: Dictionary, channel: String) -> Dictionary:
	var result := target.duplicate(true)
	result[FEEDBACK_CHANNEL_KEY] = channel
	return result


func _on_feedback_group_completed(
	_group: MotionGroup,
	completion: EventCompletion,
) -> void:
	completion.finish()


func _schedule_card_landing_feedback(
	event: Dictionary,
	kind: String,
	color: Color,
	camera_strength: float = 0.0,
	camera_duration: float = 0.0,
) -> void:
	card_landing_feedback_scheduled.emit(event, {
		"kind": kind,
		"color": color,
		"camera_strength": camera_strength,
		"camera_duration": camera_duration,
	})


func _status_display_name(status: String) -> String:
	var normalized := status.strip_edges().to_upper()
	if normalized.is_empty():
		return "状态"
	return str(STATUS_DISPLAY_NAMES.get(normalized, status))


func _ko_feedback_target(
	event: Dictionary,
	source: Dictionary,
	fallback: Dictionary,
) -> Dictionary:
	if not str(source.get("slot", "")).is_empty():
		return source
	var data: Dictionary = event.get("data", {})
	var slot := str(data.get("slot", ""))
	if not slot.is_empty():
		return {
			"player": int(data.get("player", event.get("actor", -1))),
			"slot": slot,
		}
	return fallback


func _bounded_camera_duration(event: Dictionary, requested: float) -> float:
	var event_duration := _duration_for(event)
	if requested <= 0.0 or event_duration <= 0.0:
		return 0.0
	# One 30 FPS frame is ~33 ms. A 40 ms margin makes the final reset happen
	# before the event barrier regardless of SceneTree process ordering.
	return minf(requested, maxf(0.0, event_duration - 0.04))


func _duration_for(event: Dictionary) -> float:
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	if event_type == "cards_selected" and int(event.get("amount", 0)) <= 0:
		return 0.0
	if event_type in ANNOUNCEMENT_EVENT_TYPES:
		return float(ANNOUNCEMENT_DURATIONS.get(_speed_mode, 0.46))
	var base := float(EVENT_DURATIONS.get(event_type, 0.0))
	if base <= 0.0 or _speed_scale <= 0.0:
		return 0.0
	if _queue.size() > 8 and event_type not in [
		"pokemon_evolved",
		"attack_declared",
		"pokemon_ko",
	]:
		base *= 0.55
	return maxf(0.02, base * _speed_scale)


func _trim_seen() -> void:
	if _seen_event_ids.size() <= 512:
		return
	var keys := _seen_event_ids.keys()
	for index in range(mini(256, keys.size())):
		_seen_event_ids.erase(keys[index])
