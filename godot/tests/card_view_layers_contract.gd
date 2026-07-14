extends SceneTree

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := load("res://ui/card_view.tscn") as PackedScene
	_check(scene != null, "CardView scene did not load")
	if scene == null:
		_finish()
		return
	var card := scene.instantiate() as CardView
	root.add_child(card)
	card.size = Vector2(104.0, 146.0)
	card.position = Vector2(120.0, 180.0)
	card.interaction_duration = 0.02
	card.configure("layer-contract-card", null, false, 0, 0)
	await process_frame

	_check(
		card.interaction_root != null
		and card.feedback_root != null
		and card.content_root != null
		and card.feedback_root.get_parent() == card.interaction_root
		and card.content_root.get_parent() == card.feedback_root
		and card.frame.get_parent() == card.content_root,
		"CardView visual roots are not layered as interaction/feedback/content",
	)
	_check(
		card.get_node_or_null("SelectionRing") == card.selection_ring,
		"CardView did not preserve the legacy SelectionRing path",
	)

	var layout_position := card.position
	card.remember_base_position()
	card.set_selected(true)
	await create_timer(0.04).timeout
	await process_frame
	_check(
		card.position == layout_position
		and card.interaction_root.position.y < -11.0
		and card.interaction_root.scale.x > 1.05
		and card.feedback_root.position == Vector2.ZERO,
		"Selection lift layer mismatch layout=%s actual=%s interaction=%s scale=%s feedback=%s" % [
			layout_position,
			card.position,
			card.interaction_root.position,
			card.interaction_root.scale,
			card.feedback_root.position,
		],
	)
	var selected_animation_position := card.animation_player.current_animation_position
	var selected_lift_tween := card._lift_tween
	card.set_selected(true)
	await process_frame
	_check(
		card._lift_tween == selected_lift_tween
		and card.animation_player.current_animation_position >= selected_animation_position,
		"Idempotent set_selected restarted an active visual animation",
	)

	card.shake(8.0, 0.10)
	await create_timer(0.03).timeout
	await process_frame
	_check(
		card.position == layout_position
		and card.interaction_root.position.y < -11.0
		and not card.feedback_root.position.is_zero_approx(),
		"Shake layer mismatch layout=%s actual=%s interaction=%s feedback=%s" % [
			layout_position,
			card.position,
			card.interaction_root.position,
			card.feedback_root.position,
		],
	)
	await create_timer(0.12).timeout
	_check(
		card.position == layout_position
		and card.feedback_root.position.is_zero_approx(),
		"Shake did not restore FeedbackRoot without moving the layout root",
	)

	card.set_selected(false)
	card.set_targetable(true)
	await create_timer(0.05).timeout
	var target_animation_position := card.animation_player.current_animation_position
	card.set_targetable(true)
	await process_frame
	_check(
		card.animation_player.current_animation_position >= target_animation_position,
		"Idempotent set_targetable restarted the target animation",
	)

	card.set_presentation_hidden(true)
	_check(
		card.is_presentation_hidden()
		and is_zero_approx(card.content_root.modulate.a)
		and is_equal_approx(card.modulate.a, 1.0),
		"Presentation masking escaped ContentRoot",
	)
	card.set_drag_masked(true)
	card.set_presentation_hidden(false)
	_check(
		card.is_drag_masked()
		and not card.content_root.visible
		and is_equal_approx(card.content_root.modulate.a, 1.0),
		"Drag masking was not independent from presentation alpha",
	)
	card.set_drag_masked(false)
	_check(
		not card.is_drag_masked() and card.content_root.visible,
		"Clearing the drag mask did not restore card content",
	)
	card._set_native_drag_masked(true)
	card.set_drag_masked(true)
	card.set_drag_masked(false)
	_check(
		card.is_drag_hidden() and not card.content_root.visible,
		"Coordinator mask clearing incorrectly released the native drag mask",
	)
	card._set_native_drag_masked(false)
	_check(
		not card.is_drag_hidden() and card.content_root.visible,
		"CardView did not restore content after every drag-mask owner released it",
	)

	card.queue_free()
	await process_frame
	_finish()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("CARD_VIEW_LAYERS_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
