class_name AICoordinator
extends RefCounted

var _thread := Thread.new()
var _mutex := Mutex.new()
var _cancelled := false
var _completed := false
var _result: Dictionary = {}


func is_running() -> bool:
	_mutex.lock()
	var running := _thread.is_started() and not _completed
	_mutex.unlock()
	return running


func start_request(request: Dictionary, inference: Variant = null) -> bool:
	cancel_and_wait()
	_mutex.lock()
	_cancelled = false
	_completed = false
	_result = {}
	_mutex.unlock()
	_thread = Thread.new()
	return _thread.start(_thread_main.bind(request.duplicate(true), inference)) == OK


func poll_result() -> Dictionary:
	_mutex.lock()
	var ready := _completed
	var result := _result.duplicate(true)
	_mutex.unlock()
	if not ready:
		return {}
	if _thread.is_started():
		_thread.wait_to_finish()
	_mutex.lock()
	_completed = false
	_result = {}
	_mutex.unlock()
	return result


func cancel_and_wait() -> void:
	_mutex.lock()
	_cancelled = true
	_mutex.unlock()
	if _thread.is_started():
		_thread.wait_to_finish()
	_mutex.lock()
	_completed = false
	_result = {}
	_mutex.unlock()


func _thread_main(request: Dictionary, inference: Variant) -> void:
	var worker := NativeChallengeAI.new()
	var result := worker.decide(request, _is_cancelled, inference)
	_mutex.lock()
	_result = result
	_completed = true
	_mutex.unlock()


func _is_cancelled() -> bool:
	_mutex.lock()
	var value := _cancelled
	_mutex.unlock()
	return value
