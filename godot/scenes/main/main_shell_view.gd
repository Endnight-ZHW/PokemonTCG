class_name MainShellView
extends Node

const FRONTEND_THEME := preload("res://ui/frontend/front_end_theme.tres")
const TITLE_SCENE := preload("res://scenes/title/title_page.tscn")
const DECK_SELECT_SCENE := preload("res://scenes/decks/deck_select_page.tscn")
const NETWORK_LOBBY_SCENE := preload("res://scenes/network/network_lobby_page.tscn")
const BATTLE_SCENE := preload("res://scenes/battle/components/battle_table.tscn")
const VICTORY_SCENE := preload("res://scenes/end/victory_screen.tscn")
const SCREEN_TITLE := "title"
const SCREEN_DECKS := "decks"
const SCREEN_NETWORK := "network"
const SCREEN_END := "end"
const MODE_LOCAL := "local"
const MODE_CHALLENGE := "challenge"
const MODE_NETWORK := "network"
const SCREEN_GAME := "game"
const DESIGN_CANVAS_SIZE := Vector2i(1600, 900)
const MIN_RESPONSIVE_LANDSCAPE_SIZE := Vector2i(900, 540)
const MIN_RESPONSIVE_PORTRAIT_SIZE := Vector2i(640, 960)
const SYNTHETIC_WINDOW_FLOOR := Vector2i(320, 240)

@onready var safe_area: MarginContainer = %SafeArea
@onready var screen_host: Control = %ScreenHost
@onready var title_backdrop: Control = %TitleFullBleedBackdrop
@onready var toast_label: Label = %Toast
@onready var loading_layer: Control = %LoadingLayer
@onready var loading_label: Label = %LoadingLabel

var main: Variant
var _toast_tween: Tween
var _toast_generation := 0
var _responsive_canvas_window: Window
var _original_content_scale_size := Vector2i.ZERO
var _original_window_min_size := Vector2i.ZERO
var _last_responsive_content_scale_size := Vector2i.ZERO


func configure(owner: Control) -> void:
	main = owner
	# initialize_ui() is also exercised synchronously by ABI contracts before the
	# normal ready notification. Resolve scene-owned nodes here as well as through
	# @onready so the shell has one deterministic initialization path.
	safe_area = owner.get_node_or_null("SafeArea") as MarginContainer
	screen_host = owner.get_node_or_null("SafeArea/ScreenHost") as Control
	title_backdrop = owner.get_node_or_null("TitleFullBleedBackdrop") as Control
	toast_label = owner.get_node_or_null("Toast") as Label
	loading_layer = owner.get_node_or_null("LoadingLayer") as Control
	loading_label = owner.get_node_or_null(
		"LoadingLayer/Center/Panel/Margin/Content/LoadingLabel"
	) as Label


func _exit_tree() -> void:
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = null


func clear_screen() -> void:
	if main:
		main._startup_choreography_generation += 1
		main._startup_choreography_running = false
		main.current_network_page = null
	if title_backdrop:
		title_backdrop.visible = false
	if screen_host == null:
		return
	for child in screen_host.get_children():
		screen_host.remove_child(child)
		child.queue_free()


func mount(scene: PackedScene) -> Node:
	if scene == null or screen_host == null:
		return null
	clear_screen()
	var page := scene.instantiate()
	screen_host.add_child(page)
	return page


func show_loading(message: String) -> void:
	if loading_layer == null:
		return
	loading_label.text = message
	loading_layer.visible = true


func hide_loading() -> void:
	if loading_layer:
		loading_layer.visible = false

