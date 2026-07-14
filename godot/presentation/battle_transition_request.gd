class_name BattleTransitionRequest
extends RefCounted

const CAUSE_INITIAL := "initial"
const CAUSE_LOCAL_ACTION := "local_action"
const CAUSE_AI_ACTION := "ai_action"
const CAUSE_CHOICE := "choice"
const CAUSE_NETWORK := "network"
const CAUSE_REFRESH := "refresh"
const CAUSE_RESYNC := "resync"

var target_view: BattleViewModel
var events: Array = []
var revision := -1
var fallback_actor := -1
var origin_action_id := ""
var origin_request_id := ""
var drag_session_id := ""
var cause := CAUSE_REFRESH
var critical := true


static func create(
	p_target_view: BattleViewModel,
	p_events: Array = [],
	p_fallback_actor: int = -1,
	p_cause: String = CAUSE_REFRESH,
	p_origin_action_id: String = "",
	p_origin_request_id: String = "",
	p_drag_session_id: String = "",
	p_critical: bool = true,
) -> BattleTransitionRequest:
	var result := BattleTransitionRequest.new()
	result.target_view = p_target_view
	result.events = p_events.duplicate(true)
	result.revision = p_target_view.revision() if p_target_view != null else -1
	result.fallback_actor = p_fallback_actor
	result.cause = p_cause
	result.origin_action_id = p_origin_action_id
	result.origin_request_id = p_origin_request_id
	result.drag_session_id = p_drag_session_id
	result.critical = p_critical
	return result

