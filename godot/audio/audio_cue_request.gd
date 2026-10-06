class_name AudioCueRequest
extends RefCounted

## Local presentation data only. Never serialize these into a game action.
var cue: StringName
var element := ""
var intensity := 1.0
var heavy := false
var event_id := ""
var phase := ""
var ordinal := 0
var scope_id: StringName = &"battle"
## Explicit variant for the sound workbench; normal gameplay uses -1.
var variant := -1


static func make(id: StringName, scope: StringName = &"battle", event := "", stage := "", index := 0) -> AudioCueRequest:
	var request := AudioCueRequest.new()
	request.cue = id
	request.scope_id = scope
	request.event_id = event
	request.phase = stage
	request.ordinal = index
	return request


func resolved_cue() -> StringName:
	var name_value := str(cue)
	if name_value in ["attack_hit", "attack_charge"]:
		if name_value == "attack_hit" and heavy:
			name_value = "attack_heavy"
		name_value += "_" + (element.to_lower() if not element.is_empty() else "colorless")
	return StringName(name_value)


func identity() -> String:
	if event_id.is_empty():
		return ""
	return "%s|%s|%s|%d|%s" % [scope_id, event_id, phase, ordinal, cue]