func show_toast(message: String, is_error: bool = false) -> void:
	if message.strip_edges().is_empty():
		return
	_toast_generation += 1
	toast_label.theme = FRONTEND_THEME if main.current_screen != SCREEN_GAME else null
	toast_label.theme_type_variation = (
		&"FrontToastLabel" if main.current_screen != SCREEN_GAME else &""
	)
	toast_label.set("accessibility_live", 2 if is_error else 1)
	var toast_generation := _toast_generation
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = null
	toast_label.text = message
	toast_label.modulate = Color.WHITE
	if is_error:
		toast_label.add_theme_color_override("font_color", Color("#ff9aa4"))
	else:
		toast_label.remove_theme_color_override("font_color")
	_layout_toast()
	# The battle header finishes its container layout at the end of the frame.
	# Re-evaluate once so a toast shown while entering battle uses the final header gap.
	call_deferred("_layout_toast")
	toast_label.visible = true
	if not FrontendMotion.decorative_motion_enabled():
		toast_label.modulate.a = 1.0
		get_tree().create_timer(2.0).timeout.connect(
			func() -> void:
				if (
					toast_generation == _toast_generation
					and toast_label
					and toast_label.text == message
				):
					toast_label.visible = false
		)
		return
	toast_label.modulate.a = 0.0
	_toast_tween = create_tween()
	_toast_tween.tween_property(toast_label, "modulate:a", 1.0, 0.12)
	_toast_tween.tween_interval(2.0)
	_toast_tween.tween_property(toast_label, "modulate:a", 0.0, 0.2)
	_toast_tween.tween_callback(func() -> void:
		if toast_generation == _toast_generation and toast_label:
			toast_label.visible = false
		_toast_tween = null
	)

func safe_insets_to_canvas(
	window_position: Vector2i,
	window_size: Vector2i,
	safe_rect: Rect2i,
	logical_size: Vector2,
) -> Vector4:
	if (
		window_size.x <= 0
		or window_size.y <= 0
		or safe_rect.size.x <= 0
		or safe_rect.size.y <= 0
		or logical_size.x <= 0.0
		or logical_size.y <= 0.0
	):
		return Vector4.ZERO
	var window_rect := Rect2i(window_position, window_size)
	var visible_safe_rect := window_rect.intersection(safe_rect)
	if visible_safe_rect.size.x <= 0 or visible_safe_rect.size.y <= 0:
		return Vector4.ZERO
	var canvas_per_pixel := Vector2(
		logical_size.x / float(window_size.x),
		logical_size.y / float(window_size.y),
	)
	return Vector4(
		maxf(0.0, float(visible_safe_rect.position.x - window_position.x))
			* canvas_per_pixel.x,
		maxf(0.0, float(visible_safe_rect.position.y - window_position.y))
			* canvas_per_pixel.y,
		maxf(0.0, float(window_rect.end.x - visible_safe_rect.end.x))
			* canvas_per_pixel.x,
		maxf(0.0, float(window_rect.end.y - visible_safe_rect.end.y))
			* canvas_per_pixel.y,
	)

func safe_content_size() -> Vector2:
	var full_size: Vector2 = main.size
	if safe_area and safe_area.size.x > 0.0 and safe_area.size.y > 0.0:
		full_size = safe_area.size
	if full_size.x <= 0.0 or full_size.y <= 0.0:
		full_size = main.get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	if safe_area == null:
		return full_size
	return Vector2(
		maxf(1.0, full_size.x
			- safe_area.get_theme_constant("margin_left")
			- safe_area.get_theme_constant("margin_right")),
		maxf(1.0, full_size.y
			- safe_area.get_theme_constant("margin_top")
			- safe_area.get_theme_constant("margin_bottom")),
	)

func configure_responsive_canvas() -> void:
	var window := get_window()
	if window == null:
		return
	if _responsive_canvas_window == null:
		_responsive_canvas_window = window
		_original_content_scale_size = window.content_scale_size
		_original_window_min_size = window.min_size
	if (
		DisplayServer.get_name().to_lower() != "headless"
		and not OS.has_feature("mobile")
		and not OS.has_feature("web")
	):
		window.min_size = MIN_RESPONSIVE_LANDSCAPE_SIZE
	if not window.size_changed.is_connected(_on_responsive_window_size_changed):
		window.size_changed.connect(_on_responsive_window_size_changed)
	apply_responsive_canvas()

func apply_responsive_canvas() -> void:
	var window := get_window()
	if window == null:
		return
	var target := responsive_content_scale_size(
		window.size,
		DESIGN_CANVAS_SIZE,
	)
	if target.x <= 0 or target.y <= 0:
		return
	if window.content_scale_size != target:
		window.content_scale_size = target
	_last_responsive_content_scale_size = target

