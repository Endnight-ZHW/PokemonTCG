class_name FrontendContractContext
extends RefCounted

const FRONT_THEME_PATH := "res://ui/frontend/front_end_theme.tres"
const GAME_THEME_PATH := "res://ui/game_theme.tres"
const FRONT_FONT_PATH := "res://assets/ui/fonts/NotoSansCJKsc-VF.ttf"
const FONT_WEIGHT_TAG := 0x77676874
const SAFE_INSET := 48
const MIN_TARGET_SIZE := 48.0
const EPSILON := 1.5
const TITLE_TIER_WIDE := 0
const TITLE_TIER_COMPACT_LANDSCAPE := 1
const TITLE_TIER_DENSE := 2
const TITLE_ENERGY_TYPES: Array[String] = [
	"Grass", "Fire", "Water", "Lightning",
	"Psychic", "Fighting", "Darkness", "Metal",
]
const ENERGY_ICON_CATALOG := preload("res://ui/energy_icon_catalog.gd")
const DISABLED_UI_ACTIONS: Array[StringName] = [
	&"ui_accept", &"ui_select", &"ui_cancel",
	&"ui_focus_next", &"ui_focus_prev",
	&"ui_left", &"ui_right", &"ui_up", &"ui_down",
	&"ui_page_up", &"ui_page_down", &"ui_home", &"ui_end",
]
const VIEWPORT_CASES: Array[Vector2i] = [
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(1024, 768),
	Vector2i(1024, 600),
	Vector2i(2000, 900),
]
const TITLE_PORTRAIT_CASES: Array[Vector2i] = [
	Vector2i(720, 1280),
	Vector2i(800, 1280),
]

const PAGE_SCENES := {
	"title": "res://scenes/title/title_page.tscn",
	"decks": "res://scenes/decks/deck_select_page.tscn",
	"network": "res://scenes/network/network_lobby_page.tscn",
	"settings": "res://ui/dialogs/settings_panel.tscn",
	"help": "res://ui/panels/help_panel.tscn",
	"deck_detail": "res://ui/panels/deck_detail_panel.tscn",
	"victory": "res://scenes/end/victory_screen.tscn",
}

var tree: SceneTree
var failures: Array[String] = []
var _settings_snapshot: Dictionary = {}
var _settings_node: Node
var _deck_start_payload: Array = []


func _init(contract_tree: SceneTree) -> void:
	tree = contract_tree


func _mount(
	scene_path: String,
	viewport_size: Vector2i,
	with_scroll: bool = false,
) -> Dictionary:
	tree.root.size = viewport_size
	var safe_host := MarginContainer.new()
	safe_host.name = "SafeInsetHost"
	safe_host.clip_contents = true
	safe_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	safe_host.add_theme_constant_override("margin_left", SAFE_INSET)
	safe_host.add_theme_constant_override("margin_top", SAFE_INSET)
	safe_host.add_theme_constant_override("margin_right", SAFE_INSET)
	safe_host.add_theme_constant_override("margin_bottom", SAFE_INSET)
	tree.root.add_child(safe_host)
	var content_host: Node = safe_host
	var scroll: ScrollContainer
	if with_scroll:
		scroll = ScrollContainer.new()
		scroll.name = "VerticalModalBody"
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		scroll.focus_mode = Control.FOCUS_NONE
		scroll.follow_focus = false
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		safe_host.add_child(scroll)
		content_host = scroll
	var packed := load(scene_path) as PackedScene
	_check(packed != null, "Unable to load frontend scene: %s" % scene_path)
	if packed == null:
		return {"surface": safe_host, "safe_host": safe_host, "scroll": scroll, "page": null}
	var page := packed.instantiate() as Control
	_check(page != null, "Frontend scene tree.root must be a Control: %s" % scene_path)
	if page:
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content_host.add_child(page)
	await _settle_layout()
	return {"surface": safe_host, "safe_host": safe_host, "scroll": scroll, "page": page}

