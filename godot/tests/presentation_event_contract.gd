extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	_run_normalization_contract()
	_run_director_contract()
	_run_rule_event_contract()
	_run_rule_event_regressions()
	if failures.is_empty():
		print("PRESENTATION_EVENT_CONTRACT_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_normalization_contract() -> void:
	var discarded := PresentationEvent.normalize({
		"event_type": "card_discarded",
		"card_id": "sv1-ener-5",
		"source": {"player": 1, "slot": "active", "index": 0},
		"target": {"player": 1, "zone": "discard"},
		"data": {"player": 1, "card_id": "sv1-ener-5"},
	}, 12, 0)
	_expect(
		str(discarded.get("event_type", "")) == "cards_discarded",
		"legacy singular discard event was not canonicalized",
	)
	_expect(
		int(discarded.get("amount", 0)) == 1
		and discarded.get("data", {}).get("card_ids", []) == ["sv1-ener-5"],
		"single discard event did not derive its canonical card list and amount",
	)
	_expect(
		str(discarded.get("source", {}).get("slot", "")) == "active"
		and str(discarded.get("target", {}).get("zone", "")) == "discard"
		and str(discarded.get("target", {}).get("slot", "")).is_empty(),
		"explicit discard endpoints were overwritten by data defaults",
	)

	var counters := PresentationEvent.normalize({
		"event_type": "damage_counters_placed",
		"data": {"player": 1, "slot": "active", "count": 3},
	}, 13, 0)
	_expect(
		int(counters.get("amount", 0)) == 30
		and int(counters.get("data", {}).get("counter_count", 0)) == 3,
		"damage counter event did not expose HP amount and counter_count separately",
	)
	_expect(
		int(counters.get("target", {}).get("player", -1)) == 1
		and str(counters.get("target", {}).get("slot", "")) == "active",
		"damage counter event did not derive its target endpoint",
	)

	var selected := PresentationEvent.normalize(
		VMZoneHelpers.cards_selected_event(
			0,
			"deck",
			"hand",
			["sv1-104", "sv1-151"],
		),
		14,
		0,
	)
	_expect(
		str(selected.get("source", {}).get("zone", "")) == "deck"
		and str(selected.get("target", {}).get("zone", "")) == "hand",
		"selected card event is missing explicit source or target",
	)
	_expect(
		PresentationEvent.for_player(selected, 1).get("data", {}).get(
			"card_ids", []).is_empty(),
		"selected card event leaked private card identities",
	)

	var revealed := PresentationEvent.normalize({
		"event_type": "cards_revealed",
		"actor": 0,
		"visibility": "public",
		"data": {
			"player": 0,
			"cards": [
				{
					"card_id": "sv1-ener-1",
					"matched": true,
					"destination": {"player": 0, "zone": "discard"},
				},
				{
					"card_id": "sv2-delib",
					"matched": false,
					"destination": {"player": 0, "zone": "deck"},
				},
			],
			"summary": {
				"kind": "energy_damage",
				"matched_count": 1,
				"amount": 80,
			},
		},
	}, 14, 0)
	var opponent_reveal := PresentationEvent.for_player(revealed, 1)
	var opponent_reveal_data: Dictionary = opponent_reveal.get("data", {})
	var opponent_reveal_cards: Array = opponent_reveal_data.get("cards", [])
	_expect(
		int(revealed.get("amount", 0)) == 2
		and str(revealed.get("source", {}).get("zone", "")) == "deck"
		and str(revealed.get("target", {}).get("zone", "")) == "deck"
		and opponent_reveal_cards.size() == 2
		and str(Dictionary(opponent_reveal_cards[0]).get(
			"card_id", "")) == "sv1-ener-1",
		"public card reveal lost its order, endpoints, or opponent-visible identity",
	)

	var indexed_discard := PresentationEvent.normalize(
		VMZoneHelpers.discard_event(
			0,
			"hand",
			["sv1-104", "sv1-151"],
			2,
			[3, 1],
		),
		15,
		0,
	)
	_expect(
		int(indexed_discard.get("source", {}).get("index", -1)) == 1
		and indexed_discard.get("data", {}).get("source_indices", []) == [1, 3],
		"discard event lost the source indices needed to disambiguate duplicate cards",
	)


func _run_director_contract() -> void:
	var director := PresentationDirector.new()
	get_root().add_child(director)
	var completion := PresentationDirector.EventCompletion.new(0.25)
	completion.hold()
	completion.arm_fallback(self)
	_expect(
		completion.is_held() and not completion.is_finished(),
		"held event completion unexpectedly used its timer fallback",
	)
	completion.finish()
	_expect(
		completion.is_finished(),
		"event completion could not be confirmed by an animation executor",
	)
	for event_type in PresentationEvent.SUPPORTED_EVENT_TYPES:
		_expect(
			director.has_handler(event_type),
			"director has no explicit handler for %s" % event_type,
		)
		_expect(
			director._duration_for({"event_type": event_type, "amount": 1}) > 0.0,
			"director has no explicit duration for %s" % event_type,
		)
	_expect(
		director._duration_for({"event_type": "future_event"}) == 0.0,
		"unknown presentation events still introduce a default delay",
	)
	director.set_speed_mode("reduced")
	_expect(
		director._duration_for({"event_type": "pokemon_ko"}) == 0.0,
		"reduced motion still introduces an artificial presentation wait",
	)
	for event_type in PresentationDirector.ANNOUNCEMENT_EVENT_TYPES:
		_expect(
			is_equal_approx(
				director._duration_for({"event_type": event_type}),
				0.22,
			),
			"reduced motion dropped the semantic hold for %s" % event_type,
		)
	director.set_speed_mode("cinematic")

	var floating_messages: Array[String] = []
	var floating_targets: Array[Dictionary] = []
	director.floating_text_requested.connect(func(
		text: String,
		target: Dictionary,
		_color: Color,
	) -> void:
		floating_messages.append(text)
		floating_targets.append(target.duplicate(true))
	)
	var dispatched_events: Array[Dictionary] = []
	for event_type in [
		"confusion_failed",
		"damage_prevented",
		"turn_end",
		"checkup",
		"turn_start",
		"status_applied",
	]:
		var normalized := PresentationEvent.normalize({
			"event_type": event_type,
			"amount": 30 if event_type == "confusion_failed" else 0,
			"data": {
				"player": 0,
				"slot": "active",
				"turn": 3,
				"status": "POISONED",
			},
		}, 15, 0)
		dispatched_events.append(normalized)
		director._dispatch(normalized)
	var expected_feedback := {
		"混乱 -30": "",
		"伤害无效": "",
		"回合结束": PresentationDirector.FEEDBACK_CHANNEL_ANNOUNCEMENT,
		"宝可梦检查": PresentationDirector.FEEDBACK_CHANNEL_ANNOUNCEMENT,
		"第 3 回合": PresentationDirector.FEEDBACK_CHANNEL_ANNOUNCEMENT,
		"中毒": "",
	}
	_expect(
		floating_messages.size() == expected_feedback.size()
		and floating_targets.size() == expected_feedback.size(),
		"director did not emit every world/announcement feedback event",
	)
	for index in range(mini(floating_messages.size(), floating_targets.size())):
		var text: String = floating_messages[index]
		var actual_channel := str(floating_targets[index].get(
			PresentationDirector.FEEDBACK_CHANNEL_KEY,
			"",
		))
		_expect(
			expected_feedback.has(text)
			and actual_channel == str(expected_feedback.get(text, "missing")),
			"feedback '%s' used the wrong presentation channel" % text,
		)
	var source_events_untouched := true
	for event in dispatched_events:
		if Dictionary(event.get("target", {})).has(
			PresentationDirector.FEEDBACK_CHANNEL_KEY
		):
			source_events_untouched = false
	_expect(
		source_events_untouched,
		"feedback routing metadata mutated its source presentation event",
	)

	var ko_feedback_targets: Array[Dictionary] = []
	var ko_burst_targets: Array[Dictionary] = []
	director.floating_text_requested.connect(func(
		text: String,
		target: Dictionary,
		_color: Color,
	) -> void:
		if text == "击倒":
			ko_feedback_targets.append(target.duplicate(true))
	)
	director.burst_requested.connect(func(
		kind: String,
		target: Dictionary,
		_color: Color,
	) -> void:
		if kind == "ko":
			ko_burst_targets.append(target.duplicate(true))
	)
	director._dispatch(PresentationEvent.normalize({
		"event_type": "pokemon_ko",
		"actor": 0,
		"source": {"player": 1, "slot": "bench_2"},
		"target": {"player": 1, "zone": "discard"},
		"data": {"player": 1, "slot": "bench_2"},
	}, 16, 0))
	_expect(
		ko_feedback_targets.size() == 1
		and ko_burst_targets.size() == 1
		and str(ko_feedback_targets[0].get("slot", "")) == "bench_2"
		and str(ko_burst_targets[0].get("slot", "")) == "bench_2",
		"KO feedback followed the discard destination instead of the board source",
	)

	var scheduled_landings: Array[Dictionary] = []
	var immediate_target_bursts: Array[String] = []
	director.card_landing_feedback_scheduled.connect(func(
		event: Dictionary,
		feedback: Dictionary,
	) -> void:
		scheduled_landings.append({
			"event_type": str(event.get("event_type", "")),
			"kind": str(feedback.get("kind", "")),
		})
	)
	director.burst_requested.connect(func(
		kind: String,
		_target: Dictionary,
		_color: Color,
	) -> void:
		if kind in ["card_place", "trainer", "energy", "evolution"]:
			immediate_target_bursts.append(kind)
	)
	for event_type in [
		"pokemon_played",
		"trainer_played",
		"tool_attached",
		"energy_attached",
		"pokemon_evolved",
	]:
		director._dispatch(PresentationEvent.normalize({
			"event_type": event_type,
			"actor": 0,
			"card_id": "sv1-104",
			"source": {"player": 0, "zone": "hand", "index": 0},
			"target": {"player": 0, "slot": "active"},
			"data": {"player": 0, "slot": "active"},
		}, 17, 0))
	_expect(
		scheduled_landings.size() == 5 and immediate_target_bursts.is_empty(),
		"card target feedback still fired at takeoff instead of being scheduled for landing",
	)

	director.set_speed_mode("fast")
	var camera_durations: Array[float] = []
	director.camera_impulse_requested.connect(func(
		_strength: float,
		duration: float,
	) -> void:
		camera_durations.append(duration)
	)
	var fast_damage := PresentationEvent.normalize({
		"event_type": "damage_dealt",
		"amount": 30,
		"target": {"player": 1, "slot": "active"},
		"data": {"player": 1, "slot": "active", "amount": 30},
	}, 18, 0)
	director._dispatch(fast_damage)
	_expect(
		camera_durations.size() == 1
		and camera_durations[0] < director._duration_for(fast_damage),
		"fast camera impulse can outlive its event barrier",
	)
	director.queue_free()


func _run_rule_event_contract() -> void:
	var catalog := CardCatalog.new()
	var settlement := VMKnockoutSettlement.new(
		catalog,
		RulesValidator.new(catalog),
	)
	var state := GameState.new()
	state.phase = "ATTACK"
	state.turn_number = 2
	state.active_player_idx = 0
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[0].prizes = ["sv1-ener-5", "sv1-ener-5"]
	state.players[1].active = PokemonState.new("sv1-104")
	state.players[1].active.damage_counters = 100
	var events: Array[Dictionary] = []
	var result := settlement.resolve_knockouts(state, 0, events, true)
	_expect(bool(result.get("success", false)), "KO contract fixture failed to resolve")
	var ko_index := -1
	var ko_leave_index := -1
	var prize_index := -1
	for index in range(events.size()):
		match str(events[index].get("event_type", "")):
			"pokemon_ko":
				ko_index = index
				var ko_event: Dictionary = events[index]
				_expect(
					str(ko_event.get("source", {}).get("slot", "")) == "active"
					and str(ko_event.get("target", {}).get("slot", "")) == "active"
					and bool(ko_event.get("data", {}).get("defer_leave_play", false)),
					"KO declaration does not preserve its on-board source for triggers",
				)
			"card_moved":
				if bool(events[index].get("data", {}).get("ko_leave_play", false)):
					ko_leave_index = index
			"prize_taken":
				if prize_index < 0:
					prize_index = index
	_expect(
		ko_index >= 0
		and ko_leave_index > ko_index
		and prize_index > ko_leave_index,
		"KO declaration, leave-play movement and prize movement are out of order",
	)


func _run_rule_event_regressions() -> void:
	var reveal_catalog := CardCatalog.new()
	var reveal_state := GameState.new()
	reveal_state.players[0].active = PokemonState.new("svi-infr")
	reveal_state.players[1].active = PokemonState.new("sv1-104")
	reveal_state.players[0].deck = [
		"sv2-delib",
		"sv1-ener-1",
		"sv1-ener-2",
	]
	var reveal_events: Array[Dictionary] = []
	var reveal_result := VMCombatCombo.new(
		reveal_catalog,
		VMCombatDamage.new(),
	).mill_then_damage(
		reveal_state,
		ResolutionStack.new(),
		PortableRandomSource.new(20260715),
		0,
		{"mill_count": 5, "damage_per": 40},
		reveal_events,
	)
	var reveal_event: Dictionary = (
		reveal_events[0] if not reveal_events.is_empty() else {}
	)
	var reveal_event_data: Dictionary = reveal_event.get("data", {})
	var reveal_rows: Array = reveal_event_data.get("cards", [])
	var reveal_summary: Dictionary = reveal_event_data.get("summary", {})
	_expect(
		bool(reveal_result.get("success", false))
		and reveal_events.size() == 3
		and str(reveal_event.get("event_type", "")) == "cards_revealed"
		and str(reveal_events[1].get("event_type", "")) == "deck_shuffled"
		and str(reveal_events[2].get("event_type", "")) == "damage_dealt"
		and reveal_rows.size() == 3
		and str(reveal_rows[0].get("card_id", "")) == "sv1-ener-2"
		and str(reveal_rows[1].get("card_id", "")) == "sv1-ener-1"
		and str(reveal_rows[2].get("card_id", "")) == "sv2-delib"
		and str(reveal_rows[0].get("destination", {}).get("zone", "")) == "discard"
		and str(reveal_rows[2].get("destination", {}).get("zone", "")) == "deck"
		and int(reveal_summary.get("amount", 0)) == 80,
		"mill_then_damage did not emit an ordered public composite reveal before shuffle and damage",
	)

	var empty_reveal_state := GameState.new()
	empty_reveal_state.players[0].active = PokemonState.new("svi-infr")
	empty_reveal_state.players[1].active = PokemonState.new("sv1-104")
	var empty_reveal_events: Array[Dictionary] = []
	var empty_reveal_result := VMCombatCombo.new(
		reveal_catalog,
		VMCombatDamage.new(),
	).mill_then_damage(
		empty_reveal_state,
		ResolutionStack.new(),
		PortableRandomSource.new(20260716),
		0,
		{"mill_count": 5, "damage_per": 40},
		empty_reveal_events,
	)
	var empty_event: Dictionary = (
		empty_reveal_events[0] if not empty_reveal_events.is_empty() else {}
	)
	var empty_data: Dictionary = empty_event.get("data", {})
	var empty_summary: Dictionary = empty_data.get("summary", {})
	_expect(
		bool(empty_reveal_result.get("success", false))
		and empty_reveal_events.size() == 2
		and str(empty_event.get("event_type", "")) == "cards_revealed"
		and Array(empty_data.get("cards", [])).is_empty()
		and int(empty_summary.get("matched_count", -1)) == 0
		and int(empty_summary.get("amount", -1)) == 0
		and str(empty_reveal_events[1].get("event_type", "")) == "deck_shuffled",
		"mill_then_damage suppressed the zero-card public reveal result",
	)

	var hammer_catalog := CardCatalog.new()
	var hammer_runtime := VMRuntime.new(hammer_catalog)
	var hammer_state := GameState.new()
	hammer_state.active_player_idx = 0
	hammer_state.players[1].bench[0] = PokemonState.new("sv2-delib")
	hammer_state.players[1].bench[0].energy_card_ids.append("sv1-ener-4")
	var hammer_events: Array[Dictionary] = []
	var hammer_result := hammer_runtime.board_continuations.resolve_discard_attachment(
		hammer_state,
		{"player_idx": 0},
		[{
			"value": {
				"player": 1,
				"slot": "bench_0",
				"index": 0,
				"card_id": "sv1-ener-4",
			},
		}],
		hammer_events,
	)
	var hammer_event: Dictionary = (
		hammer_events[0] if hammer_events.size() == 1 else {}
	)
	_expect(
		bool(hammer_result.get("success", false))
		and hammer_state.players[1].bench[0].energy_card_ids.is_empty()
		and hammer_state.players[1].discard == ["sv1-ener-4"]
		and int(hammer_event.get("actor", -1)) == 0
		and int(hammer_event.get("source", {}).get("player", -1)) == 1
		and str(hammer_event.get("source", {}).get("slot", "")) == "bench_0"
		and str(hammer_event.get("source", {}).get("attachment_type", "")) == "energy"
		and int(hammer_event.get("source", {}).get("index", -1)) == 0
		and int(hammer_event.get("target", {}).get("player", -1)) == 1
		and str(hammer_event.get("target", {}).get("zone", "")) == "discard",
		"opponent attachment discard lost its owner, slot, index, or discard endpoint",
	)
	var normalized_hammer := PresentationEvent.normalize(hammer_event, 16, 0)
	_expect(
		int(normalized_hammer.get("actor", -1)) == 0
		and int(normalized_hammer.get("source", {}).get("player", -1)) == 1
		and str(normalized_hammer.get("source", {}).get("slot", "")) == "bench_0"
		and str(normalized_hammer.get("source", {}).get(
			"attachment_type", "")) == "energy"
		and int(normalized_hammer.get("target", {}).get("player", -1)) == 1
		and str(normalized_hammer.get("target", {}).get("zone", "")) == "discard",
		"presentation normalization reassigned an opponent attachment discard to its actor",
	)

	var empty_draw_state := GameState.new()
	var empty_draw_events: Array[Dictionary] = []
	VMZoneHelpers.draw_available(empty_draw_state, 0, 2, empty_draw_events)
	_expect(
		empty_draw_events.is_empty(),
		"an empty deck emitted a zero-card draw presentation event",
	)

	var damage_state := GameState.new()
	damage_state.players[0].active = PokemonState.new("sv1-104")
	var damage_events: Array[Dictionary] = []
	VMCombatDamage.new().deal_damage(
		damage_state,
		0,
		"active",
		15,
		damage_events,
	)
	_expect(
		damage_state.players[0].active.damage_counters == 1
		and damage_events.size() == 1
		and int(damage_events[0].get("data", {}).get("amount", 0)) == 10,
		"damage event amount did not match the actual 10-HP counter change",
	)

	var catalog := CardCatalog.new()
	var settlement := VMKnockoutSettlement.new(
		catalog,
		RulesValidator.new(catalog),
	)
	var simultaneous_state := GameState.new()
	simultaneous_state.phase = "ATTACK"
	simultaneous_state.active_player_idx = 0
	simultaneous_state.players[0].active = PokemonState.new("sv1-104")
	simultaneous_state.players[0].active.damage_counters = 100
	simultaneous_state.players[0].prizes = ["sv1-ener-5", "sv1-ener-5"]
	simultaneous_state.players[1].active = PokemonState.new("sv1-104")
	simultaneous_state.players[1].active.damage_counters = 100
	simultaneous_state.players[1].prizes = ["sv1-ener-6", "sv1-ener-6"]
	var simultaneous_events: Array[Dictionary] = []
	settlement.resolve_knockouts(simultaneous_state, 0, simultaneous_events, true)
	var last_ko_index := -1
	var first_prize_index := simultaneous_events.size()
	for index in range(simultaneous_events.size()):
		match str(simultaneous_events[index].get("event_type", "")):
			"pokemon_ko":
				last_ko_index = index
			"prize_taken":
				first_prize_index = mini(first_prize_index, index)
	_expect(
		last_ko_index >= 0
		and first_prize_index < simultaneous_events.size()
		and last_ko_index < first_prize_index,
		"simultaneous KO settlement emitted a prize before every KO left play",
	)

	var short_prize_state := GameState.new()
	short_prize_state.phase = "ATTACK"
	short_prize_state.active_player_idx = 0
	short_prize_state.players[0].active = PokemonState.new("sv1-104")
	short_prize_state.players[0].prizes = ["sv1-ener-5"]
	short_prize_state.players[1].active = PokemonState.new("svl-pikaex")
	short_prize_state.players[1].active.damage_counters = 100
	var short_prize_events: Array[Dictionary] = []
	settlement.resolve_knockouts(short_prize_state, 0, short_prize_events, true)
	var prize_events: Array[Dictionary] = []
	for event in short_prize_events:
		if str(event.get("event_type", "")) == "prize_taken":
			prize_events.append(event)
	_expect(
		prize_events.size() == 1
		and not str(prize_events[0].get("card_id", "")).is_empty(),
		"multi-prize KO emitted an empty prize movement after prizes ran out",
	)

	var checkup_state := GameState.new()
	checkup_state.turn_number = 4
	checkup_state.active_player_idx = 0
	checkup_state.players[0].active = PokemonState.new("sv1-104")
	checkup_state.players[0].active.status_conditions.append("POISONED")
	checkup_state.players[1].active = PokemonState.new("sv1-104")
	checkup_state.players[1].active.status_conditions.append("BURNED")
	var checkup_events: Array[Dictionary] = []
	VMTurnSettlement.new(settlement).resolve_checkup(
		checkup_state,
		PortableRandomSource.new(20260714),
		checkup_events,
	)
	var status_damage := 0
	var damaged_players: Array[int] = []
	for event in checkup_events:
		if str(event.get("event_type", "")) != "damage_dealt":
			continue
		status_damage += int(event.get("amount", event.get("data", {}).get("amount", 0)))
		damaged_players.append(int(event.get("target", {}).get(
			"player",
			event.get("data", {}).get("player", -1),
		)))
	_expect(
		status_damage == 30 and 0 in damaged_players and 1 in damaged_players,
		"checkup status damage changed state without matching damage events",
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
