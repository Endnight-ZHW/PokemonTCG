class_name ModalHost
extends Node

var modal_layer: Control
var modal_body: VBoxContainer
var modal_confirm: Button
var modal_cancel: Button


func configure(
	layer: Control,
	body: VBoxContainer,
	confirm_button: Button,
	cancel_button: Button,
) -> void:
	modal_layer = layer
	modal_body = body
	modal_confirm = confirm_button
	modal_cancel = cancel_button


func clear_body() -> void:
	if modal_body == null:
		return
	for child in modal_body.get_children():
		modal_body.remove_child(child)
		child.queue_free()
