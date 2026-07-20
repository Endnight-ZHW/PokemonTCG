class_name StepResult
extends RefCounted

var success: bool
var message: String
var pending_choice: ChoiceRequest
var events: Array[Dictionary]
var winner: int
var terminal: bool
var error_code: String


func _init(
	p_success: bool = false,
	p_message: String = "",
	p_pending_choice: ChoiceRequest = null,
	p_events: Array[Dictionary] = [],
	p_winner: int = -1,
	p_terminal: bool = false,
	p_error_code: String = "",
) -> void:
	success = p_success
	message = p_message
	pending_choice = p_pending_choice
	events = p_events.duplicate(true)
	winner = p_winner
	terminal = p_terminal
	error_code = p_error_code



func to_dict(base_revision: int = -1) -> Dictionary:
	var public_choice: Variant = null
	if pending_choice is ChoiceView:
		public_choice = pending_choice.to_dict()
	elif pending_choice != null:
		# StepResult is also used inside the settlement pipeline, where the
		# authoritative ChoiceRequest must remain available until GameEngine
		# commits it to GameState. Serialization is nevertheless always a public
		# boundary and must never emit continuation values or private metadata.
		public_choice = pending_choice.to_public_dict(base_revision)
	return {
		"success": success,
		"message": message,
		"pending_choice": public_choice,
		"events": events.duplicate(true),
		"winner": winner,
		"terminal": terminal,
		"error_code": error_code,
	}


func with_public_choice(base_revision: int) -> StepResult:
	if pending_choice != null and not pending_choice is ChoiceView:
		pending_choice = ChoiceView.from_request(pending_choice, base_revision)
	return self
