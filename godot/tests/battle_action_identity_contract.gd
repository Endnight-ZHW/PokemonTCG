extends SceneTree

## Real rules -> redacted events -> physical presentation, including duplicates.
const CASES := {
	"basic": ["PLAY_BASIC", "svg2-turt", "bench_2", "pokemon_played"],
	"evolve": ["EVOLVE", "svg2-grot", "bench_0", "pokemon_evolved"],
	"energy": ["ATTACH_ENERGY", "sv1-ener-1", "bench_0", "energy_attached"],
	"tool": ["PLAY_TRAINER", "sv1-202", "bench_0", "tool_attached"],
	"potion": ["PLAY_TRAINER", "svf-potion", "active", "trainer_played"],
	"jet": ["ATTACH_ENERGY", "svi-jete", "bench_0", "energy_attached"],
}
var table: BattleTable
var failures: Array[String] = []
var records: Array[Dictionary] = []
var graphics := false
var output := "res://../build/battle-action-identity"
var done := false


func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("_run")


func check(ok: bool, message: String) -> void:
	if not ok and message not in failures: failures.append(message)


func _run() -> void:
	graphics = DisplayServer.get_name() != "headless"
	Engine.max_fps = 60
	root.size = Vector2i(1280, 768)
	root.content_scale_size = root.size
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	create_timer(180).timeout.connect(func() -> void:
		if not done:
			push_error("Action identity contract timed out")
			quit(1))
	table = load("res://scenes/battle/components/battle_table.tscn").instantiate() as BattleTable
	root.add_child(table)
	if "--transfers-only" not in OS.get_cmdline_user_args():
		for kind in CASES:
			for index in [0, 2, 4]: await _case(kind, index, "standard", 0)
		for mode in ["cinematic", "standard", "fast", "reduced"]:
			for viewer in [0, 1]:
				await _case("jet", 0, mode, viewer, true)
				await _case("basic", 2, mode, viewer)
	for viewer in [0, 1]:
		for index in [0, 1, 2]: await _transfer(index, viewer)
	var file := FileAccess.open(output.path_join("validation.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"cases": records, "failures": failures}, "\t"))
	file.close()
	table.queue_free()
	await process_frame
	done = true
	for failure in failures: push_error(failure)
	if failures.is_empty(): print("BATTLE_ACTION_IDENTITY_OK cases=%d graphics=%s" % [records.size(), graphics])
	quit(0 if failures.is_empty() else 1)


func _fixture(kind: String, same_species: bool) -> GameState:
	var state := GameState.new()
	state.revision = 30000 + records.size() * 100
	state.setup_stage = GameState.SETUP_COMPLETE
	state.active_player_idx = 0
	state.first_player_idx = 1
	state.turn_number = 4
	state.phase = "MAIN"
	for player in state.players:
		player.active = PokemonState.new("svg2-turt" if same_species else "svl-emol")
		player.prizes.assign(["sv1-ener-1", "sv1-ener-1"])
		player.deck.assign(["sv1-ener-1", "sv1-ener-1", "sv1-189"])
		player.hand.assign(["sv1-ener-1", "sv1-189"])
	var own := state.players[0]
	own.active.damage_counters = 2
	own.active.energy_card_ids.assign(["sv1-ener-1", "sv1-ener-1"])
	own.active.attached_tool_id = "sv1-202"
	own.bench[0] = PokemonState.new("svg2-turt")
	own.bench[0].energy_card_ids.assign(["sv1-ener-1"])
	own.bench[0].placed_this_turn = false
	own.bench[0].can_evolve_this_turn = true
	var id := str(CASES[kind][1])
	own.hand.assign([id, "sv1-189", id, "sv1-151", id])
	return state


func _case(kind: String, index: int, mode: String, viewer: int, same_species: bool = false) -> void:
	var key := "%s-%d-%s-p%d%s" % [kind, index, mode, viewer, "-same" if same_species else ""]
	root.get_node("AppSettings").animation_mode = mode
	var adapter := NativeRulesSessionAdapter.new(CardCatalog.shared())
	check(adapter.restore(_fixture(kind, same_species).snapshot(), 7289), key + ": restore failed")
	var before := adapter.state.clone_state()
	table.clear_presentation_for_resync()
	table.update_view(BattleViewModel.player_view_state(before, viewer), viewer, [], "", false, "local")
	await _settle(5)
	var identities: Array[String] = []
	for card in table.hand_views:
		if card.visible: identities.append(card.local_visual_id)
	var action: Dictionary = {}
	for candidate in adapter.legal_actions(0).concrete_actions():
		if candidate.kind != CASES[kind][0] or candidate.source == null or candidate.source.index != index: continue
		if candidate.target != null and not candidate.target.slot.is_empty() and candidate.target.slot != CASES[kind][2]: continue
		action = candidate.to_dict()
		break
	check(not action.is_empty(), key + ": no legal action")
	if action.is_empty(): return
	action.action_id = key
	var step := adapter.apply_action(action)
	check(step.success and step.pending_choice == null, key + ": action failed or unexpectedly suspended")
	if not step.success: return
	var events := PresentationEvent.normalize_all(step.events, adapter.state.revision, 0)
	var movement: Dictionary = {}
	for event in events:
		if event.event_type == CASES[kind][3]:
			movement = event
			break
	check(not movement.is_empty(), key + ": movement event missing")
	if movement.is_empty(): return
	check(int(movement.source.index) == index, key + ": event selects a different duplicate hand card")
	if kind in ["basic", "evolve", "energy", "tool", "jet"]:
		check(str(movement.target.slot) == CASES[kind][2], key + ": event targets the final slot instead of the action slot")
	if kind in ["energy", "jet"]:
		check(int(movement.target.index) == 1, key + ": attachment does not append to the original stack")
	var visible_events: Array[Dictionary] = []
	for event in events:
		var visible := PresentationEvent.for_player(event, viewer)
		if not visible.is_empty(): visible_events.append(visible)
	var snapshots := table.capture_presentation_snapshot()
	if viewer == 0:
		var plan := table.hand_presentation.plan_hand_sources(visible_events, snapshots, adapter.state.players[0].hand)
		var rows: Array = plan.get(str(movement.event_id), [])
		check(rows.size() == 1 and str(rows[0].visual_id) == identities[index], key + ": animation claims the wrong hand entity")
	var timeline: Array[String] = []
	var switched := func(event: Dictionary) -> void:
		if event.event_type == "switched":
			timeline.append("switch")
			var bench := table.presentation_runtime._feedback_card({"player": 0, "slot": "bench_0"})
			check(bench != null and bench.pokemon.energy_card_ids == ["sv1-ener-1", "svi-jete"], key + ": switch begins without the attached Jet Energy")
	var contacted := func(id: String) -> void:
		if id == str(movement.event_id): timeline.append("contact")
	table.director.event_started.connect(switched)
	table.render3d.world.feedback.impact_reached.connect(contacted)
	var request := BattleTransitionRequest.create(BattleViewModel.capture_player_view(adapter.state, viewer, [], "", false, "local"), visible_events, 0, BattleTransitionRequest.CAUSE_LOCAL_ACTION, key)
	var handle := table.submit_transition(request)
	var images: Array[Image] = []
	var timestamps: Array[int] = []
	var started := Time.get_ticks_msec()
	var frames := 0
	while not handle.is_completed() and frames < 360:
		await _settle(1)
		frames += 1
		if graphics and mode == "standard" and (kind == "jet" or kind == "basic") and frames % 3 == 0:
			images.append(root.get_texture().get_image())
			timestamps.append(Time.get_ticks_msec() - started)
		if kind == "jet":
			for entity in table.card_motion_layer.entities:
				if not is_instance_valid(entity) or not bool(entity.get_meta("slot_composite_motion", false)): continue
				var mover := entity as CardView
				var from_slot := str(mover.get_meta("slot_composite_from", ""))
				var expected: Array = ["sv1-ener-1", "svi-jete"] if from_slot == "bench_0" else ["sv1-ener-1", "sv1-ener-1"]
				check(mover.pokemon.energy_card_ids == expected, key + ": switch moved the wrong attachment stack")
	table.director.event_started.disconnect(switched)
	table.render3d.world.feedback.impact_reached.disconnect(contacted)
	check(handle.is_completed(), key + ": animation did not finish")
	if not handle.is_completed(): table.clear_presentation_for_resync()
	await _settle(3)
	if kind == "jet" and mode != "reduced": check(timeline == ["contact", "switch"], key + ": switch starts before energy contact or duplicates contact")
	if viewer == 0:
		identities.remove_at(index)
		var current := table.hand_views.filter(func(card: CardView) -> bool: return card.visible)
		check(current.size() == identities.size(), key + ": wrong settled hand count")
		for i in range(mini(current.size(), identities.size())):
			check(current[i].local_visual_id == identities[i] and current[i].hand_index == i, key + ": untouched duplicate changed physical identity")
	check(table.card_motion_layer.active_motion_count() == 0 and table.presentation_runtime.slot_covers.is_empty(), key + ": completed action left moving cards or slot covers")
	if not images.is_empty():
		images.append(root.get_texture().get_image())
		timestamps.append(Time.get_ticks_msec() - started)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output.path_join(key)))
		for i in range(images.size()): images[i].save_png(output.path_join(key).path_join("%04d.png" % i))
	records.append({"key": key, "kind": kind, "index": index, "mode": mode, "viewer": viewer, "events": events, "timeline": timeline, "frames": frames, "captures": images.size(), "timestamps_ms": timestamps})


