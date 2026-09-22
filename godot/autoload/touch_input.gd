extends Node

## Native widgets and ScrollContainer consume emulated mouse events in Godot
## 4.7. Observe both event streams, including platforms that deliver the mouse
## event BEFORE its ScreenTouch. Never synthesize a second click or scroll.
var gesture := PointerGesture.new()
var using_touch := false
var _source: WeakRef
var _scroll: WeakRef
var _scrolling: Dictionary = {}
var _generation := 0
var _released := false
var _blocked := false
var _cancelling := false
var _suspended_sliders: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().node_added.connect(_node_added)
	get_tree().root.size_changed.connect(cancel_gesture)
	_install_tree(get_tree().root)
	set_process(false)


func _install_tree(node: Node) -> void:
	_node_added(node)
	for child in node.get_children():
		_install_tree(child)


func _node_added(node: Node) -> void:
	if node is Control:
		_install.call_deferred(node.get_instance_id())


func _install(id: int) -> void:
	var control := instance_from_id(id) as Control
	if control == null or not control.is_inside_tree():
		return
	var callback := _control_input.bind(control)
	if not control.gui_input.is_connected(callback):
		control.gui_input.connect(callback)
		control.resized.connect(cancel_for.bind(control))
		control.tree_exiting.connect(cancel_for.bind(control))
	# STOP also blocks the emulated mouse stream that native scrolling needs.
	# Only change descendants of a scroll surface; modal/table boundaries stay.
	if not control is ScrollBar and _ancestor_scroll(control) != null:
		if control.mouse_filter == Control.MOUSE_FILTER_STOP:
			control.mouse_filter = Control.MOUSE_FILTER_PASS
	if control is ScrollContainer:
		control.scroll_deadzone = int(PointerGesture.TAP_SLOP)
		if not control.scroll_started.is_connected(_scroll_started.bind(id)):
			control.scroll_started.connect(_scroll_started.bind(id))
			control.scroll_ended.connect(_scroll_ended.bind(id))
			control.tree_exiting.connect(_scroll_ended.bind(id))


func _ancestor_scroll(control: Control) -> ScrollContainer:
	var node := control.get_parent()
	while node != null:
		if node is ScrollContainer:
			return node as ScrollContainer
		node = node.get_parent()
	return null


func _scroll_owner(control: Control) -> ScrollContainer:
	var node: Node = control
	while node != null:
		if node is ScrollContainer:
			var scroll := node as ScrollContainer
			if (scroll.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED
				and scroll.get_v_scroll_bar().max_value > scroll.get_v_scroll_bar().page
			) or (scroll.horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED
				and scroll.get_h_scroll_bar().max_value > scroll.get_h_scroll_bar().page):
				return scroll
		node = node.get_parent()
	return null


func _input(event: InputEvent) -> void:
	if event is InputEventMouse and event.device >= 0:
		using_touch = false
	if event is InputEventScreenTouch and event.device != InputEvent.DEVICE_ID_EMULATION:
		if event.pressed:
			if gesture.active and not _released and gesture.pointer >= 0 and gesture.pointer != event.index:
				get_viewport().set_input_as_handled()
				return
			if not gesture.active or _released:
				_begin(event.position)
			gesture.pointer = event.index
		elif gesture.active and gesture.pointer == event.index:
			_update(event.position)
			_release(event.canceled)
		else:
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and event.device != InputEvent.DEVICE_ID_EMULATION:
		if not gesture.active or gesture.pointer != event.index:
			get_viewport().set_input_as_handled()
			return
		_update(event.position)
	elif event.device == InputEvent.DEVICE_ID_EMULATION:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if not gesture.active or _released:
					_begin(event.position)
			elif gesture.active:
				_update(event.position)
				_release(event.canceled)
		elif event is InputEventMouseMotion and gesture.active and not _released:
			_update(event.position)


func _begin(point: Vector2) -> void:
	using_touch = true
	set_process(true)
	_generation += 1
	gesture.begin(point)
	_source = null
	_scroll = null
	_released = false
	_blocked = false


func _update(point: Vector2) -> void:
	gesture.move(point)
	var source := _source_control()
	if source == null:
		return
	if not source.is_visible_in_tree():
		cancel_gesture()
		return
	if not gesture.can_tap() and not _is_hand(source):
		_cancel_press(source)
	if source is HSlider and not _blocked and gesture.direction == PointerGesture.Direction.HORIZONTAL:
		_set_slider_position(source as HSlider, point)


func _release(cancelled: bool) -> void:
	if cancelled:
		cancel_gesture()
	var source := _source_control()
	if source != null and not _released:
		var inside := PointerGesture.contains_viewport_point(source, gesture.position)
		if not gesture.can_tap() or not inside:
			_cancel_press(source)
		elif source is HSlider and not _released:
			_set_slider_position(source as HSlider, gesture.position)
	_released = true
	_finish.call_deferred(_generation)


func _finish(generation: int) -> void:
	if generation != _generation:
		return
	gesture.clear()
	_source = null
	_scroll = null
	set_process(false)


