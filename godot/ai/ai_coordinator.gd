class_name AICoordinator
extends RefCounted

const DEFAULT_TIMEOUT_MSEC := 1100
const HARD_TIMEOUT_MSEC := 1100
const DEADLINE_GRACE_MSEC := 250
const MIN_TIMEOUT_MSEC := 50
const INVALID_TASK_ID := -1

var last_start_error := ""

var _mutex := Mutex.new()
var _task_id := INVALID_TASK_ID
var _next_generation := 0
var _active_generation := 0
var _task_generation := 0
var _task_completed := false
var _task_completed_msec := 0
var _task_result: Dictionary = {}
var _cancel_requested := false
var _deadline_msec := 0
var _deadline_reported := false
var _request_id := ""
var _revision := -1
## Keep one worker for the lifetime of the coordinator.  Challenge decisions
## are serialized by this class, so the worker can safely retain a validated
## turn plan and immutable catalog caches between atomic actions.
var _worker := NativeChallengeAI.new()


func is_running() -> bool:
	_mutex.lock()
	var running := (
		_active_generation > 0
		and _task_id != INVALID_TASK_ID
		and not _task_completed
		and not _cancel_requested
	)
	_mutex.unlock()
	return running


## A pooled task can outlive its logical request after cancellation or a
## deadline. Main keeps polling until the global pool reports it complete.
func needs_poll() -> bool:
	_mutex.lock()
	var pending := _task_id != INVALID_TASK_ID
	_mutex.unlock()
	return pending


func start_request(request: Dictionary, inference: Variant = null) -> bool:
	# Reaping is non-blocking: _reap_finished_task only waits after the global
	# pool has reported completion. A still-running worker is never waited on.
	_reap_finished_task()
	_mutex.lock()
	if _task_id != INVALID_TASK_ID:
		_cancel_requested = true
		_active_generation = 0
		last_start_error = "previous_request_running"
		_mutex.unlock()
		return false
	_next_generation += 1
	_active_generation = _next_generation
	_task_generation = _active_generation
	_task_completed = false
	_task_completed_msec = 0
	_task_result = {}
	_cancel_requested = false
	_deadline_reported = false
	_request_id = str(request.get("request_id", ""))
	_revision = int(request.get("revision", -1))
	_deadline_msec = Time.get_ticks_msec() + _request_timeout_msec(request)
	last_start_error = ""
	var generation := _active_generation
	_mutex.unlock()

	var task_id := WorkerThreadPool.add_task(
		_worker_main.bind(request.duplicate(true), inference, generation),
		false,
		"Pokemon TCG AI decision",
	)
	if task_id >= 0:
		_mutex.lock()
		_task_id = task_id
		_mutex.unlock()
		return true
	_mutex.lock()
	if _active_generation == generation:
		_active_generation = 0
	_task_generation = 0
	_task_completed = false
	last_start_error = "worker_task_start_failed:%d" % task_id
	_mutex.unlock()
	return false


func poll_result() -> Dictionary:
	var deadline_result: Dictionary = {}
	_mutex.lock()
	if (
		_active_generation > 0
		and _task_id != INVALID_TASK_ID
		and not _deadline_reported
		and Time.get_ticks_msec() >= _deadline_msec
		and (not _task_completed or _task_completed_msec > _deadline_msec)
	):
		_deadline_reported = true
		_cancel_requested = true
		_active_generation = 0
		deadline_result = {
			"success": false,
			"cancelled": false,
			"error": "deadline_exceeded",
			"request_id": _request_id,
			"revision": _revision,
		}
	_mutex.unlock()
	if not deadline_result.is_empty():
		return deadline_result

	var task_id := INVALID_TASK_ID
	var generation := 0
	_mutex.lock()
	task_id = _task_id
	generation = _task_generation
	_mutex.unlock()
	if task_id == INVALID_TASK_ID or not WorkerThreadPool.is_task_completed(task_id):
		return {}

	var accepted := false
	var result: Dictionary = {}
	_mutex.lock()
	var completed_marker := _task_completed
	accepted = (
		_active_generation > 0
		and generation == _active_generation
		and not _cancel_requested
		and not _deadline_reported
	)
	if accepted:
		if completed_marker:
			result = _task_result.duplicate(true)
		else:
			result = {
				"success": false,
				"error": "worker_terminated_without_result",
				"request_id": _request_id,
				"revision": _revision,
			}
	_mutex.unlock()

	# Completion has already been observed, so this cannot turn polling,
	# cancellation, or request startup into a wait on a live worker.
	_reap_finished_task()
	return result if accepted else {}


func cancel_request() -> void:
	_mutex.lock()
	_cancel_requested = true
	_active_generation = 0
	_mutex.unlock()
	_reap_finished_task()


## Compatibility shim. It intentionally no longer waits for a live worker.
func cancel_and_wait() -> void:
	cancel_request()


func _worker_main(
	request: Dictionary,
	inference: Variant,
	generation: int,
) -> void:
	var result := _decide(
		request,
		_is_cancelled.bind(generation),
		inference,
	)
	_mutex.lock()
	_task_result = result if result is Dictionary else {
		"success": false,
		"error": "invalid_worker_result",
		"request_id": str(request.get("request_id", "")),
		"revision": int(request.get("revision", -1)),
	}
	_task_completed_msec = Time.get_ticks_msec()
	_task_completed = true
	_mutex.unlock()


func _decide(
	request: Dictionary,
	cancel_check: Callable,
	inference: Variant,
) -> Dictionary:
	return _worker.decide(request, cancel_check, inference)


func _is_cancelled(generation: int) -> bool:
	_mutex.lock()
	var value := (
		_cancel_requested
		or _active_generation <= 0
		or generation != _active_generation
	)
	_mutex.unlock()
	return value


func _request_timeout_msec(request: Dictionary) -> int:
	if request.has("coordinator_timeout_msec"):
		return mini(
			HARD_TIMEOUT_MSEC,
			maxi(MIN_TIMEOUT_MSEC, int(request["coordinator_timeout_msec"])),
		)
	if request.has("seconds"):
		return mini(
			HARD_TIMEOUT_MSEC,
			maxi(
				MIN_TIMEOUT_MSEC,
				ceili(float(request["seconds"]) * 1000.0) + DEADLINE_GRACE_MSEC,
			),
		)
	return DEFAULT_TIMEOUT_MSEC


func _reap_finished_task() -> void:
	_mutex.lock()
	var task_id := _task_id
	_mutex.unlock()
	if (
		task_id == INVALID_TASK_ID
		or not WorkerThreadPool.is_task_completed(task_id)
	):
		return
	WorkerThreadPool.wait_for_task_completion(task_id)
	_mutex.lock()
	# Do not clear a newer task if a future caller re-enters around the pool
	# completion check.
	if _task_id == task_id:
		_task_id = INVALID_TASK_ID
		_task_generation = 0
		_task_completed = false
		_task_completed_msec = 0
		_task_result = {}
		_cancel_requested = false
		_deadline_msec = 0
		_deadline_reported = false
		_request_id = ""
		_revision = -1
		_active_generation = 0
	_mutex.unlock()
