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
signal feedback_requested(event: Dictionary, duration: float)
## Reserve the feedback barrier before the motion group seals. The physical
## executor owns its clock: evolve/attach begin in flight, and contact effects
## and visible state updates occur only when the proxy actually lands.
signal card_landing_feedback_scheduled(event: Dictionary, duration: float)
signal event_ignored(event: Dictionary)

const FEEDBACK_CHANNEL_KEY := "feedback_channel"
const FEEDBACK_CHANNEL_ANNOUNCEMENT := "announcement"
var audio_event_id := ""
var _queue: Array[Dictionary] = []
var _seen_event_ids: Dictionary = {}
var _playing := false
var _cancelled := false
var _speed_mode := "standard"
var _generation := 0
var _active_completion: EventCompletion
var _active_feedback_group: MotionGroup
var _feedback_registration_open := false


func _exit_tree() -> void:
	# A scene can be closed while an event is awaiting a real feedback handle.
	# Finish that barrier explicitly; relying on Tween/SceneTree destruction
	# leaves the RefCounted completion group alive until engine shutdown.
	clear_for_resync()


func is_playing() -> bool:
	return _playing


func pending_count() -> int:
	return _queue.size()


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


func has_seen_event(event_id: String) -> bool:
	return not event_id.is_empty() and _seen_event_ids.has(event_id)


func play(events: Array[Dictionary]) -> void:
	if not is_inside_tree():
		return
	for event in events:
		var event_id := str(event.get("event_id", ""))
		if has_seen_event(event_id):
			continue
		if not event_id.is_empty():
			_seen_event_ids[event_id] = true
		_queue.append(event.duplicate(true))
	_trim_seen()
	if not _playing and not _queue.is_empty():
		_run_queue()


func clear_for_resync() -> void:
	audio_event_id = ""
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
	_speed_mode = mode if mode in MotionPolicy.PROFILE.mode_scales else "standard"


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
	audio_event_id = str(event.get("event_id", ""))
	var event_type := str(event.get("event_type", ""))
	var target: Dictionary = event.get("target", {})
	if (
		str(target.get("slot", "")).is_empty()
		and str(target.get("zone", "")).is_empty()
	):
		target = event.get("source", {})
	var source: Dictionary = event.get("source", {})
	var data: Dictionary = event.get("data", {})
	if event_type in BattleFeedbackCue.FEEDBACK_EVENTS:
		feedback_requested.emit(event, _duration_for(event))
		if event_type == "pokemon_ko":
			card_motion_requested.emit(event, _duration_for(event))
		return
	match event_type:
		"cards_drawn":
			card_motion_requested.emit(event, _duration_for(event))
		"cards_revealed":
			audio_requested.emit("card_reveal")
			card_motion_requested.emit(event, _duration_for(event))
		"cards_discarded":
			if not str(source.get("attachment_type", "")).is_empty():
				burst_requested.emit(
					"attachment_release",
					source,
					DesignTokens.GOLD,
				)
			card_motion_requested.emit(event, _duration_for(event))
		"card_moved":
			card_motion_requested.emit(event, _duration_for(event))
		"cards_selected":
			if int(event.get("amount", 0)) > 0:
				card_motion_requested.emit(event, _duration_for(event))
		"pokemon_played", "trainer_played", "stadium_changed", "tool_attached", "energy_attached", "pokemon_evolved":
			if event_type == "energy_attached" and not str(source.get("slot", "")).is_empty():
				burst_requested.emit("attachment_release", source, DesignTokens.GOLD)
			_schedule_card_landing_feedback(event)
			card_motion_requested.emit(event, _duration_for(event))
		"retreat", "switched", "promoted":
			card_motion_requested.emit(event, _duration_for(event))
		"prize_taken":
			card_motion_requested.emit(event, _duration_for(event))
		"coin_flip":
			card_motion_requested.emit(event, _duration_for(event))
		"deck_shuffled":
			audio_requested.emit("shuffle")
			card_motion_requested.emit(event, _duration_for(event))
		"deck_exhausted":
			audio_requested.emit("deck_exhausted")
			floating_text_requested.emit(
				"牌库耗尽",
				_feedback_target(source, FEEDBACK_CHANNEL_ANNOUNCEMENT),
				DesignTokens.RED,
			)
		"turn_order_chosen":
			audio_requested.emit("turn_change")
			var first_player := int(data.get(
				"first_player",
				target.get("player", -1),
			))
			floating_text_requested.emit(
				(
					"玩家 %d 先攻" % (first_player + 1)
					if first_player in [0, 1]
					else "先攻已确定"
				),
				_feedback_target(
					{"player": first_player},
					FEEDBACK_CHANNEL_ANNOUNCEMENT,
				),
				DesignTokens.GOLD,
			)
		"setup_revealed":
			audio_requested.emit("card_reveal")
			floating_text_requested.emit(
				"双方宝可梦公开",
				_feedback_target({}, FEEDBACK_CHANNEL_ANNOUNCEMENT),
				DesignTokens.CYAN,
			)
			_emit_setup_reveal_feedback(data)
		"turn_start":
			audio_requested.emit("turn_start")
			floating_text_requested.emit(
				"第 %d 回合" % int(data.get("turn", 0)),
				_feedback_target(target, FEEDBACK_CHANNEL_ANNOUNCEMENT),
				DesignTokens.GOLD,
			)
		"turn_end":
			audio_requested.emit("turn_end")
			floating_text_requested.emit(
				"回合结束",
				_feedback_target(target, FEEDBACK_CHANNEL_ANNOUNCEMENT),
				DesignTokens.BLUE,
			)
		"checkup":
			audio_requested.emit("checkup")
			floating_text_requested.emit(
				"宝可梦检查",
				_feedback_target(target, FEEDBACK_CHANNEL_ANNOUNCEMENT),
				DesignTokens.CYAN,
			)
		_:
			event_ignored.emit(event)


