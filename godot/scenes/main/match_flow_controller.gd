class_name MatchFlowController
extends RefCounted

var session: NativeRulesSessionAdapter


func _init(p_session: NativeRulesSessionAdapter = null) -> void:
	session = p_session


func bind_session(p_session: NativeRulesSessionAdapter) -> void:
	session = p_session


func legal_actions(actor: int) -> LegalActionQueryResult:
	return session.legal_actions(actor) if session != null else LegalActionQueryResult.failure(
		-1, "native_rules_session_missing", "Native rules session is unavailable.")


func pending_choice(viewer: int) -> ChoiceView:
	return session.pending_choice(viewer) if session != null else null


func apply_action(action: GameAction) -> StepResult:
	return session.apply_action(action.to_dict()) if session != null else StepResult.new(
		false, "Native rules session is unavailable.", null, [], -1, false,
		"native_rules_session_missing")


func apply_choice(response: ChoiceResponse) -> StepResult:
	return session.apply_choice(response.to_dict()) if session != null else StepResult.new(
		false, "Native rules session is unavailable.", null, [], -1, false,
		"native_rules_session_missing")


func journal() -> Dictionary:
	return session.journal() if session != null else {}


func current_state() -> GameState:
	return session.state if session != null else null


func rng_state() -> int:
	return session.rng_state if session != null else 1
