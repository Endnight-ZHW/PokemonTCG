extends RefCounted


static func run(table: BattleTable, check: Callable) -> void:
	var tree := table.get_tree()
	var settings := tree.root.get_node("AppSettings")
	settings.quality_profile = "auto"
	settings.begin_battle_quality(table.render3d.get_instance_id())
	settings.set("_battle_auto_profile", "low")
	table.hide()
	await tree.process_frame
	check.call(table.render3d.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"A hidden table continues updating its 3D viewport")
	table.show()
	await tree.process_frame
	check.call(settings.resolved_quality_profile() == "low",
		"Hiding and restoring the same battle resets its automatic quality downgrade")
	check.call(settings.quality_profile == "auto", "Visibility changes overwrite the saved quality preference")

	# An empty view makes asset prefetch synchronous, exposing cancellation that
	# happens inside transition_started rather than during an awaited animation.
	var state := GameState.new()
	state.revision = 10
	table.update_view(state, 0, [], "", false, "local")
	var next_state := state.clone_state()
	next_state.revision = 11
	var view := BattleViewModel.capture(next_state, 0, [], "", false, "local")
	var coordinator := table.presentation_coordinator
	coordinator.transition_started.connect(func(_handle: PresentationHandle) -> void:
		coordinator.cancel_all("cancel_in_started_signal"), CONNECT_ONE_SHOT)
	var handle := coordinator.submit(BattleTransitionRequest.create(view))
	for frame in range(3):
		await tree.process_frame
	check.call(handle.is_completed() and handle.completion_reason == "cancel_in_started_signal",
		"Cancellation during transition_started did not resolve its completion handle")
	check.call(table.state_ref.revision == 10,
		"A cancelled transition still overwrites the rendered battle state")
	check.call(not coordinator.is_busy(), "Cancellation during transition_started leaves the queue blocked")
	var next_handle := coordinator.submit(BattleTransitionRequest.create(view))
	for frame in range(3):
		await tree.process_frame
	check.call(next_handle.status == PresentationHandle.COMPLETED and table.state_ref.revision == 11,
		"The queue cannot accept a new transition after cancellation during transition_started")