func restore_responsive_canvas() -> void:
	if (
		_responsive_canvas_window == null
		or not is_instance_valid(_responsive_canvas_window)
		or _original_content_scale_size.x <= 0
		or _original_content_scale_size.y <= 0
	):
		return
	# Tests and editor previews can mount Main transiently. Only restore a value
	# still owned by this instance so another live shell cannot be overwritten.
	if (
		_last_responsive_content_scale_size != Vector2i.ZERO
		and _responsive_canvas_window.content_scale_size
		== _last_responsive_content_scale_size
	):
		_responsive_canvas_window.content_scale_size = _original_content_scale_size
	if _responsive_canvas_window.min_size == MIN_RESPONSIVE_LANDSCAPE_SIZE:
		_responsive_canvas_window.min_size = _original_window_min_size
	if _responsive_canvas_window.size_changed.is_connected(
		_on_responsive_window_size_changed
	):
		_responsive_canvas_window.size_changed.disconnect(
			_on_responsive_window_size_changed
		)
	_responsive_canvas_window = null

func _on_responsive_window_size_changed() -> void:
	apply_responsive_canvas()
	# content_scale_size changes the logical Control tree in the same frame. Safe
	# insets and modal budgets must be recomputed after that resize has propagated.
	call_deferred("apply_safe_area")

func responsive_content_scale_size(
	window_size: Vector2i,
	design_size: Vector2i = DESIGN_CANVAS_SIZE,
) -> Vector2i:
	if (
		window_size.x <= 0
		or window_size.y <= 0
		or design_size.x <= 0
		or design_size.y <= 0
	):
		return design_size
	# Below the native compact layouts, render the smallest validated canvas and
	# let stretch scaling preserve the complete UI instead of reflowing cards and
	# controls on top of one another. Desktop windows are clamped to the landscape
	# minimum; this fallback primarily protects embedded/mobile edge cases.
	var minimum_size := (
		MIN_RESPONSIVE_PORTRAIT_SIZE
		if window_size.y > window_size.x
		else MIN_RESPONSIVE_LANDSCAPE_SIZE
	)
	# Script-only headless contracts use a synthetic 64×64 root. It is not a
	# display shape, so keep the design canvas rather than selecting a portrait
	# layout from that placeholder aspect ratio.
	if (
		window_size.x < SYNTHETIC_WINDOW_FLOOR.x
		or window_size.y < SYNTHETIC_WINDOW_FLOOR.y
	):
		return design_size
	if (
		window_size.x < minimum_size.x
		or window_size.y < minimum_size.y
	):
		return minimum_size
	var fit_scale := minf(
		float(window_size.x) / float(design_size.x),
		float(window_size.y) / float(design_size.y),
	)
	# canvas_items is retained for ultrawide/large displays, but it must never
	# downsample the UI below 1 physical pixel per logical pixel. Besides keeping
	# 48 px targets touchable, this lets compact pages observe their real space.
	return window_size if fit_scale < 1.0 else design_size

func apply_safe_area() -> void:
	if safe_area == null:
		return
	var left := 18
	var top := 14
	var right := 18
	var bottom := 14
	var window := get_window()
	if window == null:
		safe_area.add_theme_constant_override("margin_left", left)
		safe_area.add_theme_constant_override("margin_top", top)
		safe_area.add_theme_constant_override("margin_right", right)
		safe_area.add_theme_constant_override("margin_bottom", bottom)
		return
	var window_size := window.size
	var logical_size: Vector2 = main.size
	if logical_size.x <= 0.0 or logical_size.y <= 0.0:
		logical_size = main.get_viewport_rect().size
	var safe_rect := DisplayServer.get_display_safe_area()
	var safe_insets := safe_insets_to_canvas(
		window.position,
		window_size,
		safe_rect,
		logical_size,
	)
	left = maxi(left, ceili(safe_insets.x))
	top = maxi(top, ceili(safe_insets.y))
	right = maxi(right, ceili(safe_insets.z))
	bottom = maxi(bottom, ceili(safe_insets.w))
	safe_area.add_theme_constant_override("margin_left", left)
	safe_area.add_theme_constant_override("margin_top", top)
	safe_area.add_theme_constant_override("margin_right", right)
	safe_area.add_theme_constant_override("margin_bottom", bottom)
	for path in ["ModalLayer/Center", "LoadingLayer/Center"]:
		var safe_center := main.get_node_or_null(path) as Control
		if safe_center:
			safe_center.offset_left = left
			safe_center.offset_top = top
			safe_center.offset_right = -right
			safe_center.offset_bottom = -bottom
	_layout_toast(logical_size, left, top, right, bottom)
	if (
		main.modal_host_controller
		and main.modal_layer
		and main.modal_layer.visible
		and main.modal_host_controller.active_spec
	):
		main.modal_host_controller.update_available_size(safe_content_size())

