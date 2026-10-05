extends SceneTree

## Equal-size source and in-scene material comparison; no gameplay changes.
const OUTPUT := "res://../build/badge-style-review/comparison.png"
const FONT := preload("res://assets/ui/fonts/noto_sans_cjk_sc_medium.tres")
var stages: Array[FrontendCardShowcase3D] = []

func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("run")

func label_at(copy: String, rect: Rect2, pixels: int = 20) -> void:
	var label := Label.new()
	label.text = copy
	label.position = rect.position
	label.size = rect.size
	label.add_theme_font_override("font", FONT)
	label.add_theme_font_size_override("font_size", pixels)
	label.add_theme_color_override("font_color", HomePalette.TEXT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(label)

func run() -> void:
	root.size = Vector2i(1120, 670)
	root.content_scale_size = Vector2i(1120, 670)
	var settings := root.get_node("AppSettings")
	settings.animation_mode = "reduced"
	settings.quality_profile = "high"
	var background := ColorRect.new()
	background.color = HomePalette.BACKGROUND
	root.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label_at("属性角标 · 同尺寸对照", Rect2(0, 18, 1120, 44), 30)
	var types := ["Water", "Grass", "Metal", "Dragon"]
	var names := ["水", "草", "钢", "龙"]
	for index in range(4):
		var left := float(index) * 280.0
		label_at(names[index], Rect2(left, 76, 280, 32), 23)
		var image := TextureRect.new()
		image.position = Vector2(left + 60, 118)
		image.size = Vector2(160, 160)
		image.texture = ShowcaseFinishes.badge_for(types[index])
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		root.add_child(image)
		var stage := FrontendCardShowcase3D.new()
		stage.position = Vector2(left + 25, 350)
		stage.size = Vector2(230, 240)
		root.add_child(stage)
		stage.set_deck(names[index], types[index], 60)
		stages.append(stage)
	label_at("透明图标", Rect2(0, 291, 1120, 30), 17)
	label_at("相同灯光与镜头下的牌盒徽章", Rect2(0, 607, 1120, 30), 17)
	for frame in range(14):
		await process_frame
	for stage in stages:
		var target := stage._case_root.to_global(Vector3(-0.45, 1.79, ShowcaseCaseGeometry.FRONT))
		stage.camera.position = target + stage._case_root.basis * Vector3(0, 0.03, 0.65)
		stage.camera.look_at(target)
	for frame in range(8):
		await process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT.get_base_dir()))
	var result := root.get_texture().get_image().save_png(OUTPUT)
	print("HOME_BADGE_STYLE_REVIEW_OK" if result == OK else "HOME_BADGE_STYLE_REVIEW_FAILED")
	quit(0 if result == OK else 1)
