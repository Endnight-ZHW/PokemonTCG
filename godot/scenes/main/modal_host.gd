class_name ModalHost
extends Control

const FRONTEND_THEME := preload("res://ui/frontend/front_end_theme.tres")
const SCREEN_GAME := "game"
const MODE_CHALLENGE := "challenge"
const MODAL_SHADE_ALPHA := 0.72
const MODAL_SHADE_OPAQUE_ALPHA := 1.0

@onready var modal_layer: Control = self
@onready var modal_panel: PanelContainer = %ModalPanel
@onready var modal_shade: ColorRect = %ModalShade
@onready var modal_title: Label = %ModalTitle
@onready var modal_scroll: ScrollContainer = $Center/ModalPanel/Margin/Content/Scroll
@onready var modal_body: VBoxContainer = %ModalBody
@onready var modal_confirm: Button = %ModalConfirm
@onready var modal_cancel: Button = %ModalCancel
@onready var shell_animations: AnimationPlayer = %ShellAnimations
var active_spec: ModalSpec
var main: Variant
var generation := 0
var back_action := Callable()
var closing := false
var _close_completion := Callable()
var _close_completion_generation := -1


func configure(owner: Control) -> void:
	main = owner
	modal_layer = self
	modal_panel = get_node_or_null("Center/ModalPanel") as PanelContainer
	modal_shade = get_node_or_null("ModalShade") as ColorRect
	modal_title = get_node_or_null(
		"Center/ModalPanel/Margin/Content/ModalTitle"
	) as Label
	modal_scroll = get_node_or_null(
		"Center/ModalPanel/Margin/Content/Scroll"
	) as ScrollContainer
	modal_body = get_node_or_null(
		"Center/ModalPanel/Margin/Content/Scroll/ModalBody"
	) as VBoxContainer
	modal_confirm = get_node_or_null(
		"Center/ModalPanel/Margin/Content/Buttons/ModalConfirm"
	) as Button
	modal_cancel = get_node_or_null(
		"Center/ModalPanel/Margin/Content/Buttons/ModalCancel"
	) as Button
	shell_animations = owner.get_node_or_null("ShellAnimations") as AnimationPlayer


func open(
	title_text: String,
	confirm_text: String,
	cancel_text: String,
	opaque_shade: bool = false,
	spec: ModalSpec = null,
) -> void:
	if main.battle_screen:
		main.battle_screen.close_log_drawer()
	main._clear_battle_selection("", false)
	# Opening a modal is a hard interaction boundary, including for any stale
	# table-side selection that Main has already forgotten.
	if main.current_screen == SCREEN_GAME and main.state:
		main._refresh_game()
	modal_scroll.custom_minimum_size.y = 0.0
	var viewport := get_viewport()
	var text_owner := viewport.gui_get_focus_owner() if viewport else null
	if text_owner is LineEdit:
		(text_owner as LineEdit).release_focus()
	back_action = Callable()
	var resolved_spec := spec
	if resolved_spec == null:
		resolved_spec = (
			ModalSpec.battle(Vector2(720, 620), opaque_shade)
			if main.current_screen == SCREEN_GAME
			else ModalSpec.frontend(Vector2(820, 680))
		)
	resolved_spec.opaque_shade = opaque_shade or resolved_spec.opaque_shade
	generation += 1
	closing = false
	_close_completion = Callable()
	_close_completion_generation = -1
	_disconnect_button(modal_confirm)
	_disconnect_button(modal_cancel)
	clear_body()
	begin(resolved_spec, main.shell_view.safe_content_size())
	modal_title.text = title_text
	var frontend_modal := resolved_spec.surface == ModalSpec.Surface.FRONTEND
	modal_title.theme_type_variation = &"FrontModalTitle" if frontend_modal else &""
	modal_confirm.text = confirm_text
	modal_confirm.disabled = false
	modal_confirm.theme_type_variation = _button_variation(
		resolved_spec.surface,
		resolved_spec.confirm_role,
	)
	modal_cancel.text = cancel_text
	modal_cancel.disabled = false
	modal_cancel.visible = resolved_spec.cancellable and not cancel_text.is_empty()
	modal_cancel.theme_type_variation = _button_variation(
		resolved_spec.surface,
		resolved_spec.cancel_role,
	)
	modal_shade.color.a = (
		MODAL_SHADE_OPAQUE_ALPHA
		if resolved_spec.opaque_shade
		else clampf(resolved_spec.shade_alpha, 0.0, 1.0)
	)
	modal_layer.visible = true
	modal_layer.move_to_front()
	if not FrontendMotion.decorative_motion_enabled():
		shell_animations.stop()
		shell_animations.speed_scale = 1.0
		modal_panel.modulate.a = 1.0
		modal_panel.scale = Vector2.ONE
		return
	var open_duration := FrontendMotion.duration(0.16)
	shell_animations.speed_scale = 0.16 / maxf(open_duration, 0.001)
	shell_animations.play("modal_open")


