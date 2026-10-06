extends SceneTree

const TABLE: PackedScene = preload("res://scenes/battle/components/battle_table.tscn")
var failures: Array[String] = []
var sequence := 7000
var _done := false


func _initialize() -> void:
	call_deferred("_run")
	call_deferred("_watchdog")


func _watchdog() -> void:
	await create_timer(110.0).timeout
	if not _done:
		push_error("Animation contract timed out")
		quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition and message not in failures:
		failures.append(message)


func _run() -> void:
	await _check_audio()
	root.size = Vector2i(1600, 900)
	var settings := root.get_node("AppSettings")
	var previous_mode := str(settings.animation_mode)
	var table := TABLE.instantiate() as BattleTable
	root.add_child(table)
	await _check_mulligan_audio(table)
	_check_cue_semantics(table.catalog)
	_check_impact_staging(table.catalog)
	for mode in ["cinematic", "standard", "fast"]:
		settings.animation_mode = mode
		await _check_contact(table, "damage_dealt")
		await _check_contact(table, "heavy_hit")
		await _check_contact(table, "healed")
		await _check_contact(table, "status_POISONED")
		await _check_contact(table, "damage_counters_placed")
		await _check_arrival_contact(table, "energy_attached")
		await _check_arrival_contact(table, "pokemon_evolved")
	settings.animation_mode = "standard"
	await _check_ko_finish(table)
	_check_effect_tails(table.render3d.world.feedback)
	await _check_camera_pixels(table)
	await _check_stalled_contact(table)
	await _check_cancel(table)
	await _check_cancel(table, true)
	_check_pool(table.render3d.world.feedback)
	settings.animation_mode = "fast"
	# All public Workbench actions execute through the real coordinator, including
	# identity-preserving flights and the separate KO leave-play event.
	for action in BattleAnimationPreview.ACTIONS:
		await _check_fixture(table, str(action), 0)
	settings.animation_mode = "reduced"
	for action in ["damage_dealt", "energy_attached", "pokemon_evolved", "pokemon_ko", "status_tick", "cards_drawn", "cards_selected"]:
		await _check_fixture(table, action, 1)
	settings.animation_mode = previous_mode
	table.queue_free()
	await process_frame
	_done = true
	for failure in failures:
		push_error(failure)
	if failures.is_empty(): print("BATTLE_ANIMATION_CONTRACT_OK")
	quit(0 if failures.is_empty() else 1)


func _check_cue_semantics(catalog: CardCatalog) -> void:
	for element in BattleFeedbackCue.ELEMENTS:
		var event := {"event_type": "damage_dealt", "source": {"player": 0, "slot": "active"},
			"target": {"player": 1, "slot": "active"}, "amount": 30, "data": {"damage_kind": "attack_damage"}}
		var cue := BattleFeedbackCue.from_event(event, BattleAnimationPreview.card_for(element, catalog), catalog, 0.32)
		_check(cue.element == element and cue.lunge, "%s source did not select its own attribute" % element)
		for damage_kind in ["damage", "damage_counters", "special_condition", ""]:
			event.data.damage_kind = damage_kind
			cue = BattleFeedbackCue.from_event(event, "svi-hrot", catalog, 0.32)
			_check(not cue.lunge, "Non-attack damage invented a lunge: " + damage_kind)
	var hidden := BattleFeedbackCue.from_event({"event_type": "damage_dealt"}, "", catalog, 0.32)
	_check(hidden.element.is_empty(), "Missing identity guessed an attribute")
	_check(is_equal_approx(MotionPolicy.duration("cards_drawn", "standard"), 0.36), "Draw time drifted from the shared profile")
	for mode in ["cinematic", "standard", "fast", "reduced"]:
		var reveal := MotionPolicy.event_duration({"event_type": "cards_revealed"}, mode, 50)
		_check(reveal >= (1.15 if mode == "reduced" else 1.85), "Reveal reading floor was compressed")


