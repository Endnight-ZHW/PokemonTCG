extends SceneTree

var _failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _run() -> void:
	root.get_node("AppSettings").set("reduced_motion", true)
	root.get_node("AppSettings").set("animation_mode", "reduced")
	root.size = Vector2i(1280, 720)
	var table := load("res://scenes/battle/components/battle_table.tscn").instantiate() as BattleTable
	root.add_child(table)
	var state := UIPreviewStateFactory.battle_state()
	table.update_view(state, 0, UIPreviewStateFactory.action_rows(state), "", false, "local")
	for _i in range(3):
		await process_frame
	_check(not table.is_processing(), "Idle table must not poll drag position")
	table.hand_view._on_hand_drag_started(0)
	_check(not table.active_drag_context().is_empty() and table.is_processing(), "Live drag must start pointer tracking")
	table.commit_pending_drag_source("stale-session")
	_check(table.is_processing(), "Stale presentation must not stop an unrelated live drag")
	root.size = Vector2i(1000, 600)
	for _i in range(3):
		await process_frame
	_check(table.is_processing(), "Resize must preserve live pointer tracking")
	var session_id := table.mark_drag_pending("drag:contract", true)
	_check(not session_id.is_empty() and not table.is_processing(), "Pending authority must park the proxy")
	table.hand_view._on_hand_drag_ended()
	_check(table.active_drag_context().get("session_id") == session_id, "Pointer release discarded the pending action")
	table.clear_pending_drag_immediately("resync")
	_check(table.active_drag_context().is_empty() and not table.is_processing(), "Resync must clear the drag and polling")
	_check(not table.hand_views[0].is_drag_masked(), "Resync must restore the source card")
	table.hand_view._on_hand_drag_started(0)
	table.hand_view._on_hand_drag_ended()
	_check(table.active_drag_context().is_empty() and not table.is_processing(), "Cancelled reduced-motion drag must return immediately")
	table.queue_free()
	await process_frame
	if _failures.is_empty():
		print("BATTLE_DRAG_LIFECYCLE_OK")
		quit(0)
	else:
		for message in _failures:
			push_error(message)
		quit(1)
