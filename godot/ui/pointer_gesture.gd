class_name PointerGesture
extends RefCounted

## Positions are in viewport coordinates, never in a moving card's local space.
const TAP_SLOP := 12.0
const HAND_DRAG_DISTANCE := 24.0
const AXIS_RATIO := 1.5
enum Direction { PENDING, HORIZONTAL, UP, DOWN }

var active := false
var pointer := -1
var origin := Vector2.ZERO
var position := Vector2.ZERO
var maximum_distance := 0.0
var direction := Direction.PENDING
var cancelled := false


func begin(point: Vector2, index: int = -1) -> void:
	active = true
	pointer = index
	origin = point
	position = point
	maximum_distance = 0.0
	direction = Direction.PENDING
	cancelled = false


func move(point: Vector2) -> void:
	position = point
	var displacement := point - origin
	maximum_distance = maxf(maximum_distance, displacement.length())
	if direction != Direction.PENDING or maximum_distance < TAP_SLOP:
		return
	if absf(displacement.x) >= absf(displacement.y) * AXIS_RATIO:
		direction = Direction.HORIZONTAL
	elif absf(displacement.y) >= absf(displacement.x) * AXIS_RATIO:
		direction = Direction.UP if displacement.y < 0.0 else Direction.DOWN


func can_tap() -> bool:
	return active and not cancelled and maximum_distance < TAP_SLOP


func can_drag_hand() -> bool:
	return active and not cancelled and direction == Direction.UP and origin.y - position.y >= HAND_DRAG_DISTANCE


func cancel() -> void:
	cancelled = true


func clear() -> void:
	active = false
	pointer = -1


static func viewport_point(control: Control, point: Vector2) -> Vector2:
	return control.get_global_transform_with_canvas() * point


static func contains_viewport_point(control: Control, point: Vector2) -> bool:
	var local := control.get_global_transform_with_canvas().affine_inverse() * point
	# Card and pile input follows their projected 3D faces, which can extend
	# beyond the invisible layout anchor. Match the same hit shape on release.
	if control.has_method("_has_point"):
		return bool(control.call("_has_point", local))
	return Rect2(Vector2.ZERO, control.size).has_point(local)


static func touch_router() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("TouchInput") if tree != null else null


static func tap_allowed(control: Control) -> bool:
	var router := touch_router()
	return router == null or bool(router.call("tap_allowed", control))


static func is_touch_input() -> bool:
	var router := touch_router()
	return router != null and bool(router.get("using_touch"))


static func hand_drag_allowed(control: Control) -> bool:
	var router := touch_router()
	return router == null or bool(router.call("hand_drag_allowed", control))


static func cancel_for(control: Control) -> void:
	var router := touch_router()
	if router != null:
		router.call("cancel_for", control)


static func cancel_all() -> void:
	var router := touch_router()
	if router != null:
		router.call("cancel_gesture")


static func is_cancelled_touch_mouse(event: InputEvent) -> bool:
	if event.device != InputEvent.DEVICE_ID_EMULATION or not event is InputEventMouse:
		return false
	var router := touch_router()
	if router == null:
		return false
	var current := router.get("gesture") as PointerGesture
	return current.active and not current.can_tap()