func _fixture(table: BattleTable, kind: String, viewer: int = 0) -> Dictionary:
	sequence += 1
	var fixture := BattleAnimationPreview.build(kind, "Fire", viewer, sequence, table.catalog)
	table.cancel_presentations("animation_fixture", fixture.before_view)
	return fixture


func _freeze_first_sample(_cue: BattleFeedbackCue, progress: float, renderer: BattleFeedback3D) -> void:
	if not _cue.event_id.is_empty() and is_zero_approx(progress): renderer.set_process(false)


func _check_contact(table: BattleTable, kind: String) -> void:
	var fixture := _fixture(table, kind)
	await process_frame
	await process_frame
	var renderer := table.render3d.world.feedback
	var freezer := _freeze_first_sample.bind(renderer)
	renderer.sampled.connect(freezer)
	var handle := table.submit_transition(fixture.request)
	for frame in range(120):
		if not table.presentation_runtime.feedback_cues.is_empty(): break
		await process_frame
	var id := str(fixture.request.events[0].event_id)
	var runtime := table.presentation_runtime
	var cue := runtime.feedback_cues.get(id) as BattleFeedbackCue
	_check(cue != null, kind + " never produced a live feedback timeline")
	if cue != null:
		var row: Dictionary = {}
		for candidate in renderer._bursts:
			if candidate.cue == cue: row = candidate
		var cover := runtime.slot_cover_states.get("1:active") as PokemonState
		_check(cover != null, kind + " has no staged target")
		if cover != null and not row.is_empty():
			var before := (fixture.before_state as GameState).players[1].active
			var after := (fixture.after_state as GameState).players[1].active
			renderer._sample(row, cue.impact_fraction * 0.5)
			_check(cover.damage_counters == before.damage_counters and cover.status_conditions == before.status_conditions, kind + " committed before contact")
			_check(table.world_feedback.floating_texts.is_empty(), kind + " showed its number before contact")
			renderer._sample(row, cue.impact_fraction)
			var contact_pose := table.render3d.card_pose(runtime._feedback_card(cue.target_endpoint))
			_check(cue.target.distance_to(contact_pose.origin + contact_pose.basis.y * CardEntity3D.THICKNESS * 0.5) < 0.001, kind + " impact was bound to the previous card pose")
			_check(cover.damage_counters == after.damage_counters and cover.status_conditions == after.status_conditions, kind + " did not commit on contact")
			_check(table.world_feedback.floating_texts.size() == 1, kind + " did not produce one readable result")
			if kind == "heavy_hit":
				_check(cue.heavy and table.camera_rig._impulse_handle != null, "Heavy contact did not produce a bounded camera impulse")
				var impulse := table.camera_rig._impulse_handle
				# A second target in the same sequence gets its own hit, no second shake.
				var other := BattleFeedbackCue.from_event(fixture.request.events[0], "svi-chim", table.catalog, cue.duration)
				other.event_id = id + ":other-target"
				other.text = ""
				other.audio = ""
				other.set_damage_weight(60, 100)
				runtime.feedback_cues[other.event_id] = other
				runtime._on_feedback_impact(other.event_id)
				_check(table.camera_rig._impulse_handle == impulse, "A multi-target attack restarted the camera")
				runtime._on_feedback_released(other)
			renderer._sample(row, cue.impact_fraction + 0.01)
			_check(cover.damage_counters == after.damage_counters and table.world_feedback.floating_texts.size() == 1, kind + " committed twice")
			if kind == "damage_dealt" and MotionPolicy.mode() == "standard":
				root.size = Vector2i(640, 960)
				await process_frame
				await process_frame
				renderer._sample(row, 0.65)
				var physical_width := table.render3d.card_pose(runtime._feedback_card(cue.target_endpoint)).basis.x.length()
				_check(is_equal_approx(cue.width, physical_width), "Live resize detached feedback from the physical card")
				root.size = Vector2i(1600, 900)
				await process_frame
			# End all positional writes before the event barrier releases input.
			renderer._process(cue.duration)
	renderer.sampled.disconnect(freezer)
	for frame in range(120):
		if handle.is_completed(): break
		await process_frame
	_check(handle.is_completed(), kind + " completion barrier remained blocked")
	_check(table.own_active.battle_fx_offset.is_zero_approx() and table.opponent_active.battle_fx_offset.is_zero_approx(), kind + " left a card pose behind")