func _unmount(mounted: Dictionary) -> void:
	var surface := mounted.get("surface") as Control
	if surface and is_instance_valid(surface):
		surface.queue_free()

func _settle_layout(frame_count: int = 3) -> void:
	for _frame in range(maxi(frame_count, 2)):
		await tree.process_frame

func _check_full_page(page: Control, safe_host: Control, label: String) -> void:
	var page_rect := page.get_global_rect()
	var safe_rect := _simulated_safe_rect(safe_host)
	_check(
		_rect_inside(page_rect, safe_rect),
		"%s: page escaped simulated 48px safe area. page=%s safe=%s" % [
			label, page_rect, safe_rect,
		],
	)

func _simulated_safe_rect(safe_host: Control) -> Rect2:
	var rect := safe_host.get_global_rect()
	return Rect2(
		rect.position + Vector2(SAFE_INSET, SAFE_INSET),
		Vector2(
			maxf(0.0, rect.size.x - SAFE_INSET * 2.0),
			maxf(0.0, rect.size.y - SAFE_INSET * 2.0),
		),
	)

func _check_named_inside(
	owner: Node,
	bounds: Rect2,
	names: Array,
	label: String,
) -> void:
	for node_name in names:
		var control := _find_control(owner, str(node_name))
		_check(control != null, "%s: missing key control %s" % [label, node_name])
		if control == null or not control.is_visible_in_tree():
			continue
		var rect := control.get_global_rect()
		_check(
			_rect_inside(rect, bounds),
			"%s: %s escaped safe bounds. rect=%s bounds=%s" % [
				label, node_name, rect, bounds,
			],
		)

func _check_horizontal_inside(control: Control, bounds: Rect2, label: String) -> void:
	var rect := control.get_global_rect()
	_check(
		rect.position.x >= bounds.position.x - EPSILON
		and rect.end.x <= bounds.end.x + EPSILON,
		"%s: panel exceeds horizontal safe bounds. rect=%s bounds=%s" % [
			label, rect, bounds,
		],
	)

func _check_named_non_overlapping(owner: Node, names: Array, label: String) -> void:
	var controls: Array[Control] = []
	for node_name in names:
		var control := _find_control(owner, str(node_name))
		if control and control.is_visible_in_tree():
			controls.append(control)
	for first_index in range(controls.size()):
		for second_index in range(first_index + 1, controls.size()):
			_check_pair_not_overlapping(controls[first_index], controls[second_index], label)

func _check_pointer_only_controls(
	owner: Node,
	label: String,
	bounds: Rect2 = Rect2(),
) -> void:
	_check(owner != null, "%s: pointer-only surface is unavailable" % label)
	if owner == null:
		return
	var targets: Array[Control] = []
	var invalid_navigation: Array[Control] = []
	_collect_pointer_targets(owner, targets)
	_collect_invalid_navigation_controls(owner, invalid_navigation)
	_check(not targets.is_empty(), "%s: page exposes no pointer/touch target" % label)
	for control in invalid_navigation:
		_check(
			false,
			"%s: control still accepts keyboard/controller focus: %s" % [
				label, control.get_path(),
			],
		)
	_check(
		owner.get_viewport().gui_get_focus_owner() == null,
		"%s: page unexpectedly owns GUI focus" % label,
	)
	for target in targets:
		var valid_mode := (
			target.focus_mode in [Control.FOCUS_NONE, Control.FOCUS_CLICK]
			if target is LineEdit
			else target.focus_mode == Control.FOCUS_NONE
		)
		_check(
			valid_mode,
			"%s: pointer target %s still accepts keyboard/controller focus" % [
				label, target.get_path(),
			],
		)
		if target is OptionButton:
			_check(
				not (target as OptionButton).get_popup().allow_search,
				"%s: option menu still accepts keyboard type-to-search: %s" % [
					label, target.get_path(),
				],
			)
		var rect := target.get_global_rect()
		_check(
			rect.size.x + EPSILON >= MIN_TARGET_SIZE
			and rect.size.y + EPSILON >= MIN_TARGET_SIZE,
			"%s: pointer target %s is smaller than 48x48 (%s)" % [
				label, target.get_path(), rect.size,
			],
		)
		if bounds.has_area():
			if not _has_scroll_ancestor(target, owner):
				_check(
					_rect_inside(rect, bounds),
					"%s: pointer target %s escaped safe bounds (%s)" % [
						label, target.get_path(), rect,
					],
				)
	for first_index in range(targets.size()):
		for second_index in range(first_index + 1, targets.size()):
			_check_pair_not_overlapping(targets[first_index], targets[second_index], label)

