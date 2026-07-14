class_name PresentationHandle
extends RefCounted

signal completed(handle: PresentationHandle)

const QUEUED := "queued"
const RUNNING := "running"
const COMPLETED := "completed"
const CANCELLED := "cancelled"
const SNAPPED := "snapped"

var batch_id := 0
var revision := -1
var origin_action_id := ""
var status := QUEUED
var completion_reason := ""


func is_completed() -> bool:
	return status in [COMPLETED, CANCELLED, SNAPPED]


func mark_running() -> void:
	if status == QUEUED:
		status = RUNNING


func finish(next_status: String = COMPLETED, reason: String = "") -> void:
	if is_completed():
		return
	status = next_status
	completion_reason = reason
	completed.emit(self)

