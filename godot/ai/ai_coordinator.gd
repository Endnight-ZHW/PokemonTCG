class_name AICoordinator
extends RefCounted

const INVALID_TASK_ID := -1

var last_start_error := ""

var _mutex := Mutex.new()
var _task_id := INVALID_TASK_ID
var _next_generation := 0
var _active_generation := 0
var _task_generation := 0
var _task_completed := false
var _task_result: Dictionary = {}
var _cancel_requested := false
var _request_id := ""
var _revision := -1
## Keep one worker for the lifetime of the coordinator.  Challenge decisions
## are serialized by this class, so the worker can safely retain a validated
## turn plan and immutable catalog caches between atomic actions.
var _worker := NativeChallengeAI.new()
var _deep_worker := DeepRootISMCTS.new()


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


## A pooled task can outlive its logical request after explicit cancellation.
## Main keeps polling until the global pool reports it complete.
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
	_task_result = {}
	_cancel_requested = false
	_request_id = str(request.get("request_id", ""))
	_revision = int(request.get("revision", -1))
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


## The authoritative evaluation runner is synchronous, but must exercise the
## exact same Deep/fallback branch as the asynchronous gameplay boundary.
## Keeping this thin adapter here prevents candidate evidence from silently
## bypassing the production infoset_puct_v2 path.
func decide_sync_for_evaluation(
	request: Dictionary,
	inference: Variant = null,
) -> Dictionary:
	return _decide(request, Callable(), inference)


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
	_task_completed = true
	_mutex.unlock()


func _decide(
	request: Dictionary,
	cancel_check: Callable,
	inference: Variant,
) -> Dictionary:
	if str(request.get("mode", "challenge")) == "deep" and inference == null:
		var unavailable_fallback := _worker.decide(
			request, cancel_check, null)
		unavailable_fallback["deep_fallback"] = true
		unavailable_fallback["fallback_reason"] = "runtime_unavailable"
		unavailable_fallback["deep_failure"] = {
			"planner": DeepRootISMCTS.PLANNER_ID,
			"reason": "runtime_unavailable",
			"elapsed_ms": 0.0,
		}
		return unavailable_fallback
	if str(request.get("mode", "challenge")) == "deep":
		var deep_result := _deep_worker.decide(
			request, cancel_check, inference)
		if bool(deep_result.get("success", false)) or bool(
			deep_result.get("cancelled", false)):
			return deep_result
		var reason := str(deep_result.get(
			"deep_failure_reason",
			deep_result.get("error", "deep_unknown_failure"),
		))
		var fallback := _worker.decide(request, cancel_check, null)
		fallback["deep_fallback"] = true
		fallback["fallback_reason"] = reason
		fallback["deep_failure"] = {
			"planner": DeepRootISMCTS.PLANNER_ID,
			"reason": reason,
			"elapsed_ms": float(deep_result.get("elapsed_ms", 0.0)),
		}
		return fallback
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
		_task_result = {}
		_cancel_requested = false
		_request_id = ""
		_revision = -1
		_active_generation = 0
	_mutex.unlock()