func close(completion: Callable = Callable()) -> void:
	# Treat close as a transaction so repeated back/button signals cannot replace
	# the completion that submits or cancels an authoritative choice.
	if closing:
		return
	closing = true
	generation += 1
	var close_generation := generation
	_close_completion = completion
	_close_completion_generation = close_generation
	main.active_request = null
	main.active_choice_panel = null
	main.selected_choice_ids.clear()
	main.option_buttons.clear()
	back_action = Callable()
	modal_confirm.disabled = true
	modal_cancel.disabled = true
	if not modal_layer.visible:
		finish_close(close_generation)
		return
	if not is_inside_tree() or not FrontendMotion.decorative_motion_enabled():
		finish_close(close_generation)
		return
	var close_animation := shell_animations.get_animation("modal_close")
	if close_animation == null:
		finish_close(close_generation)
		return
	var close_duration := FrontendMotion.duration(close_animation.length)
	shell_animations.speed_scale = close_animation.length / maxf(close_duration, 0.001)
	shell_animations.play("modal_close")
	_finish_close_after_delay(close_generation, close_duration)


func _finish_close_after_delay(close_generation: int, delay: float) -> void:
	await get_tree().create_timer(delay, true, false, true).timeout
	finish_close(close_generation)


func finish_close(close_generation: int) -> void:
	if close_generation != generation or not closing:
		return
	closing = false
	modal_layer.visible = false
	_free_children_immediate(modal_body)
	modal_shade.color.a = MODAL_SHADE_ALPHA
	modal_panel.modulate = Color.WHITE
	modal_panel.scale = Vector2.ONE
	shell_animations.stop()
	shell_animations.speed_scale = 1.0
	reset_surface()
	finish()
	var completion := Callable()
	if _close_completion_generation == close_generation:
		completion = _close_completion
	_close_completion = Callable()
	_close_completion_generation = -1
	if completion.is_valid():
		completion.call()


func handle_back() -> bool:
	if not visible:
		return false
	if closing:
		return true
	if main.active_request:
		if main.active_request.can_cancel:
			main._cancel_choice()
		return true
	if active_spec and not active_spec.cancellable:
		return true
	if back_action.is_valid():
		var return_action := back_action
		back_action = Callable()
		return_action.call()
	elif main.current_screen == SCREEN_GAME:
		close(
			Callable(main, "_resume_after_pause")
			if main.game_mode == MODE_CHALLENGE
			else Callable()
		)
	else:
		close()
	return true


func _button_variation(surface: int, role: int) -> StringName:
	if role == ModalSpec.ButtonRole.DEFAULT:
		return &""
	if surface == ModalSpec.Surface.FRONTEND:
		return {
			ModalSpec.ButtonRole.PRIMARY: &"FrontPrimaryButton",
			ModalSpec.ButtonRole.SECONDARY: &"FrontSecondaryButton",
			ModalSpec.ButtonRole.DANGER: &"FrontDangerButton",
		}.get(role, &"")
	return {
		ModalSpec.ButtonRole.PRIMARY: &"BattlePrimaryButton",
		ModalSpec.ButtonRole.SECONDARY: &"BattleSecondaryButton",
		ModalSpec.ButtonRole.DANGER: &"BattleDangerButton",
	}.get(role, &"")


func _disconnect_button(button: Button) -> void:
	for connection in button.pressed.get_connections():
		button.pressed.disconnect(connection["callable"])


