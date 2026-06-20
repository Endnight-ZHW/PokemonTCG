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


func to_dict() -> Dictionary:
	return {
		"success": success,
		"message": message,
		"pending_choice": pending_choice.to_dict() if pending_choice else null,
		"events": events.duplicate(true),
		"winner": winner,
		"terminal": terminal,
		"error_code": error_code,
	}
