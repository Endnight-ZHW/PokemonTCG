class_name NetworkSessionDriver
extends Node

var controller := NetworkMatchController.new()


func poll() -> Array:
	return controller.poll()


func close() -> void:
	controller.close()
