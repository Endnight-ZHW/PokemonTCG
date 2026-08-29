extends SceneTree

const OUTPUT_ROOT := "res://../build/ui-preview"
const PreviewHarness = preload("res://tests/ui_preview_harness.gd")
const FrontendScenario = preload("res://tests/ui_preview_frontend_scenario.gd")
const BattleScenario = preload("res://tests/ui_preview_battle_scenario.gd")
const SemanticChoiceScenario = preload("res://tests/ui_preview_semantic_choice_scenario.gd")
const BattleDetailScenario = preload("res://tests/ui_preview_battle_detail_scenario.gd")


func _initialize() -> void:
	root.size = Vector2i(1600, 900)
	call_deferred("_render_previews")


func _render_previews() -> void:
	var harness := PreviewHarness.new()
	harness.configure(self)
	# Re-apply the capture size after the project's desktop override initializes.
	root.size = Vector2i(1600, 900)
	await harness._settle_frontend(2)
	if not harness._enable_deterministic_preview_mode():
		push_error("AppSettings autoload is unavailable")
		harness._finish(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_ROOT))
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	if packed == null:
		push_error("Unable to load main UI scene")
		harness._finish(1)
		return
	var ui := packed.instantiate()
	root.add_child(ui)
	ui.initialize_ui()
	if root.min_size != Vector2i(900, 540):
		push_error("Desktop UI did not enforce the validated 900x540 minimum window")
		harness._finish(1)
		return
	Input.warp_mouse(Vector2(4, 4))
	await harness._settle_frontend(8)
	var user_args := OS.get_cmdline_user_args()
	if "--semantic-choice-only" in user_args:
		var semantic_scenario := SemanticChoiceScenario.new()
		semantic_scenario.configure(harness)
		await semantic_scenario.run(ui)
		return
	if "--battle-detail-only" in user_args:
		var detail_scenario := BattleDetailScenario.new()
		detail_scenario.configure(harness)
		await detail_scenario.run(ui)
		return
	var frontend_scenario := FrontendScenario.new()
	frontend_scenario.configure(harness)
	await frontend_scenario.run(ui)
	if harness.finished:
		return
	var battle_scenario := BattleScenario.new()
	battle_scenario.configure(harness)
	await battle_scenario.run(ui)