func _emit_setup_reveal_feedback(data: Dictionary) -> void:
	var players_value: Variant = data.get("players", [])
	if not players_value is Array:
		return
	var players: Array = players_value
	for player_idx in range(mini(2, players.size())):
		if not players[player_idx] is Dictionary:
			continue
		var player: Dictionary = players[player_idx]
		if not str(player.get("active", "")).is_empty():
			burst_requested.emit(
				"setup_reveal",
				{"player": player_idx, "slot": "active"},
				DesignTokens.CYAN,
			)
		var bench_value: Variant = player.get("bench", [])
		if not bench_value is Array:
			continue
		var bench: Array = bench_value
		for bench_idx in range(mini(5, bench.size())):
			if str(bench[bench_idx]).is_empty():
				continue
			burst_requested.emit(
				"setup_reveal",
				{"player": player_idx, "slot": "bench_%d" % bench_idx},
				DesignTokens.CYAN,
			)


func _feedback_target(target: Dictionary, channel: String) -> Dictionary:
	var result := target.duplicate(true)
	result[FEEDBACK_CHANNEL_KEY] = channel
	return result


func _on_feedback_group_completed(
	_group: MotionGroup,
	completion: EventCompletion,
) -> void:
	completion.finish()


func _schedule_card_landing_feedback(event: Dictionary) -> void:
	card_landing_feedback_scheduled.emit(event,
		MotionPolicy.landing_duration(str(event.get("event_type", "")), _duration_for(event)))


func _duration_for(event: Dictionary) -> float:
	return MotionPolicy.event_duration(event, _speed_mode, _queue.size())


func _trim_seen() -> void:
	if _seen_event_ids.size() <= 512:
		return
	var keys := _seen_event_ids.keys()
	for index in range(mini(256, keys.size())):
		_seen_event_ids.erase(keys[index])
