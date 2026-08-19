class_name BattlePresentationCoordinator
extends Node

signal busy_changed(busy: bool)
signal transition_started(handle: PresentationHandle)
signal transition_finished(handle: PresentationHandle)

var _table: BattleTable
var _queue: Array[Dictionary] = []
var _active: Dictionary = {}
var _next_batch_id := 1
var _pump_scheduled := false
var _generation := 0
var _preflight: MotionHandle


func _exit_tree() -> void:
	_generation += 1
	_cancel_preflight()
	if _table != null and is_instance_valid(_table):
		# Scene teardown may happen in the middle of a feedback/motion barrier.
		# Cancel those table-owned groups before releasing the coordinator's
		# active handle so EventCompletion/MotionGroup references cannot survive
		# until ObjectDB shutdown.
		_table.clear_presentation_visuals_for_resync()
		_table.set_transition_blocked(false)
	if not _active.is_empty():
		var active_handle := _active.get("handle") as PresentationHandle
		if active_handle != null:
			active_handle.finish(PresentationHandle.CANCELLED, "coordinator_exited")
	_active.clear()
	for row in _queue:
		var queued_handle := row.get("handle") as PresentationHandle
		if queued_handle != null:
			queued_handle.finish(PresentationHandle.CANCELLED, "coordinator_exited")
	_queue.clear()
	_table = null


func configure(table: BattleTable) -> void:
	_table = table


func is_busy() -> bool:
	return (
		(_preflight != null and not _preflight.is_finished())
		or not _active.is_empty()
		or not _queue.is_empty()
	)


## Installs a presentation barrier that must finish before authoritative battle
## transitions may mutate the rendered table. Startup shuffle uses this so a
## network state received during the opening choreography is queued, not applied
## underneath the physical deck animation.
func set_preflight(handle: MotionHandle) -> void:
	if _preflight == handle:
		return
	var was_busy := is_busy()
	_cancel_preflight()
	if handle == null or handle.is_finished():
		_refresh_critical_blocker()
		_schedule_pump()
		return
	_preflight = handle
	handle.completed.connect(
		_on_preflight_completed.bind(handle),
		CONNECT_ONE_SHOT,
	)
	_refresh_critical_blocker()
	if not was_busy:
		busy_changed.emit(true)


func _on_preflight_completed(
	_completed_handle: MotionHandle,
	expected_handle: MotionHandle,
) -> void:
	if _preflight != expected_handle:
		return
	_preflight = null
	_refresh_critical_blocker()
	if _queue.is_empty() and _active.is_empty():
		busy_changed.emit(false)
	else:
		_schedule_pump()


func _cancel_preflight() -> void:
	var handle := _preflight
	_preflight = null
	if handle != null and not handle.is_finished():
		handle.cancel()


func submit(request: BattleTransitionRequest) -> PresentationHandle:
	var was_busy := is_busy()
	var handle := PresentationHandle.new()
	handle.batch_id = _next_batch_id
	_next_batch_id += 1
	handle.revision = request.revision if request != null else -1
	handle.origin_action_id = request.origin_action_id if request != null else ""
	_queue.append({"request": request, "handle": handle})
	_refresh_critical_blocker()
	if not was_busy:
		busy_changed.emit(true)
	_schedule_pump()
	return handle


func cancel_all(reason: String = "cancelled", replacement: BattleViewModel = null) -> void:
	_generation += 1
	_cancel_preflight()
	if _table != null:
		_table.clear_presentation_visuals_for_resync()
		_table.clear_pending_drag_immediately(reason)
	if not _active.is_empty():
		var active_handle := _active.get("handle") as PresentationHandle
		if active_handle != null:
			active_handle.finish(PresentationHandle.SNAPPED, reason)
			transition_finished.emit(active_handle)
	_active.clear()
	for row in _queue:
		var queued_handle := row.get("handle") as PresentationHandle
		if queued_handle != null:
			queued_handle.finish(PresentationHandle.CANCELLED, reason)
	_queue.clear()
	if replacement != null:
		_apply_view(replacement)
	_refresh_critical_blocker()
	busy_changed.emit(false)


func _schedule_pump() -> void:
	if _pump_scheduled:
		return
	_pump_scheduled = true
	call_deferred("_pump")


func _pump() -> void:
	_pump_scheduled = false
	if (
		not is_inside_tree()
		or get_tree() == null
		or (_preflight != null and not _preflight.is_finished())
		or not _active.is_empty()
		or _queue.is_empty()
		or _table == null
	):
		return
	var row: Dictionary = _queue.pop_front()
	var request := row.get("request") as BattleTransitionRequest
	var handle := row.get("handle") as PresentationHandle
	if request == null or request.target_view == null or handle == null:
		if handle != null:
			handle.finish(PresentationHandle.CANCELLED, "invalid_request")
		_refresh_critical_blocker()
		if _queue.is_empty():
			busy_changed.emit(false)
		else:
			_schedule_pump()
		return
	var run_generation := _generation
	_active = row
	handle.mark_running()
	transition_started.emit(handle)
	var previous_snapshot := _table.capture_presentation_snapshot()
	_table.prepare_hand_identity_transition(request.events, previous_snapshot)
	if not request.drag_session_id.is_empty():
		_table.prepare_pending_drag_for_transition(request.drag_session_id)
	_apply_view(request.target_view)
	if not request.drag_session_id.is_empty():
		_table.commit_pending_drag_source(request.drag_session_id)
	if request.events.is_empty() or _table.director == null:
		_finish_active(run_generation)
		return
	var director := _table.director
	_table.play_presentation(
		request.events,
		request.revision,
		request.fallback_actor,
		previous_snapshot,
	)
	# A duplicate-only batch does not start the director.  It still commits on
	# this deferred pump turn and must not deadlock the flow barrier.
	if not director.is_playing() and director.pending_count() == 0:
		_table.clear_unplayed_presentation_staging()
	else:
		await director.sequence_finished
	_finish_active(run_generation)


func _apply_view(view: BattleViewModel) -> void:
	var render_state := view.state_for_render()
	if render_state == null:
		return
	_table.update_view(
		render_state,
		view.view_player,
		view.action_rows,
		view.selected_entity_key,
		view.ai_thinking,
		view.game_mode,
	)


func _finish_active(
	run_generation: int,
	status: String = PresentationHandle.COMPLETED,
	reason: String = "",
) -> void:
	if run_generation != _generation or _active.is_empty():
		return
	var handle := _active.get("handle") as PresentationHandle
	var request := _active.get("request") as BattleTransitionRequest
	_active.clear()
	if request != null and not request.drag_session_id.is_empty() and _table != null:
		_table.finish_pending_drag_transition(request.drag_session_id)
	if handle != null:
		handle.finish(status, reason)
		transition_finished.emit(handle)
	_refresh_critical_blocker()
	if _queue.is_empty():
		busy_changed.emit(false)
	else:
		_schedule_pump()


func _refresh_critical_blocker() -> void:
	if _table == null or not is_instance_valid(_table):
		return
	var blocked := _preflight != null and not _preflight.is_finished()
	if not _active.is_empty():
		var active_request := _active.get("request") as BattleTransitionRequest
		blocked = active_request != null and active_request.critical
	if not blocked:
		for row in _queue:
			var queued_request := row.get("request") as BattleTransitionRequest
			if queued_request != null and queued_request.critical:
				blocked = true
				break
	_table.set_transition_blocked(blocked)
