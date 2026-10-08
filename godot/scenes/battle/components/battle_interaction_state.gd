class_name BattleInteractionState
extends RefCounted

## Local UI state only. Legal actions and mandatory choices remain session-owned.
enum Stage { BROWSING, ACTION_MENU, TARGET, CONFIRMATION }

var source_key := ""
var group_key := ""
var popover_source := ""
var dismissed_source := ""
var forced_rows: Array[Dictionary] = []
var forced_source := ""
var stage := Stage.BROWSING
var _last_source := ""
var _identity := ""
var _actions_signature := ""


func reconcile(identity: String, actions_signature: String) -> Dictionary:
	var changed := source_key != _last_source or identity != _identity or actions_signature != _actions_signature
	var invalidated := changed and not group_key.is_empty() and source_key == _last_source
	if changed:
		reset_operation()
	_last_source = source_key
	_identity = identity
	_actions_signature = actions_signature
	return {"changed": changed, "invalidated": invalidated}


func begin_target(key: String) -> void:
	group_key = key
	popover_source = ""
	stage = Stage.TARGET


func reset_operation() -> void:
	group_key = ""
	popover_source = ""
	dismissed_source = ""
	forced_rows.clear()
	forced_source = ""
	stage = Stage.BROWSING if source_key.is_empty() else Stage.ACTION_MENU


func confirmation_context() -> Dictionary:
	var result := {"source": source_key, "identity": _identity, "group": group_key}
	stage = Stage.CONFIRMATION
	return result
