extends "res://tests/csv5_rules_contract.gd"

## New rule effects must retain physical card identities and legal wire endpoints.
func run() -> void:
	cards = CardCatalog.shared().cards.duplicate(true)
	var state := base_state("csv5-014", "csv5-002")
	state.players[0].active.attached_tool_id = "csv5-120"
	state.players[0].active.energy_card_ids.assign(["sv1-ener-2"])
	state.players[1].active.evolution_stack_ids.assign(["csv5-001"])
	var native: Variant = session(state)
	var result := act(native, "DECLARE_ATTACK", 1)
	var events := wire_events(result, "devolution")
	check(has_move(events, "csv5-002", "active", "hand"), "Devolution lost the outgoing evolution's board source")
	check(has_move(events, "csv5-120", "active", "discard", "cards_discarded"), "Expired TM lost its attachment source")
	state.players[1].active.damage_counters = int(cards["csv5-001"].hp) / 10
	state.players[1].bench[0] = pokemon("csv5-028")
	native = session(state)
	events = wire_events(act(native, "DECLARE_ATTACK", 1), "devolution knockout")
	var knockout_found := false
	for event in events:
		if event.event_type != "pokemon_ko": continue
		knockout_found = true
		check(event.card_id == "csv5-001" and event.target.player == 1 and event.target.slot == "active", "Devolution KO feedback targets the attacker or wrong evolution")
	check(knockout_found, "Devolution knockout has no feedback")
	check(has_move(events, "csv5-001", "active", "discard"), "Devolved KO lost its leave-play motion")

	state = base_state("csv5-014", "csv5-028")
	state.players[0].active.attached_tool_id = "csv5-119"
	state.players[0].active.energy_card_ids.assign(["sv1-ener-2"])
	state.players[0].bench[0] = pokemon("csv5-001")
	state.players[0].deck.assign(["csv5-002", "sv1-ener-2"])
	native = session(state)
	wire_events(act(native, "DECLARE_ATTACK", 1), "TM attack")
	wire_events(choose(native, 0, [0]), "TM target")
	check(native.pending_choice(0).max_select == 1, "Evolution search incorrectly disallows all cards")
	events = wire_events(choose(native, 0, [0]), "TM evolution")
	check(has_move(events, "csv5-002", "deck", "bench_0", "pokemon_evolved"), "TM evolution did not use the staged evolution animation")
	check(native.snapshot().players[0].bench[0].card_id == "csv5-002", "TM selected evolution did not enter play")

	state = base_state("csv5-081", "csv5-028")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-7"])
	state.players[0].bench[0] = pokemon("csv5-081")
	state.players[0].deck.assign(["sv1-ener-7", "sv1-ener-2"])
	native = session(state)
	wire_events(act(native, "DECLARE_ATTACK", 0), "Houndour attack")
	check(native.pending_choice(0).max_select == 1, "Energy search incorrectly disallows all cards")
	events = wire_events(choose(native, 0, [0]), "Houndour attachment")
	check(has_move(events, "sv1-ener-7", "deck", "bench_0", "energy_attached"), "Attack attachment did not stage the energy badge at landing")
	check(native.snapshot().players[0].bench[0].energy_card_ids == ["sv1-ener-7"], "Selected attack energy did not attach")

	state = base_state("csv5-014", "csv5-028")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-2"])
	state.players[0].bench[0] = pokemon("csv5-073")
	for index in 5: state.players[1].bench[index] = pokemon("csv5-001", ["sv1-ener-1"])
	native = session(state)
	wire_events(act(native, "RETREAT", -1, "bench_0"), "bench limit retreat")
	var payment_events := wire_events(choose(native, 0, [0]), "retreat payment")
	check(has_move(payment_events, "csv5-014", "active", "bench_0", "retreat"), "Retreat movement was withheld until the opponent chose bench discards")
	check(not native.pending_choice(1).can_cancel, "Opponent can cancel a committed retreat")
	events = wire_events(choose(native, 1, [0, 1]), "bench limit discard")
	for slot in ["bench_0", "bench_1"]:
		check(has_move(events, "csv5-001", slot, "discard"), "Bench reduction lost a departing Pokemon: " + slot)
		check(has_move(events, "sv1-ener-1", slot, "discard"), "Bench reduction lost an attachment: " + slot)
	for event in events:
		check(event.event_type != "pokemon_ko", "Bench reduction played a false knockout")
		check(event.event_type != "retreat", "Retreat movement replayed after opponent's discard choice")
	state = base_state("csv5-115", "csv5-028")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-2"])
	state.players[0].bench[0] = pokemon("csv5-014")
	native = session(state)
	events = wire_events(act(native, "USE_ABILITY"), "Doll discard")
	check(has_move(events, "csv5-115", "active", "discard"), "Doll self-discard lost its departing card")
	check(has_move(events, "sv1-ener-2", "active", "discard"), "Doll self-discard lost its energy")
	if failures.is_empty(): print("CSV5_PRESENTATION_CONTRACT_OK")
	quit(0 if failures.is_empty() else 1)

func wire_events(result: Dictionary, label: String) -> Array[Dictionary]:
	var events := PresentationEvent.normalize_all(result.get("events", []), 0, 0)
	for event in events:
		for endpoint in [event.source, event.target]:
			check(endpoint.get("zone", "") not in ["active", "bench_0", "bench_1", "bench_2", "bench_3", "bench_4"], "Board slot encoded as a zone: " + label)
		if event.event_type == "cards_discarded" and event.card_id.begins_with("sv1-ener-") and not str(event.source.get("slot", "")).is_empty():
			check(event.source.get("attachment_type") == "energy", "Energy discard lost its attachment role: " + label)
		for viewer in 2:
			var visible := PresentationEvent.for_player(event, viewer)
			if not visible.is_empty():
				check(ProtocolV7._validate_presentation_event(visible), "Invalid wire event in %s: %s" % [label, JSON.stringify(visible)])
	return events

func has_move(events: Array[Dictionary], id: String, source: String, target: String, kind: String = "") -> bool:
	for event in events:
		if not kind.is_empty() and event.event_type != kind: continue
		if id not in event.get("data", {}).get("card_ids", [event.get("card_id", "")]): continue
		var from: Dictionary = event.get("source", {})
		var to: Dictionary = event.get("target", {})
		if endpoint_matches(from, source) and endpoint_matches(to, target):
			return true
	return false

func endpoint_matches(endpoint: Dictionary, location: String) -> bool:
	if location == "active" or location.begins_with("bench_"):
		return endpoint.get("slot", "") == location and str(endpoint.get("zone", "")).is_empty()
	return endpoint.get("zone", "") == location and str(endpoint.get("slot", "")).is_empty()