func _check_cancel(table: BattleTable, after_contact: bool = false) -> void:
	var fixture := _fixture(table, "damage_dealt")
	await process_frame
	var renderer := table.render3d.world.feedback
	var freezer := _freeze_first_sample.bind(renderer)
	renderer.sampled.connect(freezer)
	var handle := table.submit_transition(fixture.request)
	for frame in range(120):
		if not table.presentation_runtime.feedback_cues.is_empty(): break
		await process_frame
	if after_contact:
		for row in renderer._bursts:
			if not (row.cue as BattleFeedbackCue).event_id.is_empty():
				renderer._sample(row, 0.65)
	table.cancel_presentations("contact_cancel", fixture.after_view if after_contact else fixture.before_view)
	renderer.sampled.disconnect(freezer)
	_check(handle.status == PresentationHandle.SNAPPED and handle.completion_reason == "contact_cancel", "Resync failed to cancel the semantic transition")
	_check(renderer._bursts.is_empty() and table.presentation_runtime.feedback_cues.is_empty(), "Resync retained a feedback timeline")
	_check(table.opponent_active.pokemon.damage_counters == (4 if after_contact else 1), "Cancelled impact changed the replacement view")
	_check(table.own_active.battle_fx_offset.is_zero_approx(), "Cancelled attack left its source displaced")
	_check(table.render3d.world._feedback_focus.is_empty(), "Cancelled attack left the table dimmed")
	_check(table.camera_rig._impulse_handle == null, "Cancelled attack retained a camera impulse")


func _check_arrival_contact(table: BattleTable, kind: String) -> void:
	var fixture := _fixture(table, kind)
	await process_frame
	var renderer := table.render3d.world.feedback
	var runtime := table.presentation_runtime
	var id := str(fixture.request.events[0].event_id)
	var freezer := func(cue: BattleFeedbackCue, progress: float) -> void:
		if cue.event_id != id or not is_zero_approx(progress): return
		var source := runtime.feedback_motion_sources.get(id) as WeakRef
		if source == null: return
		var flyer := source.get_ref() as Control
		var motion := flyer.get_meta("motion_handle") as MotionHandle
		motion.tween.pause()
	renderer.sampled.connect(freezer)
	var handle := table.submit_transition(fixture.request)
	for frame in range(120):
		if runtime.feedback_cues.has(id): break
		await process_frame
	var cue := runtime.feedback_cues.get(id) as BattleFeedbackCue
	_check(cue != null and cue.motion_driven, kind + " has no feedback during flight")
	if cue != null:
		var before := (fixture.before_state as GameState).players[0].active
		var after := (fixture.after_state as GameState).players[0].active
		var shown := runtime._feedback_card(cue.target_endpoint)
		# A stalled flight must not update its target merely because the effect
		# renderer advanced. Both now use the actual arrival tween as their clock.
		renderer._process(cue.duration * 2.0)
		_check(shown.pokemon.card_id == before.card_id and shown.pokemon.energy_card_ids == before.energy_card_ids, kind + " committed during a paused flight")
		renderer.advance(id, cue.impact_fraction - 0.001)
		_check(shown.pokemon.card_id == before.card_id and shown.pokemon.energy_card_ids == before.energy_card_ids, kind + " committed before landing")
		var audio: Array[String] = []
		var capture := func(value: String) -> void: audio.append(value)
		table.audio_requested.connect(capture)
		renderer.advance(id, cue.impact_fraction)
		_check(shown.pokemon.card_id == after.card_id and shown.pokemon.energy_card_ids == after.energy_card_ids, kind + " did not commit at landing")
		renderer.advance(id, cue.impact_fraction + 0.001)
		_check(audio.size() == 1, kind + " duplicated its contact audio")
		table.audio_requested.disconnect(capture)
	table.cancel_presentations("arrival_cancel", fixture.before_view)
	renderer.sampled.disconnect(freezer)
	_check(handle.is_completed() and runtime.feedback_motion_sources.is_empty() and runtime.landing_barriers.is_empty(), kind + " retained a flight-driven effect after resync")
	_check(table.own_active.pokemon.card_id == (fixture.before_state as GameState).players[0].active.card_id, kind + " cancellation changed the replacement card")


