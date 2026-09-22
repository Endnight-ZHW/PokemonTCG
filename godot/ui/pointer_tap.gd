class_name PointerTap
extends RefCounted

## Small adapter for custom clickable tiles. Synthetic mouse events are reserved
## for the native ScrollContainer and must not also activate their contents.
var gesture := PointerGesture.new()
var _touch := false


func handle(control: Control, event: InputEvent) -> bool:
	if event.device == InputEvent.DEVICE_ID_EMULATION:
		return false
	var point := Vector2.ZERO
	var pressed := false
	var released := false
	var cancelled := false
	if event is InputEventScreenTouch:
		point = PointerGesture.viewport_point(control, event.position)
		if event.pressed:
			# TouchInput rejects extra fingers before GUI dispatch. A fresh
			# accepted press replaces a gesture whose release was lost on pause.
			_touch = true
			gesture.begin(point, event.index)
			return false
		if not _touch or event.index != gesture.pointer:
			return false
		released = true
		cancelled = event.canceled
	elif event is InputEventScreenDrag:
		if _touch and event.index == gesture.pointer:
			gesture.move(PointerGesture.viewport_point(control, event.position))
		return false
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if _touch and gesture.active and not event.pressed:
			return false
		point = PointerGesture.viewport_point(control, event.position)
		pressed = event.pressed
		released = not pressed
		cancelled = event.canceled
	elif event is InputEventMouseMotion:
		if gesture.active and not _touch:
			gesture.move(PointerGesture.viewport_point(control, event.position))
		return false
	else:
		return false
	if pressed:
		_touch = false
		gesture.begin(point)
		return false
	if not released or not gesture.active:
		return false
	gesture.move(point)
	var allowed := gesture.can_tap() and not cancelled and PointerGesture.contains_viewport_point(control, point)
	if _touch:
		allowed = allowed and PointerGesture.tap_allowed(control)
	gesture.clear()
	return allowed