func _check_no_navigation_controls(owner: Node, label: String) -> void:
	var invalid_navigation: Array[Control] = []
	_collect_invalid_navigation_controls(owner, invalid_navigation)
	for control in invalid_navigation:
		_check(
			false,
			"%s: control still accepts keyboard/controller focus: %s" % [
				label, control.get_path(),
			],
		)

func _collect_pointer_targets(node: Node, output: Array[Control]) -> void:
	if node is Control:
		var control := node as Control
		if control != node.get_tree().root and (
			(control is BaseButton or control is Slider or control is LineEdit or control is CardView)
			and control.is_visible_in_tree()
			and control.mouse_filter != Control.MOUSE_FILTER_IGNORE
		):
			output.append(control)
	for child in node.get_children():
		_collect_pointer_targets(child, output)

func _collect_invalid_navigation_controls(node: Node, output: Array[Control]) -> void:
	if node is Control:
		var control := node as Control
		var valid_mode := (
			control.focus_mode in [Control.FOCUS_NONE, Control.FOCUS_CLICK]
			if control is LineEdit
			else control.focus_mode == Control.FOCUS_NONE
		)
		if not valid_mode:
			output.append(control)
	for child in node.get_children():
		_collect_invalid_navigation_controls(child, output)

func _has_scroll_ancestor(control: Control, boundary: Node) -> bool:
	var ancestor := control.get_parent()
	while ancestor and ancestor != boundary:
		if ancestor is ScrollContainer:
			return true
		ancestor = ancestor.get_parent()
	return false

func _find_control(owner: Node, node_name: String) -> Control:
	return owner.find_child(node_name, true, false) as Control

func _check_pair_not_overlapping(first: Control, second: Control, label: String) -> void:
	# Scroll children keep their full global rect even when most of the control is
	# clipped by the viewport. Compare the actually visible portions so a tile
	# below the fold is not reported as overlapping a fixed action bar.
	var overlap := _visible_control_rect(first).intersection(_visible_control_rect(second))
	_check(
		overlap.size.x <= EPSILON or overlap.size.y <= EPSILON,
		"%s: controls overlap: %s and %s (%s)" % [
			label, first.get_path(), second.get_path(), overlap,
		],
	)

func _visible_control_rect(control: Control) -> Rect2:
	var rect := control.get_global_rect()
	var ancestor := control.get_parent()
	while ancestor:
		if ancestor is ScrollContainer:
			rect = rect.intersection((ancestor as Control).get_global_rect())
		elif ancestor is Control and (ancestor as Control).clip_contents:
			rect = rect.intersection((ancestor as Control).get_global_rect())
		if not rect.has_area():
			return Rect2()
		ancestor = ancestor.get_parent()
	return rect

func _check_no_horizontal_scroll(owner: Node, label: String) -> void:
	var scrolls: Array[ScrollContainer] = []
	_collect_scroll_containers(owner, scrolls)
	for scroll in scrolls:
		_check(
			_not_horizontally_scrollable(scroll),
			"%s: horizontal scrollbar is visible at %s" % [label, scroll.get_path()],
		)

