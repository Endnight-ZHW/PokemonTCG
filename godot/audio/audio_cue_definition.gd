class_name AudioCueDefinition
extends Resource

@export var id: StringName
@export var category := "cards"
@export var variants: Array[AudioStream] = []
@export var bus := "SFX"
@export var gain_db := 0.0
@export var pitch_spread := 0.025
@export var gain_spread_db := 0.8
@export var priority := 1
@export var max_instances := 4
@export var cooldown_ms := 30
@export var duck_db := 0.0
## Lower only overlapping members of the same perceptual family and scope.
@export var stack_group: StringName
@export var stack_step_db := 0.0
@export var stack_window_ms := 160