func _free_children_immediate(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.free()


func begin(spec: ModalSpec, available_size: Vector2) -> void:
	active_spec = spec
	if modal_panel:
		modal_panel.theme = FRONTEND_THEME if spec.surface == ModalSpec.Surface.FRONTEND else null
		_apply_layout(spec, available_size)
	if modal_scroll:
		DesignTokens.style_scrollbar(modal_scroll.get_v_scroll_bar())
		DesignTokens.style_scrollbar(modal_scroll.get_h_scroll_bar())


func update_available_size(available_size: Vector2) -> void:
	if active_spec and modal_panel:
		_apply_layout(active_spec, available_size)


func clear_body() -> void:
	if modal_body == null:
		return
	for child in modal_body.get_children():
		modal_body.remove_child(child)
		child.queue_free()


func finish() -> void:
	active_spec = null


func reset_surface() -> void:
	if modal_panel:
		modal_panel.theme = null


func _apply_layout(spec: ModalSpec, available_size: Vector2) -> void:
	var panel_size := _resolved_size(spec, available_size)
	# Reset the previous viewport's scroll floor before changing the panel. A
	# stale 420 px floor can otherwise become the panel's effective minimum and
	# push a resized modal outside the current safe center.
	if modal_scroll:
		modal_scroll.custom_minimum_size.y = 0.0
	modal_panel.custom_minimum_size = panel_size
	if modal_scroll:
		modal_scroll.custom_minimum_size.y = _resolved_scroll_minimum(spec, panel_size)


func _resolved_scroll_minimum(spec: ModalSpec, panel_size: Vector2) -> float:
	if spec.size_mode == ModalSpec.SizeMode.FIT_CONTENT:
		return 0.0
	return minf(420.0, maxf(0.0, panel_size.y - _fixed_vertical_extent()))


func _fixed_vertical_extent() -> float:
	if modal_panel == null:
		return 200.0
	var fixed := 0.0
	var panel_style := modal_panel.get_theme_stylebox(&"panel")
	if panel_style:
		fixed += panel_style.get_minimum_size().y
	var margin := modal_panel.get_node_or_null("Margin") as MarginContainer
	if margin:
		fixed += margin.get_theme_constant(&"margin_top")
		fixed += margin.get_theme_constant(&"margin_bottom")
	var content := modal_panel.get_node_or_null("Margin/Content") as VBoxContainer
	if content:
		var visible_fixed_children := 0
		for child in content.get_children():
			if child is Control and (child as Control).visible:
				visible_fixed_children += 1
				if child != modal_scroll:
					fixed += (child as Control).get_combined_minimum_size().y
		fixed += maxf(0.0, float(visible_fixed_children - 1)) * content.get_theme_constant(
			&"separation"
		)
	return fixed


func _resolved_size(spec: ModalSpec, available: Vector2) -> Vector2:
	var compact := available.x / maxf(available.y, 1.0) < 1.5 or available.x < 1360.0
	var inset := Vector2(24, 24) if compact else Vector2(96, 72)
	var cap := Vector2(
		maxf(1.0, available.x - inset.x),
		maxf(1.0, available.y - inset.y),
	)
	if spec.size_mode == ModalSpec.SizeMode.FILL_SAFE:
		return cap
	var preferred := spec.preferred_size
	if spec.size_mode == ModalSpec.SizeMode.FIT_CONTENT:
		return Vector2(
			clampf(preferred.x, minf(320.0, cap.x), cap.x),
			clampf(preferred.y, 1.0, cap.y),
		)
	var minimum := Vector2(
		minf(560.0, cap.x),
		minf(480.0, cap.y),
	)
	return Vector2(
		clampf(preferred.x, minimum.x, cap.x),
		clampf(preferred.y, minimum.y, cap.y),
	)


func choice_size(has_preview: bool, compact_empty: bool = false) -> Vector2:
	# ModalHost resolves this preferred size against the safe content area, not
	# the raw sub-viewport. Headless and embedded viewports can report a tiny
	# placeholder rect even while the safe root layout has its final size.
	var viewport_size: Vector2 = (
		main.shell_view.safe_content_size() if is_inside_tree() else Vector2.ZERO
	)
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		var tree := Engine.get_main_loop() as SceneTree
		if tree and tree.root:
			viewport_size = Vector2(tree.root.size)
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		viewport_size = Vector2(1280, 720)
	var target := (
		Vector2(640, 360)
		if compact_empty
		else Vector2(980, 660) if has_preview else Vector2(720, 620)
	)
	var compact: bool = (
		viewport_size.x / maxf(viewport_size.y, 1.0) < 1.5
		or viewport_size.x < 1360.0
	)
	var inset := Vector2(24, 24) if compact else Vector2(96, 72)
	var available := Vector2(
		maxf(1.0, viewport_size.x - inset.x),
		maxf(1.0, viewport_size.y - inset.y),
	)
	return Vector2(
		minf(target.x, available.x),
		minf(target.y, available.y),
	)