func _settle(count: int) -> void:
	for frame in range(count):
		await process_frame
		if graphics: await RenderingServer.frame_post_draw
		else: table.render3d.sync_surfaces()


func _transfer(index: int, viewer: int) -> void:
	var key := "transfer-%d-p%d" % [index, viewer]
	root.get_node("AppSettings").animation_mode = "standard"
	var state := _fixture("energy", false)
	state.players[0].hand.assign(["svf-ensw2", "sv1-ener-1"])
	state.players[0].active.energy_card_ids.assign(["sv1-ener-1", "sv1-ener-1", "sv1-ener-1"])
	var adapter := NativeRulesSessionAdapter.new(CardCatalog.shared())
	check(adapter.restore(state.snapshot(), 8104), key + ": restore failed")
	table.clear_presentation_for_resync()
	table.update_view(BattleViewModel.player_view_state(state, viewer), viewer, [], "", false, "local")
	await _settle(4)
	var action: Dictionary = {}
	for candidate in adapter.legal_actions(0).concrete_actions():
		if candidate.kind == "PLAY_TRAINER" and candidate.source.card_id == "svf-ensw2":
			action = candidate.to_dict()
			break
	check(not action.is_empty(), key + ": no legal energy switch")
	if action.is_empty(): return
	action.action_id = key
	var step := adapter.apply_action(action)
	var event_log: Array[Dictionary] = []
	var choices := 0
	while step.success:
		var events := PresentationEvent.normalize_all(step.events, adapter.state.revision, 0)
		event_log.append_array(events)
		var visible_events: Array[Dictionary] = []
		for event in events:
			if event.event_type == "energy_attached":
				check(str(event.source.slot) == "active" and int(event.source.index) == index, key + ": energy transfer peels the wrong duplicate attachment")
				check(str(event.target.slot) == "bench_0" and int(event.target.index) == 1, key + ": energy transfer uses the wrong landing index")
			var visible := PresentationEvent.for_player(event, viewer)
			if not visible.is_empty(): visible_events.append(visible)
		var handle := table.submit_transition(BattleTransitionRequest.create(BattleViewModel.capture_player_view(adapter.state, viewer, [], "", false, "local"), visible_events, 0, BattleTransitionRequest.CAUSE_CHOICE, key))
		for frame in range(300):
			if handle.is_completed(): break
			await _settle(1)
		check(handle.is_completed(), key + ": transfer did not finish")
		if step.pending_choice == null: break
		choices += 1
		if choices > 4:
			check(false, key + ": choice chain did not terminate")
			break
		var chosen := ""
		for option in step.pending_choice.options:
			if option.ref == null: continue
			if option.ref.kind == "attachment":
				if option.ref.index == index:
					chosen = option.option_id
					break
				continue
			if option.ref.slot == "active":
				chosen = option.option_id
				break
			if option.ref.slot == "bench_0": chosen = option.option_id
		check(not chosen.is_empty(), key + ": no matching choice option")
		if chosen.is_empty(): break
		step = adapter.apply_choice(ChoiceResponse.new(step.pending_choice.request_id, [chosen]).to_dict())
	check(step.success, key + ": native transfer failed")
	check(event_log.any(func(event: Dictionary) -> bool: return event.event_type == "energy_attached"), key + ": no energy transfer occurred")
	check(table.card_motion_layer.active_motion_count() == 0, key + ": leftover movers")
	records.append({"key": key, "kind": "transfer", "index": index, "viewer": viewer, "events": event_log, "choices": choices, "captures": 0, "timestamps_ms": []})