func _collect_scroll_containers(node: Node, output: Array[ScrollContainer]) -> void:
	if node is ScrollContainer and (node as ScrollContainer).is_visible_in_tree():
		output.append(node as ScrollContainer)
	for child in node.get_children():
		_collect_scroll_containers(child, output)

func _not_horizontally_scrollable(scroll: ScrollContainer) -> bool:
	return (
		scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED
		or not scroll.get_h_scroll_bar().visible
	)

func _rect_inside(inner: Rect2, outer: Rect2) -> bool:
	return (
		inner.position.x >= outer.position.x - EPSILON
		and inner.position.y >= outer.position.y - EPSILON
		and inner.end.x <= outer.end.x + EPSILON
		and inner.end.y <= outer.end.y + EPSILON
	)

func _files_recursive(path: String) -> Array[String]:
	var result: Array[String] = []
	var directory := DirAccess.open(path)
	if directory == null:
		_check(false, "Unable to inspect directory: %s" % path)
		return result
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			var child_path := path.path_join(entry)
			if directory.current_is_dir():
				result.append_array(_files_recursive(child_path))
			else:
				result.append(child_path)
		entry = directory.get_next()
	directory.list_dir_end()
	return result

func _capture_settings() -> Dictionary:
	return {
		"master_volume": _settings_node.get("master_volume"),
		"music_volume": _settings_node.get("music_volume"),
		"sfx_volume": _settings_node.get("sfx_volume"),
		"muted": _settings_node.get("muted"),
		"reduced_motion": _settings_node.get("reduced_motion"),
		"card_cache_size": _settings_node.get("card_cache_size"),
		"animation_mode": _settings_node.get("animation_mode"),
		"quality_profile": _settings_node.get("quality_profile"),
	}

func _apply_reduced_motion() -> void:
	_settings_node.call(
		"update",
		float(_settings_snapshot.master_volume),
		bool(_settings_snapshot.muted),
		true,
		int(_settings_snapshot.card_cache_size),
		"reduced",
		str(_settings_snapshot.quality_profile),
		float(_settings_snapshot.music_volume),
		float(_settings_snapshot.sfx_volume),
	)

func _restore_settings() -> void:
	if _settings_snapshot.is_empty():
		return
	_settings_node.call(
		"update",
		float(_settings_snapshot.master_volume),
		bool(_settings_snapshot.muted),
		bool(_settings_snapshot.reduced_motion),
		int(_settings_snapshot.card_cache_size),
		str(_settings_snapshot.animation_mode),
		str(_settings_snapshot.quality_profile),
		float(_settings_snapshot.music_volume),
		float(_settings_snapshot.sfx_volume),
	)

func _case_label(page_name: String, viewport_size: Vector2i) -> String:
	return "%s@%dx%d+safe%d" % [
		page_name,
		viewport_size.x,
		viewport_size.y,
		SAFE_INSET,
	]

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _contrast_ratio(first: Color, second: Color) -> float:
	var first_luminance := _relative_luminance(first)
	var second_luminance := _relative_luminance(second)
	var lighter := maxf(first_luminance, second_luminance)
	var darker := minf(first_luminance, second_luminance)
	return (lighter + 0.05) / (darker + 0.05)

func _composite_color(foreground: Color, background: Color) -> Color:
	return Color(
		foreground.r * foreground.a + background.r * (1.0 - foreground.a),
		foreground.g * foreground.a + background.g * (1.0 - foreground.a),
		foreground.b * foreground.a + background.b * (1.0 - foreground.a),
		1.0,
	)

func _relative_luminance(color: Color) -> float:
	return (
		0.2126 * _linear_color_channel(color.r)
		+ 0.7152 * _linear_color_channel(color.g)
		+ 0.0722 * _linear_color_channel(color.b)
	)

func _linear_color_channel(value: float) -> float:
	return (
		value / 12.92
		if value <= 0.04045
		else pow((value + 0.055) / 1.055, 2.4)
	)
