extends SceneTree

const Harness = preload("res://tests/ui_preview_harness.gd")
const OUTPUT := "res://../build/happy4-preview"
var failures: Array[String] = []
var harness: RefCounted
var ui: Control


func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("run")


func run() -> void:
	harness = Harness.new()
	harness.configure(self)
	harness._enable_deterministic_preview_mode()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	ui = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(ui)
	ui.initialize_ui()
	await harness._settle_rendered(6)
	for dimensions in [Vector2i(1600,900), Vector2i(900,540)]:
		root.size = dimensions
		await harness._settle_rendered(5)
		ui.shell_view.show_deck_select("local")
		var page := ui.screen_host.get_child(0) as DeckSelectPage
		if page.deck_count() != 14: failures.append("Deck gallery must expose 14 presets")
		for suffix in ["decidueye", "melmetal", "koraidon", "miraidon"]:
			var key: String = "happy4_" + str(suffix)
			page.select_deck(0,key)
			page.select_deck(1,key)
			page._on_deck_tile_pressed(key)
			await harness._settle_rendered(4)
			page.gallery_scroll.ensure_control_visible(page._tiles[key])
			await harness._settle_rendered(2)
			if page.selected_deck_key(0) != key or page.selected_deck_key(1) != key:
				failures.append("Same deck assignment failed: " + key)
			capture("deck-%s-%d" % [suffix,dimensions.x])
		if not ui._start_local_match("happy4_melmetal", "happy4_koraidon"):
			failures.append("Cannot mount the battle view with the new decks")
		await harness._settle_rendered(6)
		ui.modal_host_controller.close()
		for kind in ["metal-look","metal-distribute","sada","rika","future-search","turo","power-shot"]:
			var setup := create_choice(kind)
			if setup.is_empty(): continue
			harness._update_battle_preview(ui,setup.state,[])
			ui._show_choice_overlay(setup.choice)
			await harness._settle_rendered(5)
			if kind == "turo":
				if ui.battle_screen.choice_target_options.size() != 2 or not ui.battle_screen.choice_target_prompt.contains("放回手牌"):
					failures.append("Turo must expose both Pokemon as field targets with its return prompt")
			else:
				if not ui.modal_layer.visible or ui.active_choice_panel == null:
					failures.append("Choice overlay absent: " + kind)
				if not Rect2(Vector2.ZERO,ui.size).grow(2).encloses(ui.modal_panel.get_global_rect()):
					failures.append("Modal overflow: %s %d" % [kind, dimensions.x])
			if kind == "sada":
				var targets: Array[String] = []
				for option in setup.choice.options:
					if str(option.ref.slot) == "active": targets.append(option.option_id)
				if targets.size() >= 2:
					ui._toggle_choice(targets[0])
					ui._toggle_choice(targets[1])
					if ui.selected_choice_ids.size() > 1:
						failures.append("Sada UI allowed two attachments to one target")
			capture("choice-%s-%d" % [kind,dimensions.x])
			ui.modal_host_controller.close()
			await harness._settle_rendered(3)
	for failure in failures: push_error(failure)
	if failures.is_empty(): print("HAPPY4_VISUAL_CONTRACT_OK captures=22")
	harness._finish(0 if failures.is_empty() else 1)


func capture(name: String) -> void:
	if root.get_texture().get_image().save_png(ProjectSettings.globalize_path(OUTPUT + "/" + name + ".png")) != OK:
		failures.append("Capture failed: " + name)


func create_choice(kind: String) -> Dictionary:
	var state := GameState.new()
	state.setup_stage = GameState.SETUP_COMPLETE
	state.active_player_idx = 0
	state.first_player_idx = 1
	state.turn_number = 4
	state.phase = "MAIN"
	state.revision = 80
	for player in state.players:
		player.active = PokemonState.new("csvh4-020")
		player.deck.assign(["csvh4-024","csvh4-017","csvh4-003","sv1-ener-8","sv1-ener-8","sv1-151"])
		player.prizes.assign(["sv1-ener-8","sv1-ener-8","sv1-ener-8"])
	var id: String = {"sada":"csvh4-046","rika":"csvh4-051","future-search":"csvh4-035","turo":"csvh4-057"}.get(kind,"csvh4-017")
	state.players[0].active = PokemonState.new("csvh4-003" if kind == "power-shot" else "csvh4-017" if kind.begins_with("metal") else "csvh4-022")
	state.players[0].bench[0] = PokemonState.new("csvh4-020" if kind.begins_with("metal") else "csvh4-005")
	state.players[0].hand.assign([id,"sv1-ener-1","sv1-ener-1"])
	state.players[0].discard.assign(["sv1-ener-6","sv1-ener-2"])
	state.players[0].active.energy_card_ids.assign(["sv1-ener-1"])
	var adapter := NativeRulesSessionAdapter.new(CardCatalog.shared())
	if not adapter.restore(state.snapshot(),9123):
		failures.append("Visual fixture restore: " + kind)
		return {}
	var step: StepResult
	for candidate in adapter.legal_actions(0).concrete_actions():
		var row := candidate.to_dict()
		var matches := candidate.kind == "USE_ABILITY" if kind.begins_with("metal") else candidate.kind == "DECLARE_ATTACK" and candidate.attack_index() == 1 if kind == "power-shot" else candidate.kind == "PLAY_TRAINER" and str(row.source.card_id) == id
		if matches:
			row["action_id"] = "visual_" + kind
			step = adapter.apply_action(row)
			break
	if step == null or not step.success or step.pending_choice == null:
		failures.append("No real choice: " + kind)
		return {}
	if kind in ["metal-distribute","future-search"]:
		var ids: Array[String] = []
		for option in step.pending_choice.options.slice(0,step.pending_choice.max_select): ids.append(option.option_id)
		step = adapter.apply_choice(ChoiceResponse.new(step.pending_choice.request_id,ids).to_dict())
		if not step.success or step.pending_choice == null:
			failures.append("No continued choice: " + kind)
			return {}
	return {"state":adapter.state,"choice":step.pending_choice}
