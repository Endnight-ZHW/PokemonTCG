class_name AudioCatalog
extends Resource

@export var cues: Array[AudioCueDefinition] = []
@export var tracks: Array[MusicTrackDefinition] = []


func cue_map() -> Dictionary:
	var result := {}
	for cue in cues:
		result[cue.id] = cue
	return result


func track_map() -> Dictionary:
	var result := {}
	for track in tracks:
		result[track.id] = track
	return result