func _layout_toast(
	logical_size: Vector2 = Vector2.ZERO,
	left: int = -1,
	top: int = -1,
	right: int = -1,
	bottom: int = -1,
) -> void:
	if toast_label == null:
		return
	if logical_size.x <= 0.0 or logical_size.y <= 0.0:
		logical_size = main.size
		if logical_size.x <= 0.0 or logical_size.y <= 0.0:
			logical_size = main.get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	if safe_area:
		if left < 0:
			left = safe_area.get_theme_constant("margin_left")
		if top < 0:
			top = safe_area.get_theme_constant("margin_top")
		if right < 0:
			right = safe_area.get_theme_constant("margin_right")
		if bottom < 0:
			bottom = safe_area.get_theme_constant("margin_bottom")
	left = maxi(left, 0)
	top = maxi(top, 0)
	right = maxi(right, 0)
	bottom = maxi(bottom, 0)

	toast_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	if main.current_screen == SCREEN_GAME and main.battle_screen and is_instance_valid(main.battle_screen):
		# The log is now a drawer layered over the right edge of the table. Anchoring
		# battle feedback to that legacy panel puts confirmations over the deck and
		# discard zones even while the drawer is closed. Use the reserved header gap
		# between the menu and phase status instead; it remains outside card play.
		var header_lane: Rect2 = main.battle_screen.toast_anchor_rect()
		if header_lane.size.x >= 180.0:
			var battle_width := minf(300.0, header_lane.size.x)
			var battle_height := _toast_content_height(battle_width, 44.0, 52.0)
			var header_rect := Rect2(
				Vector2(
					header_lane.get_center().x - battle_width * 0.5,
					header_lane.get_center().y - battle_height * 0.5,
				),
				Vector2(battle_width, battle_height),
			)
			# This is a scene-reserved header lane and is already outside the
			# tabletop. Preserve its exact coordinates; compact layouts without
			# this lane use the obstacle-aware fallback below.
			toast_label.position = header_rect.position - main.global_position
			toast_label.size = header_rect.size
			return
		# On compact layouts the header has no 180 px gap. Keep the toast out of
		# the fanned opponent hand instead of falling back to the screen centre,
		# where it can cover the card backs at 900x540.
		var battle_safe_rect := _battle_toast_safe_rect(
			logical_size, left, top, right, bottom)
		var compact_width := minf(360.0, battle_safe_rect.size.x)
		var compact_height := _toast_content_height(compact_width, 44.0, 64.0)
		_apply_battle_toast_rect(
			Rect2(
				Vector2(
					battle_safe_rect.get_center().x - compact_width * 0.5,
					battle_safe_rect.position.y + 4.0,
				),
				Vector2(compact_width, compact_height),
			),
			battle_safe_rect,
		)
		return

	# Front-end pages have no command rail, so retain a centered safe-area status chip.
	var available_width := maxf(1.0, logical_size.x - left - right - 32.0)
	var toast_width := minf(560.0, available_width)
	var toast_height := _toast_content_height(toast_width, 48.0, 72.0)
	toast_label.position = Vector2(
		clampf((logical_size.x - toast_width) * 0.5, float(left + 16), logical_size.x - right - toast_width - 16.0),
		float(top + 12),
	)
	toast_label.size = Vector2(toast_width, toast_height)

func _battle_toast_safe_rect(
	logical_size: Vector2,
	left: int,
	top: int,
	right: int,
	bottom: int,
) -> Rect2:
	var origin: Vector2 = main.global_position + Vector2(left + 12, top + 8)
	return Rect2(
		origin,
		Vector2(
			maxf(1.0, logical_size.x - left - right - 24.0),
			maxf(1.0, logical_size.y - top - bottom - 16.0),
		),
	)

func _apply_battle_toast_rect(preferred: Rect2, safe_rect: Rect2) -> void:
	var resolved := _clamp_rect_to_rect(preferred, safe_rect)
	var opponent_hand_rect := _opponent_hand_visual_rect()
	if (
		opponent_hand_rect.size.x > 1.0
		and opponent_hand_rect.size.y > 1.0
		and resolved.intersects(opponent_hand_rect)
	):
		resolved = _toast_rect_outside_obstacle(resolved, opponent_hand_rect, safe_rect)
	toast_label.position = resolved.position - main.global_position
	toast_label.size = resolved.size

func _opponent_hand_visual_rect() -> Rect2:
	if main.battle_screen == null or not is_instance_valid(main.battle_screen):
		return Rect2()
	return main.battle_screen.toast_avoidance_rect()