func _check_pool(renderer: BattleFeedback3D) -> void:
	var handles: Array[MotionHandle] = []
	for i in range(12):
		var cue := BattleFeedbackCue.new()
		cue.event_id = "pool:%d" % i
		cue.duration = 0.1
		cue.impact_fraction = 0.5
		handles.append(renderer.play(cue))
	_check(renderer.get_child_count() <= BattleFeedback3D.LIMIT, "Glyph allocation exceeded the bounded pool")
	var hits: Array[String] = []
	var capture := func(id: String) -> void: hits.append(id)
	renderer.impact_reached.connect(capture)
	renderer._process(0.1)
	renderer.impact_reached.disconnect(capture)
	_check(hits.size() == 12, "Full pool dropped semantic contact callbacks")
	for handle in handles: _check(handle.is_finished(), "Full pool stranded a handle")
	renderer.clear()


func _check_fixture(table: BattleTable, kind: String, viewer: int) -> void:
	var fixture := _fixture(table, kind, viewer)
	await process_frame
	var sounds: Array[String] = []
	var capture := func(request: AudioCueRequest) -> void: sounds.append(str(request.cue))
	table.audio_event_requested.connect(capture)
	var handle := table.submit_transition(fixture.request)
	var deadline := Time.get_ticks_msec() + 7000
	while not handle.is_completed() and Time.get_ticks_msec() < deadline:
		await process_frame
	table.audio_event_requested.disconnect(capture)
	if kind == "cards_selected":
		_check(sounds.count("card_reveal") == 1, "Public search reveal lost or duplicated its audio")
	_check(handle.is_completed(), "Fixture stalled: " + kind)
	if not handle.is_completed(): table.cancel_presentations("test_timeout", fixture.after_view)
	_check(table.state_ref.revision == fixture.after_view.revision(), "Fixture failed to reconcile: " + kind)
	_check(table.presentation_runtime.landing_barriers.is_empty(), "Landing barrier leaked: " + kind)
	_check(table.render3d.world.feedback._bursts.is_empty(), "Effect survived its batch: " + kind)
	if MotionPolicy.reduced() and kind == "damage_dealt":
		_check(not table.world_feedback.static_outlines.is_empty(), "Reduced feedback lost its static target outline")
	for view in table.hand_views + table.opponent_hand_views + [table.own_active, table.opponent_active]:
		_check(not view.has_meta("physical_settle"), "Landing pose survived its batch: " + kind)


