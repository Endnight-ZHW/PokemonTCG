class_name AudioVoicePool
extends Node

signal started(request: AudioCueRequest, definition: AudioCueDefinition, variant: int)

var players: Array[AudioStreamPlayer] = []
var slots: Array[Dictionary] = []
var rng := RandomNumberGenerator.new()
var last_variants: Dictionary = {}
var last_times: Dictionary = {}
var serial := 0


func configure(bus: String, count: int) -> void:
	rng.randomize()
	for index in range(count):
		var player := AudioStreamPlayer.new()
		player.bus = bus
		add_child(player)
		players.append(player)
		slots.append({})


func play(request: AudioCueRequest, definition: AudioCueDefinition) -> bool:
	if definition.variants.is_empty():
		return false
	var now := Time.get_ticks_msec()
	var key := "%s:%s" % [request.scope_id, definition.id]
	if request.variant < 0 and now - int(last_times.get(key, -100000)) < definition.cooldown_ms:
		return false
	# A landed/failed attack replaces its preparatory sound, including fast mode.
	if definition.category == "impact" or definition.id in [&"attack_failed", &"pokemon_ko", &"direct_ko"]:
		for index in range(players.size()):
			if slots[index].get("scope") == request.scope_id and slots[index].get("category") == "charge":
				players[index].stop()
				players[index].stream = null
				slots[index] = {}
	var matching: Array[int] = []
	var available := -1
	var victim := -1
	var recent_stack := 0
	for index in range(players.size()):
		if not players[index].playing:
			if available < 0:
				available = index
			continue
		var slot := slots[index]
		if not definition.stack_group.is_empty() and slot.get("group") == definition.stack_group and slot.get("scope") == request.scope_id and now - int(slot.get("started_ms", 0)) <= definition.stack_window_ms:
			recent_stack += 1
		if slot.get("cue") == definition.id:
			matching.append(index)
		if victim < 0 or _older_or_lower(slot, slots[victim]):
			victim = index
	if matching.size() >= definition.max_instances:
		available = matching[0]
		for index in matching:
			if int(slots[index].order) < int(slots[available].order):
				available = index
	if available < 0:
		if victim < 0 or int(slots[victim].priority) > definition.priority:
			return false
		available = victim
	var variant := request.variant
	if variant < 0:
		var count := definition.variants.size()
		var previous := int(last_variants.get(definition.id, -1))
		variant = rng.randi_range(0, count - 2) if count > 1 and previous >= 0 else rng.randi_range(0, count - 1)
		if count > 1 and previous >= 0 and variant >= previous:
			variant += 1
	variant = clampi(variant, 0, definition.variants.size() - 1)
	last_variants[definition.id] = variant
	last_times[key] = now
	serial += 1
	var stack_db := maxf(-6.0, definition.stack_step_db * mini(recent_stack, 4))
	slots[available] = {"cue": definition.id, "scope": request.scope_id, "priority": definition.priority, "order": serial, "duck": definition.duck_db, "category": definition.category, "group": definition.stack_group, "started_ms": now, "stack_db": stack_db}
	var player := players[available]
	player.stop()
	player.stream = definition.variants[variant]
	# Fixed-variant audition should be repeatable, including pitch and loudness.
	player.pitch_scale = 1.0 if request.variant >= 0 else rng.randf_range(1.0 - definition.pitch_spread, 1.0 + definition.pitch_spread)
	var jitter := 0.0 if request.variant >= 0 else rng.randf_range(-definition.gain_spread_db, definition.gain_spread_db)
	player.volume_db = definition.gain_db + jitter + stack_db + linear_to_db(clampf(request.intensity, 0.7, 1.3))
	player.play()
	started.emit(request, definition, variant)
	return true


func _older_or_lower(a: Dictionary, b: Dictionary) -> bool:
	return int(a.priority) < int(b.priority) or (a.priority == b.priority and int(a.order) < int(b.order))


func cancel_scope(scope: StringName) -> void:
	for index in range(players.size()):
		if scope.is_empty() or slots[index].get("scope") == scope:
			players[index].stop()
			players[index].stream = null
			slots[index] = {}
	for key in last_times.keys():
		if scope.is_empty() or str(key).begins_with(str(scope) + ":"):
			last_times.erase(key)


func duck_db() -> float:
	var result := 0.0
	for index in range(players.size()):
		if players[index].playing:
			result = minf(result, float(slots[index].get("duck", 0.0)))
	return result
