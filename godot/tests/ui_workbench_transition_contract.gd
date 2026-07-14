extends SceneTree

var _failed := false
var _previous_animation_mode := "standard"
var _previous_reduced_motion := false
var _settings: Node
var _stage := "initialize"
var _finished := false


func _initialize() -> void:
	root.size = Vector2i(1280, 720)
	call_deferred("_run")
	call_deferred("_watchdog")


func _watchdog() -> void:
	await create_timer(10.0, true, false, true).timeout
	if _finished:
		return
	_failed = true
	push_error("UI Workbench transition contract timed out at %s" % _stage)
	_finish()


func _run() -> void:
	_settings = root.get_node_or_null("AppSettings")
	_check(_settings != null, "AppSettings autoload is unavailable")
	if _settings == null:
		_finish()
		return
	_previous_animation_mode = str(_settings.get("animation_mode"))
	_previous_reduced_motion = bool(_settings.get("reduced_motion"))
	_settings.set("animation_mode", "fast")
	_settings.set("reduced_motion", false)
	var scene := load("res://tools/ui_workbench.tscn") as PackedScene
	_check(scene != null, "UI Workbench scene could not be loaded")
	if scene == null:
		_finish()
		return
	var workbench := scene.instantiate()
	root.add_child(workbench)
	await process_frame
	_check(
		workbench.find_child("Checkpoint0", true, false) != null
		and workbench.find_child("Checkpoint50", true, false) != null
		and workbench.find_child("Checkpoint100", true, false) != null,
		"UI Workbench checkpoint controls are missing",
	)

	_stage = "checkpoint_0"
	await workbench.capture_presentation_checkpoint(0, "draw")
	var checkpoint: Dictionary = workbench.call("get_presentation_checkpoint")
	var before_view: Variant = checkpoint.get("before_view")
	var after_view: Variant = checkpoint.get("after_view")
	var request: Variant = checkpoint.get("request")
	var before_state: Variant = before_view.call("state_for_render")
	var after_state: Variant = after_view.call("state_for_render")
	_check(int(checkpoint.get("percent", -1)) == 0, "0% checkpoint was not ready")
	_check(
		after_state.players[0].hand.size() == before_state.players[0].hand.size() + 1
		and after_state.players[0].deck.size() == before_state.players[0].deck.size() - 1,
		"Draw fixture before/after states are not a real state transition",
	)
	_check(
		request != null
		and request.target_view == after_view
		and request.events.size() == 1
		and str(request.events[0].get("event_type", "")) == "cards_drawn",
		"Draw fixture did not build an atomic BattleTransitionRequest",
	)

	_stage = "checkpoint_50"
	await workbench.capture_presentation_checkpoint(50, "draw")
	checkpoint = workbench.call("get_presentation_checkpoint")
	_check(int(checkpoint.get("percent", -1)) == 50, "50% checkpoint was not ready")
	_check(
		workbench.current_battle.process_mode == Node.PROCESS_MODE_DISABLED,
		"50% checkpoint did not pause the battle motion subtree",
	)

	_stage = "checkpoint_100"
	await workbench.capture_presentation_checkpoint(100, "draw")
	checkpoint = workbench.call("get_presentation_checkpoint")
	var rendered_state: Variant = workbench.current_battle.table.state_ref
	var final_view: Variant = checkpoint.get("after_view")
	var target_state: Variant = final_view.call("state_for_render")
	_check(int(checkpoint.get("percent", -1)) == 100, "100% checkpoint was not ready")
	_check(
		workbench.current_battle.process_mode == Node.PROCESS_MODE_INHERIT
		and rendered_state.revision == target_state.revision
		and rendered_state.players[0].hand.size() == target_state.players[0].hand.size(),
		"100% checkpoint did not reconcile to the target BattleViewModel",
	)
	for kind in ["attach_energy", "evolve", "attack", "damage", "ko"]:
		_stage = "atomic_%s" % kind
		var handle: Variant = workbench.call("trigger_presentation", kind)
		_check(handle != null, "%s fixture did not return a PresentationHandle" % kind)
		if handle != null and not bool(handle.call("is_completed")):
			await handle.completed
		checkpoint = workbench.call("get_presentation_checkpoint")
		final_view = checkpoint.get("after_view")
		target_state = final_view.call("state_for_render")
		rendered_state = workbench.current_battle.table.state_ref
		_check(
			handle != null
			and str(handle.get("status")) == "completed"
			and rendered_state.revision == target_state.revision,
			"%s fixture did not complete its atomic transition" % kind,
		)
	workbench.queue_free()
	await process_frame
	_finish()


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	push_error(message)


func _finish() -> void:
	if _finished:
		return
	_finished = true
	if _settings != null:
		_settings.set("animation_mode", _previous_animation_mode)
		_settings.set("reduced_motion", _previous_reduced_motion)
	if _failed:
		quit(1)
		return
	print("UI_WORKBENCH_TRANSITION_OK")
	quit(0)