func _check_impact_staging(catalog: CardCatalog) -> void:
	var event := {"event_type": "damage_dealt", "source": {"player": 0, "slot": "active"},
		"target": {"player": 1, "slot": "active"}, "amount": 50, "data": {"damage_kind": "attack_damage"}}
	var cue := BattleFeedbackCue.from_event(event, "svi-chim", catalog, 0.44)
	cue.set_damage_weight(49, 100)
	_check(not cue.heavy, "Below-half damage incorrectly became a heavy hit")
	cue.set_damage_weight(50, 100)
	_check(cue.heavy, "Half-HP damage did not select heavy staging")
	var contact := cue.impact_fraction
	_check(is_zero_approx(cue.contact_progress(contact + 0.049 / 0.44)), "Heavy pose did not hold for 50ms")
	_check(cue.contact_progress(contact + 0.070 / 0.44) > 0.0, "Heavy pose failed to recover after its hold")
	_check(is_equal_approx(cue.contact_progress(1.0), 1.0), "Hit hold lengthened the completion barrier")
	cue.set_damage_weight(30, 100)
	_check(is_zero_approx(cue.contact_progress(contact + 0.029 / 0.44)), "Normal pose did not hold for 30ms")
	_check(cue.contact_progress(contact + 0.04 / 0.44) > 0.0, "Normal pose remained held too long")
	var recoil := BattleFeedbackCue.from_event({"event_type": "damage_dealt", "data": {"damage_kind": "special_condition"}}, "", catalog, 0.32)
	recoil.set_damage_weight(100, 100)
	_check(not recoil.heavy and not recoil.lunge, "Status damage acquired attack staging")
	_check(is_equal_approx(MotionPolicy.event_duration(event, "standard"), 0.44), "Attack timing did not use the shared impact duration")


func _check_stalled_contact(table: BattleTable) -> void:
	var fixture := _fixture(table, "heavy_hit")
	await process_frame
	var renderer := table.render3d.world.feedback
	var freezer := _freeze_first_sample.bind(renderer)
	renderer.sampled.connect(freezer)
	var handle := table.submit_transition(fixture.request)
	for frame in range(120):
		if not table.presentation_runtime.feedback_cues.is_empty(): break
		await process_frame
	renderer._process(2.0)
	_check(table.camera_rig._impulse_handle == null, "Skipped contact started a camera tween after its parent finished")
	for row in table.world_feedback.floating_texts:
		_check(is_zero_approx(float(row.motion_remaining)), "Skipped contact left a moving number after input unlocked")
	_check(table.render3d.world._feedback_focus.is_empty(), "Skipped contact left the table dimmed")
	renderer.sampled.disconnect(freezer)
	for frame in range(120):
		if handle.is_completed(): break
		await process_frame
	_check(handle.is_completed(), "Skipped contact stranded its presentation barrier")
	_check(table.opponent_active.pokemon.damage_counters == 7, "Skipped contact lost its authoritative damage result")


func _check_camera_pixels(table: BattleTable) -> void:
	_fixture(table, "heavy_hit")
	await process_frame
	await process_frame
	var world := table.render3d.world
	var pose := table.render3d.card_pose(table.own_active)
	var baseline := world.projection.world_to_screen(pose.origin)
	var peak := 0.0
	for index in range(25):
		table.camera_rig._sample_impulse(float(index) / 24.0, 2.0 / 7.0)
		table.render3d.sync_surfaces()
		var current := table.render3d.card_pose(table.own_active)
		_check(current.origin.distance_to(pose.origin) < 0.0001, "Layout counteracted the camera by displacing the card")
		peak = maxf(peak, baseline.distance_to(world.projection.world_to_screen(current.origin)))
	_check(peak > 0.5 and peak <= 2.0, "Heavy camera impulse is imperceptible or exceeds two pixels")
	table.camera_rig.cancel()
	_check(world.projection.world_to_screen(pose.origin).distance_to(baseline) < 0.001, "Camera did not return to its calibrated projection")


func _check_effect_tails(renderer: BattleFeedback3D) -> void:
	for kind in ["energy", "evolution", "charge", "heal", "shield", "ko", "victory", "attack"]:
		var cue := BattleFeedbackCue.new()
		cue.kind = kind
		cue.duration = 1.0
		cue.impact_fraction = 0.60 if kind in ["energy", "evolution"] else 0.42
		cue.bind_surface(Transform3D.IDENTITY)
		var handle := renderer.play(cue)
		var row: Dictionary = renderer._bursts[-1]
		renderer._sample(row, 0.999)
		var node := row.node as MultiMeshInstance3D
		_check(node.multimesh.visible_instance_count == 0, kind + " still has visible geometry when its effect is recycled")
		renderer._process(1.0)
		_check(handle.is_finished(), kind + " tail never released its barrier")