func _control_input(event: InputEvent, control: Control) -> void:
	if not gesture.active:
		return
	var emulated_mouse := event.device == InputEvent.DEVICE_ID_EMULATION and event is InputEventMouse
	var real_touch := event.device != InputEvent.DEVICE_ID_EMULATION and (event is InputEventScreenTouch or event is InputEventScreenDrag)
	if not emulated_mouse and not real_touch:
		return
	if _source == null and not _released:
		_source = weakref(control)
		var scroll := _scroll_owner(control)
		if scroll != null:
			_scroll = weakref(scroll)
			if _scrolling.has(scroll.get_instance_id()):
				# A tap on a moving list brakes it without activating the item.
				gesture.cancel()
				_stop_scroll(scroll)
	var source := _source_control()
	if real_touch and (gesture.cancelled or _blocked):
		_cancel_press(control)
		control.accept_event()
		return
	if control is BaseButton:
		# OptionButton normally opens on press. Touch must commit on release.
		if control.action_mode == BaseButton.ACTION_MODE_BUTTON_PRESS:
			control.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
			_restore_button_mode.call_deferred(control.get_instance_id())
		# 4.7 BaseButton accepts BOTH streams. Use its physical touch handling,
		# while still passing the synthetic mouse to the native scroll owner.
		if emulated_mouse and event is InputEventMouseButton and control.button_mask != 0:
			_restore_button_mask.call_deferred(control.get_instance_id(), control.button_mask)
			control.button_mask = 0
		if not gesture.can_tap():
			_cancel_press(control)
	if not emulated_mouse:
		return
	if control is HSlider and control == source:
		# Let vertical movement bubble to ScrollContainer without allowing the
		# native slider to change value at initial contact. Restore before draw.
		if control.editable:
			_suspended_sliders[control.get_instance_id()] = true
			control.editable = false
			_restore_slider.call_deferred(control.get_instance_id())
		if gesture.direction == PointerGesture.Direction.HORIZONTAL:
			control.accept_event()
	if control is ScrollContainer:
		var owner := _scroll.get_ref() as ScrollContainer if _scroll != null else null
		if owner != null and owner != control and control.is_ancestor_of(owner):
			control.accept_event()
	if event is InputEventMouseMotion and source != null and _is_hand(source):
		if gesture.direction != PointerGesture.Direction.HORIZONTAL:
			control.accept_event()
	if _blocked:
		_cancel_press(control)
		control.accept_event()


func _restore_button_mode(id: int) -> void:
	var button := instance_from_id(id) as BaseButton
	if button != null:
		button.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS


func _restore_button_mask(id: int, mask: int) -> void:
	var button := instance_from_id(id) as BaseButton
	if button != null:
		button.button_mask = mask


func _restore_slider(id: int) -> void:
	_suspended_sliders.erase(id)
	var slider := instance_from_id(id) as HSlider
	if slider != null:
		slider.editable = true


func _set_slider_position(slider: HSlider, point: Vector2) -> void:
	if not slider.editable and not _suspended_sliders.has(slider.get_instance_id()):
		return
	var local := slider.get_global_transform_with_canvas().affine_inverse() * point
	var grabber := slider.get_theme_icon("grabber")
	var width := float(grabber.get_width()) if grabber != null else 0.0
	var ratio := clampf((local.x - width * 0.5) / maxf(1.0, slider.size.x - width), 0.0, 1.0)
	if slider.is_layout_rtl():
		ratio = 1.0 - ratio
	slider.ratio = ratio


func _is_hand(control: Control) -> bool:
	return control is CardView and control.hand_index >= 0


func _source_control() -> Control:
	return _source.get_ref() as Control if _source != null else null


func tap_allowed(control: Control) -> bool:
	if not gesture.active:
		return true
	var source := _source_control()
	return not _blocked and gesture.can_tap() and (source == control or (source != null and control.is_ancestor_of(source)))


func hand_drag_allowed(control: Control) -> bool:
	return not gesture.active or (not _blocked and _source_control() == control and gesture.can_drag_hand())


func cancel_gesture() -> void:
	if not gesture.active or _cancelling:
		return
	_cancelling = true
	gesture.cancel()
	_blocked = true
	set_process(false)
	var source := _source_control()
	if source != null:
		_cancel_press(source)
	var scroll := _scroll.get_ref() as ScrollContainer if _scroll != null else null
	if scroll != null:
		_stop_scroll(scroll)
	if get_viewport().gui_is_dragging():
		get_viewport().gui_cancel_drag()
	_cancelling = false


func cancel_for(control: Control) -> void:
	var source := _source_control()
	if source == control or (source != null and control.is_ancestor_of(source)):
		cancel_gesture()


func _cancel_press(control: Control) -> void:
	var tap := control.get_meta("pointer_tap") as PointerTap if control.has_meta("pointer_tap") else null
	if tap != null:
		tap.gesture.cancel()
	if control is BaseButton:
		control.notification(Control.NOTIFICATION_SCROLL_BEGIN)
	elif control.has_method("cancel_pointer_gesture"):
		control.call("cancel_pointer_gesture")


func _stop_scroll(scroll: ScrollContainer) -> void:
	scroll.scroll_vertical = scroll.scroll_vertical
	scroll.scroll_horizontal = scroll.scroll_horizontal


func _scroll_started(id: int) -> void:
	_scrolling[id] = true


func _scroll_ended(id: int) -> void:
	_scrolling.erase(id)


func _process(_delta: float) -> void:
	if gesture.active and _source != null:
		var source := _source_control()
		if source == null or source.is_queued_for_deletion() or not source.is_visible_in_tree():
			cancel_gesture()


func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED]:
		cancel_gesture()
		# Platforms can lose the release while backgrounded. Keep the old
		# gesture cancelled, but let the next physical press start a new one.
		_released = true
