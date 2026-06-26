class_name AIMatchDriver
extends Node

var coordinator := AICoordinator.new()
var deep_runtime := DeepAIRuntime.new()


func cancel_and_wait() -> void:
	coordinator.cancel_and_wait()
	deep_runtime.unload()


func poll_result() -> Dictionary:
	return coordinator.poll_result()