func _check_ko_finish(table: BattleTable) -> void:
	var fixture := _fixture(table, "pokemon_ko")
	await process_frame
	var observed := {"held": false, "departed": false}
	var finished := func(event: Dictionary) -> void:
		if str(event.get("event_type", "")) == "pokemon_ko":
			var cover := table.presentation_runtime._feedback_card(event.source)
			observed.held = cover != null and float(cover.get_meta("ko_desaturation", 0.0)) > 0.8
	table.director.event_finished.connect(finished)
	var handle := table.submit_transition(fixture.request)
	for frame in range(240):
		await process_frame
		for token in table.card_motion_layer.entities:
			if str(token.get_meta("motion_kind", "")) == "ko_leave_play" and token.visible and float(token.get_meta("motion_progress", 0.0)) < 0.25:
				observed.departed = true
				_check(float(token.get_meta("paper_desaturation", 0.0)) > 0.8, "KO departure flashed back to full color")
		if handle.is_completed(): break
	table.director.event_finished.disconnect(finished)
	_check(observed.held and observed.departed and handle.is_completed(), "KO finish did not carry into a completed departure")
	table.cancel_presentations("ko_finish_reset", fixture.before_view)
	_check(not table.opponent_active.has_meta("ko_desaturation"), "KO finish contaminated the replacement card")


func _check_audio() -> void:
	var audio := AudioDirector.new()
	root.add_child(audio)
	await process_frame
	var table := TABLE.instantiate() as BattleTable
	root.add_child(table)
	table.audio_event_requested.connect(audio.play)
	table.audio_cancel_requested.connect(audio.cancel_scope.bind(&"battle"))
	audio.play_cue("evolution")
	table.cancel_presentations("audio_resync")
	for voice in audio.sfx.players:
		_check(not voice.playing and voice.stream == null, "Resync left an orphan sound")
	for element in BattleFeedbackCue.ELEMENTS:
		_check(audio.cues.has(StringName("attack_hit_" + str(element).to_lower())), "Missing attribute sound: " + str(element))
	table.queue_free()
	audio.queue_free()
	await process_frame
	await create_timer(0.15).timeout
	if failures.is_empty(): print("BATTLE_AUDIO_CONTRACT_OK")


func _check_mulligan_audio(table: BattleTable) -> void:
	root.get_node("AppSettings").animation_mode = "standard"
	_fixture(table, "cards_drawn")
	await process_frame
	await process_frame
	var requests: Array[AudioCueRequest] = []
	var capture := func(request: AudioCueRequest) -> void: requests.append(request)
	table.audio_event_requested.connect(capture)
	var mulligan := table.render3d.mulligan
	var ids := ["sv1-151", "sv1-151", "sv1-151"]
	for pair in [["cards_drawn", "mulligan_redraw", "card_draw"], ["card_moved", "mulligan_return", "card_recover"]]:
		requests.clear()
		var event := {"event_type": pair[0], "event_id": "audio-review:" + str(pair[0]), "actor": 0,
			"data": {"purpose": pair[1], "count": 3, "card_ids": ids}}
		var handle := mulligan.play(event, 0.3)
		if not handle.is_finished(): await handle.completed
		_check(requests.size() == 3, "Intermediate mulligan hand lost per-card audio: " + str(pair[0]))
		for index in range(requests.size()):
			_check(requests[index].cue == StringName(pair[2]) and requests[index].ordinal == index, "Mulligan audio lost cue/ordinal identity")
		var count := requests.size()
		mulligan.sync()
		_check(requests.size() == count, "Mulligan sync replayed a departure sound")
	mulligan.clear()
	table.audio_event_requested.disconnect(capture)