func _toast_rect_outside_obstacle(
	preferred: Rect2,
	obstacle: Rect2,
	safe_rect: Rect2,
) -> Rect2:
	const GAP := 10.0
	var candidates: Array[Rect2] = []
	var above := Rect2(
		Vector2(preferred.position.x, obstacle.position.y - GAP - preferred.size.y),
		preferred.size,
	)
	if safe_rect.encloses(above):
		candidates.append(above)
	var left_width := obstacle.position.x - GAP - safe_rect.position.x
	var right_width := safe_rect.end.x - obstacle.end.x - GAP
	var add_side := func(on_right: bool, available_width: float) -> void:
		if available_width < 180.0:
			return
		var width := minf(preferred.size.x, available_width)
		var x := obstacle.end.x + GAP if on_right else obstacle.position.x - GAP - width
		var y := clampf(
			preferred.position.y,
			safe_rect.position.y,
			maxf(safe_rect.position.y, safe_rect.end.y - preferred.size.y),
		)
		candidates.append(Rect2(Vector2(x, y), Vector2(width, preferred.size.y)))
	if right_width >= left_width:
		add_side.call(true, right_width)
		add_side.call(false, left_width)
	else:
		add_side.call(false, left_width)
		add_side.call(true, right_width)
	var below := Rect2(
		Vector2(preferred.position.x, obstacle.end.y + GAP),
		preferred.size,
	)
	below = _clamp_rect_to_rect(below, safe_rect)
	if not below.intersects(obstacle):
		candidates.append(below)
	for candidate in candidates:
		var fitted := _clamp_rect_to_rect(candidate, safe_rect)
		if not fitted.intersects(obstacle):
			return fitted
	return _clamp_rect_to_rect(preferred, safe_rect)

func _clamp_rect_to_rect(rect: Rect2, bounds: Rect2) -> Rect2:
	var fitted := rect
	fitted.size.x = minf(fitted.size.x, bounds.size.x)
	fitted.size.y = minf(fitted.size.y, bounds.size.y)
	fitted.position.x = clampf(
		fitted.position.x,
		bounds.position.x,
		maxf(bounds.position.x, bounds.end.x - fitted.size.x),
	)
	fitted.position.y = clampf(
		fitted.position.y,
		bounds.position.y,
		maxf(bounds.position.y, bounds.end.y - fitted.size.y),
	)
	return fitted

func _toast_content_height(width: float, minimum: float, maximum: float) -> float:
	if toast_label == null or toast_label.text.is_empty():
		return minimum
	var usable_width := maxf(80.0, width - 28.0)
	# Chinese glyphs are close to one font-height wide. This estimate keeps short
	# confirmations on one line and reserves up to three lines for network errors.
	var characters_per_line := maxi(6, floori(usable_width / 15.0))
	var line_count := 0
	for paragraph in toast_label.text.split("\n", true):
		line_count += maxi(1, ceili(float(paragraph.length()) / float(characters_per_line)))
	return clampf(16.0 + float(line_count) * 20.0, minimum, maximum)


func show_title() -> void:
	main._stop_ai()
	main._stop_network()
	if main.modal_layer and main.modal_layer.visible:
		main.modal_host_controller.close()
	hide_loading()
	main.current_screen = SCREEN_TITLE
	main.battle_screen = null
	if main.audio_director:
		main.audio_director.play_music("title")
	var page := mount(TITLE_SCENE) as TitlePage
	if title_backdrop:
		title_backdrop.visible = true
	page.set_embedded_backdrop_visible(false)
	page.configure("v%s" % AppState.APP_VERSION)
	page.mode_selected.connect(show_deck_select)
	page.network_selected.connect(show_network_setup)
	page.settings_requested.connect(main._show_settings)
	page.help_requested.connect(main._show_help)

func show_network_setup(kind: String) -> void:
	main._play_click()
	main._stop_network()
	main.network_kind = kind if kind in ["lan", "relay"] else "lan"
	main.game_mode = MODE_NETWORK
	main.current_screen = SCREEN_NETWORK
	var page := mount(NETWORK_LOBBY_SCENE) as NetworkLobbyPage
	main.current_network_page = page
	page.configure(main.catalog, main.network_kind, AppSettings.relay_url)
	page.back_requested.connect(show_title)
	page.kind_changed.connect(main._on_network_kind_changed)
	page.connect_requested.connect(main._on_network_connect_requested)

