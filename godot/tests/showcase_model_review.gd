extends SceneTree

## Close-up product views, independent of the deliberately limited title drag.
## Run with a graphical Godot: --script res://tests/showcase_model_review.gd
const OUTPUT := "res://../build/hinged-case-review/angles"

func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	root.size = Vector2i(1100, 1000)
	call_deferred("run")


func settle(frames: int = 8) -> void:
	for frame in range(frames):
		await process_frame
	await RenderingServer.frame_post_draw


func run() -> void:
	root.size = Vector2i(1100, 1000)
	var settings := root.get_node("AppSettings")
	settings.quality_profile = "high"
	settings.animation_mode = "reduced"
	var background := ColorRect.new()
	background.color = Color("efeee8")
	root.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var stage: Variant = load("res://ui/frontend/frontend_card_showcase_3d.gd").new()
	root.add_child(stage)
	stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage.set_deck("甲贺忍蛙ex", "Water", 60)
	var card_ids: Array[String] = [DeckVisualCatalog.representative_card(CardCatalog.shared(), "water")]
	stage.set_cards(card_ids)
	await settle(18)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	for card in stage._backs:
		card.hide()
	stage._coin.hide()
	stage._world.get_node("DisplayMat").hide()
	stage._world.get_node("CaseContactShadow").hide()
	var views := [["front", -18.0, 12.0], ["three-quarter", 20.0, 24.0],
		["side", 72.0, 12.0], ["left", -108.0, 12.0], ["rear", 154.0, 20.0],
		["top", 20.0, 65.0], ["underside", 20.0, -38.0]]
	for subject in ["case", "stand"]:
		stage._case_root.visible = subject == "case"
		stage._world.get_node("CardCradle").visible = subject == "stand"
		stage.cards[0].visible = subject == "stand"
		stage.cards[0].contact_shadow.hide()
		var target := Vector3(-1.15, 1.10, -0.25) if subject == "case" else Vector3(1.35, 0.99, 0.40)
		for view in views:
			var pitch := deg_to_rad(float(view[2]))
			stage.camera.position = target + Basis(Vector3.UP, deg_to_rad(float(view[1]))) * Vector3(0, sin(pitch), cos(pitch)) * 5.8
			stage.camera.look_at(target)
			await settle()
			capture(subject + "-" + str(view[0]))
			if subject == "stand" and view[0] == "three-quarter":
				stage.cards[0].hide()
				var stand_target := Vector3(1.35, 0.44, 0.48)
				stage.camera.position = stand_target + Basis(Vector3.UP, deg_to_rad(28.0)) * Vector3(0, 0.48, 0.88).normalized() * 4.3
				stage.camera.look_at(stand_target)
				await settle()
				capture("stand-empty")
				stage.cards[0].show()
		if subject == "case":
			for side in [-1.0, 1.0]:
				var joint_target: Vector3 = stage._case_root.to_global(Vector3(side * (ShowcaseCaseGeometry.WIDTH * 0.5 - 0.05), 2.04, -ShowcaseCaseGeometry.DEPTH * 0.5))
				stage.camera.position = joint_target + stage._case_root.basis * Vector3(side * 0.55, 0.30, -0.85).normalized() * 2.0
				stage.camera.look_at(joint_target)
				await settle()
				capture("case-" + ("left-joint" if side < 0 else "right-joint"))
			for opening in [35.0, 90.0]:
				stage._set_case_open(opening)
				await settle()
				var open_target: Vector3 = stage._case_root.to_global(Vector3(0, 1.65, 0))
				stage.camera.position = open_target + stage._case_root.basis * Vector3(0.52, 0.38, 0.86).normalized() * 8.0
				stage.camera.look_at(open_target)
				await settle()
				capture("case-open-" + str(int(opening)))
			stage._set_case_open(0)
			await settle()
	stage.free()
	background.free()
	print("SHOWCASE_MODEL_REVIEW_OK views=19")
	quit()


func capture(label: String) -> void:
	var result := root.get_texture().get_image().save_png(ProjectSettings.globalize_path(OUTPUT.path_join(label + ".png")))
	if result != OK:
		push_error("Could not capture " + label)
		quit(1)