func show_deck_select(mode: String = MODE_LOCAL) -> void:
	main._play_click()
	main.game_mode = mode
	main.current_screen = SCREEN_DECKS
	var page := mount(DECK_SELECT_SCENE) as DeckSelectPage
	page.configure(main.catalog, main.game_mode)
	page.back_requested.connect(show_title)
	page.deck_details_requested.connect(main._show_deck_details)
	page.start_requested.connect(main._on_match_start_requested)

func build_game_screen() -> void:
	main.current_screen = SCREEN_GAME
	clear_screen()
	main.battle_screen = BATTLE_SCENE.instantiate() as BattleTable
	main.battle_screen.name = "GameScreen"
	main.battle_screen.menu_requested.connect(main._show_pause_overlay)
	main.battle_screen.selection_clear_requested.connect(main._on_selection_clear_requested)
	main.battle_screen.hand_card_selected.connect(main._select_hand_card)
	main.battle_screen.pokemon_selected.connect(main._on_battle_pokemon_selected)
	main.battle_screen.action_requested.connect(main._execute_action)
	main.battle_screen.card_drop_requested.connect(main._on_battle_card_dropped)
	main.battle_screen.inspect_card_requested.connect(main._show_card_inspector)
	main.battle_screen.inspect_zone_requested.connect(main._show_zone_inspector)
	main.battle_screen.choice_target_selected.connect(main._on_battle_choice_target_selected)
	main.battle_screen.choice_option_toggled.connect(main._toggle_choice)
	main.battle_screen.choice_selection_confirmed.connect(main._confirm_choice)
	main.battle_screen.choice_cancel_requested.connect(main._cancel_choice)
	screen_host.add_child(main.battle_screen)
	main.battle_screen.initialize_ui()
	# Hot-seat hands are private from the first rendered frame. Opening shuffle
	# and the pass-device gate can both outlive the synchronous table mount.
	main.battle_screen.set_local_hand_privacy_hidden(main.game_mode == MODE_LOCAL)
	if main.audio_director:
		main.battle_screen.audio_requested.connect(main.audio_director.play_cue)
	if main.audio_director:
		main.audio_director.play_music("battle")
	main._refresh_game()

func show_end_screen() -> void:
	if main.state == null or not main.state.is_terminal():
		return
	if main.current_screen == SCREEN_END:
		return
	main.current_screen = SCREEN_END
	if main.modal_layer.visible:
		main.modal_host_controller.close()
	main.battle_screen = null
	var victory := mount(VICTORY_SCENE) as VictoryScreen
	var is_draw: bool = main.state.result_status == GameState.RESULT_DRAW
	var winner_player: PlayerState = (
		null if is_draw else main.state.get_player(main.state.winner))
	var winner_card_id := (
		winner_player.active.card_id
		if winner_player != null and winner_player.active
		else ""
	)
	var winner_deck_key: String = str(
		main.state.public_deck_keys[main.state.winner]
		if main.state.winner >= 0 and main.state.winner < main.state.public_deck_keys.size()
		else ""
	)
	var winner_deck: Dictionary = main.catalog.get_deck(winner_deck_key)
	var mode_label: String = str({
		MODE_LOCAL: "本地双人",
		MODE_CHALLENGE: "Challenge AI",
		MODE_NETWORK: "Relay 联机" if main.network_kind == "relay" else "LAN 联机",
	}.get(main.game_mode, "自定义对局"))
	victory.configure(
		main.state.winner,
		main.state.turn_number,
		winner_player.name if winner_player != null else "",
		winner_card_id,
		{
			"mode": main.game_mode,
			"mode_label": mode_label,
			"winner_deck": winner_deck_key,
			"winner_deck_name": winner_deck.get("name", winner_deck_key),
			"winner_card_name": main.catalog.card_name(winner_card_id),
			"result_status": main.state.result_status,
			"result_reason": main.state.result_reason,
			"result_conditions": main.state.result_conditions.duplicate(true),
		},
	)
	victory.rematch_requested.connect(func() -> void:
		main.state = null
		if main.game_mode == MODE_NETWORK:
			show_network_setup(main.network_kind)
		else:
			show_deck_select(main.game_mode)
	)
	victory.title_requested.connect(func() -> void:
		main.state = null
		show_title()
	)
	if main.audio_director:
		main.audio_director.play_music("victory")
	main._play_success()
