extends SceneTree

const RELEASE_DECK_KEYS := [
	"colorless",
	"darkness",
	"dragon",
	"fighting",
	"fire",
	"grass",
	"lightning",
	"psychic",
	"steel",
	"water",
]
const TEST_SEED := 20260721

var failures: Array[String] = []


func _initialize() -> void:
	var started_ms := Time.get_ticks_msec()
	var catalog := CardCatalog.new()
	var engine := GameEngine.new(catalog)
	_check_retired_ai_removed()
	var state := _planner_state()
	var information_set := _check_information_set(state, catalog)
	var semantic_count := _check_semantic_catalog(catalog)
	_check_choice_constraints(catalog)
	_check_information_context_and_cache(state, catalog, engine)
	_check_search_hot_path_contract(state, catalog)
	_check_hot_path_string_wire_equivalence()
	_check_trace_format_wire_equivalence()
	_check_stable_variant_signature_wire_equivalence()
	_check_search_action_apply_equivalence(catalog)
	var registry := _check_strategy_registry(information_set)
	_check_dragon_strategy_regressions(registry)
	_check_shared_strategy_scoring_regressions(registry)
	_check_water_psychic_strategy_regressions(registry)
	_check_lightning_strategy_regressions(registry)
	var tactical_golden_count := _check_tactical_goldens(registry, catalog)
	_check_trusted_choice_bridge(state, registry, catalog)
	_check_cancel_prediction_uses_live_choice_policy(registry, catalog, engine)
	_check_trusted_dynamic_scoring(catalog)
	_check_post_plan_tactical_guards(catalog, engine)
	_check_no_progress_action_cycle_guard(catalog)
	_check_target_variant_candidate_coverage()
	_check_retreat_tempo_evaluation(catalog)
	_check_redundant_same_pokemon_retreat(catalog, engine)
	_check_mandatory_knockout(registry, catalog, engine)
	_check_repeatable_ability_turn_guard(catalog)
	_check_planner_contract(state, information_set, registry, catalog, engine)
	if failures.is_empty():
		print("TRADITIONAL_AI_ARCHITECTURE_OK ", JSON.stringify({
			"decks": RELEASE_DECK_KEYS.size(),
			"semantic_cards": semantic_count,
			"tactical_goldens": tactical_golden_count,
			"elapsed_ms": Time.get_ticks_msec() - started_ms,
		}))
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _check_retired_ai_removed() -> void:
	var retired_paths := [
		"res://tools/legacy_challenge_ai_acceptance.gd",
		"res://tools/legacy_observation_builder_acceptance.gd",
	]
	for path in retired_paths:
		_check(not FileAccess.file_exists(path),
			"Retired traditional AI source is still present: %s" % path)
	var evaluator_path := "res://tools/ai_evaluation_runner.gd"
	var evaluator_file := FileAccess.open(evaluator_path, FileAccess.READ)
	_check(evaluator_file != null, "Unable to inspect the AI evaluation runner")
	if evaluator_file != null:
		var source := evaluator_file.get_as_text()
		evaluator_file.close()
		_check(source.find("legacy_ucb_v1") < 0,
			"AI evaluation runner still exposes the retired UCB engine")
		_check(source.contains("Unsupported AI evaluation engine"),
			"AI evaluation runner does not fail closed for unknown engines")
	_check(NativeChallengeAI.heuristic_variants() == ["semantic_v2"],
		"NativeChallengeAI still exposes a retired heuristic variant")


func _check_information_set(
	state: GameState,
	catalog: CardCatalog,
) -> AIInformationSet:
	var source_before := state.snapshot()
	var information_set := AIInformationSet.capture(
		state, 0, catalog, [], [], TEST_SEED)
	_check(information_set.is_valid(), (
		"AIInformationSet capture failed: %s" % information_set.validation_error()))
	_check(state.snapshot() == source_before,
		"AIInformationSet capture mutated the authoritative state")
	if not information_set.is_valid():
		return information_set

	var view := information_set.read_only_view()
	var players: Array = view.get("players", [])
	_check(
		view.is_read_only()
		and players.is_read_only()
		and players.size() == 2,
		"AIInformationSet public view is not deeply read-only",
	)
	if players.size() != 2:
		return information_set
	var own: Dictionary = players[0]
	var opponent: Dictionary = players[1]
	_check(
		own.is_read_only()
		and opponent.is_read_only()
		and Array(own.get("hand", [])).is_read_only()
		and Array(opponent.get("hand", [])).is_read_only(),
		"AIInformationSet retained a mutable nested player zone",
	)
	_check(
		Array(own.get("hand", [])) == ["sv1-ener-2"],
		"AIInformationSet hid or changed the acting player's public hand",
	)
	_check(
		_all_values_equal(
			Array(own.get("deck", [])), AIInformationSet.HIDDEN_CARD)
		and _all_values_equal(
			Array(opponent.get("hand", [])), AIInformationSet.HIDDEN_CARD)
		and _all_values_equal(
			Array(opponent.get("deck", [])), AIInformationSet.HIDDEN_CARD)
		and _all_values_equal(
			Array(own.get("prizes", [])), AIInformationSet.HIDDEN_PRIZE)
		and _all_values_equal(
			Array(opponent.get("prizes", [])), AIInformationSet.HIDDEN_PRIZE),
		"AIInformationSet leaked a hidden hand, deck, or prize identity",
	)
	_check(
		not bool(view.get("apply_type_matchups", true))
		and not bool(Dictionary(view.get("rules_options", {})).get(
			"apply_type_matchups", true))
		and int(view.get("match_seed", 0)) == TEST_SEED
		and information_set.match_seed() == TEST_SEED,
		"AIInformationSet did not preserve the fixed seed/rules configuration",
	)
	var mutable_export := information_set.export_mutable()
	mutable_export["phase"] = "BAIT"
	var mutable_players: Array = mutable_export.get("players", [])
	if mutable_players.size() == 2:
		var mutable_own: Dictionary = mutable_players[0]
		mutable_own["hand"] = ["bait-card"]
	var fresh_view := information_set.read_only_view()
	_check(
		str(fresh_view.get("phase", "")) == "MAIN"
		and Array(Dictionary(Array(fresh_view["players"])[0]).get("hand", []))
		== ["sv1-ener-2"],
		"AIInformationSet mutable export aliases its internal public snapshot",
	)

	var sample_a := information_set.sample_state(TEST_SEED)
	var sample_b := information_set.sample_state(TEST_SEED)
	_check(sample_a != null and sample_b != null,
		"AIInformationSet could not determinize a valid public state")
	if sample_a != null and sample_b != null:
		_check(sample_a.snapshot() == sample_b.snapshot(),
			"AIInformationSet same-seed determinization is not reproducible")
		_check(
			not sample_a.apply_type_matchups
			and not bool(sample_a.rules_options.get("apply_type_matchups", true)),
			"AIInformationSet determinization re-enabled type matchups",
		)
		_check(not _contains_hidden_marker(sample_a.snapshot()),
			"AIInformationSet determinization retained hidden-zone markers")
	return information_set


func _check_semantic_catalog(catalog: CardCatalog) -> int:
	var semantic_catalog := CardSemanticCatalog.new(catalog)
	_check(not semantic_catalog.has_method("source_catalog"),
		"CardSemanticCatalog still exposes its raw CardCatalog")
	var card_ids: Array = catalog.cards.keys()
	card_ids.sort()
	var forbidden_cards: Array[String] = []
	for card_id_value in card_ids:
		var card_id := str(card_id_value)
		var semantics := semantic_catalog.semantics_for(card_id)
		if (
			not semantics.is_read_only()
			or CardSemanticCatalog.contains_forbidden_field(semantics)
		):
			forbidden_cards.append(card_id)
	_check(forbidden_cards.is_empty(), (
		"CardSemanticCatalog exposed mutable or forbidden fields for: %s"
		% ",".join(forbidden_cards.slice(0, 8))))
	var coin_attack := semantic_catalog.attack_semantics("sv1-107", 0)
	_check(
		bool(coin_attack.get("has_random_effect", false))
		and is_equal_approx(float(coin_attack.get("expected_damage", -1.0)), 15.0),
		"CardSemanticCatalog did not analytically project known coin-flip damage",
	)
	var infernape_attack := semantic_catalog.attack_semantics("svi-infr", 0)
	_check(
		bool(infernape_attack.get("has_random_effect", false)),
		"CardSemanticCatalog treated hidden top-deck Infernape damage as deterministic",
	)
	return card_ids.size()


func _check_choice_constraints(catalog: CardCatalog) -> void:
	var target_options: Array[Dictionary] = [
		{
			"option_id": "target:active",
			"label": "Active",
			"ref": EntityRef.new("pokemon", 0, "", "active").to_dict(),
		},
		{
			"option_id": "target:bench0",
			"label": "Bench",
			"ref": EntityRef.new("pokemon", 0, "", "bench:0").to_dict(),
		},
	]
	var capped := ChoiceView.new(
		"choice:capped", 17, "select_energy_target", 0, "", target_options,
		0, 3, true, true, {"max_per_target": 1})
	var capped_ids := AIChoiceSelector.select_ranked_option_ids(
		capped, [0], 3, catalog)
	_check(
		capped_ids == ["target:active"]
		and AIChoiceSelector.response_is_shape_legal(capped, capped_ids, catalog)
		and not AIChoiceSelector.response_is_shape_legal(
			capped, ["target:active", "target:active"], catalog),
		"Traditional AI bypassed max_per_target while filling an optional choice",
	)
	var same_target := ChoiceView.new(
		"choice:same", 17, "select_energy_target", 0, "", target_options,
		1, 2, true, false, {"max_per_target": 2, "same_target": true})
	var same_ids := AIChoiceSelector.select_ranked_option_ids(
		same_target, [0, 1], 2, catalog)
	_check(
		same_ids == ["target:active", "target:active"]
		and AIChoiceSelector.response_is_shape_legal(
			same_target, same_ids, catalog)
		and not AIChoiceSelector.response_is_shape_legal(
			same_target, ["target:active", "target:bench0"], catalog),
		"Traditional AI did not enforce presentation.same_target",
	)
	var category_options: Array[Dictionary] = [
		{
			"option_id": "card:pokemon",
			"label": "Pokemon",
			"ref": EntityRef.new("card", 0, "discard", "", 0, "", "svi-ente").to_dict(),
		},
		{
			"option_id": "card:energy",
			"label": "Energy",
			"ref": EntityRef.new("card", 0, "discard", "", 1, "", "sv1-ener-2").to_dict(),
		},
	]
	var categorized := ChoiceView.new(
		"choice:categories", 17, "select_cards", 0, "", category_options,
		0, 4, true, true, {"category_limits": {"pokemon": 1, "energy": 1}})
	var category_ids := AIChoiceSelector.select_ranked_option_ids(
		categorized, [0, 1], 4, catalog)
	_check(
		category_ids.size() == 2
		and AIChoiceSelector.response_is_shape_legal(
			categorized, category_ids, catalog),
		"Traditional AI did not enforce public category limits",
	)


func _check_information_context_and_cache(
	state: GameState,
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	var query := engine.query_legal_action_groups(state, 0)
	_check(query.success, "Information-context legal query failed")
	if not query.success:
		return
	var legal: Array[GameAction] = []
	legal.assign(query.concrete_actions())
	var information := AIInformationSet.capture(
		state,
		0,
		catalog,
		legal,
		[{
			"turn_number": state.turn_number,
			"revision": state.revision,
			"actor": 1,
			"kind": "DECLARE_ATTACK",
			"card_id": "sv2-grex",
			"event_type": "attack_declared",
			"private_choice": "must-not-cross",
			"resolution_stack": {"private": true},
		}],
	)
	var view := information.read_only_view()
	var legal_rows: Array = view.get("legal_actions", [])
	var history: Array = view.get("public_history", [])
	_check(
		legal_rows.is_read_only()
		and history.is_read_only()
		and not legal_rows.is_empty()
		and history.size() == 1
		and not Dictionary(history[0]).has("card_id")
		and not JSON.stringify(history).contains("must-not-cross")
		and not JSON.stringify(history).contains("resolution_stack")
		and information.legal_action_summaries().is_read_only()
		and information.public_history().is_read_only(),
		"AIInformationSet did not expose read-only, safely projected action/history context",
	)
	var nonterminal: Array[GameAction] = []
	for action in legal:
		if not action.terminal:
			nonterminal.append(action)
	if nonterminal.is_empty() or legal.size() < 2:
		_check(false, "Cache fixture lacks two actions with a nonterminal first step")
		return
	var first := nonterminal[0]
	var second: GameAction = legal[0] if legal[0] != first else legal[1]
	var precondition := information.cache_precondition()
	var first_step := TraditionalTurnPlanner.action_intent(first)
	var second_step := TraditionalTurnPlanner.action_intent(second)
	for key in ["expected_public_fingerprint", "expected_actor", "expected_phase"]:
		first_step[key] = precondition[key]
		second_step[key] = precondition[key]
	var worker := NativeChallengeAI.new()
	var cache_key := "contract-cache"
	worker._store_turn_plan(
		cache_key, state.revision - 1, [first_step, second_step], first)
	var hit := worker._take_cached_turn_action(
		cache_key, state.revision, legal, information)
	_check(
		hit != null
		and _intent_signature(hit) == _intent_signature(second),
		"Turn-plan cache rejected a matching public-state precondition",
	)
	worker._store_turn_plan(
		cache_key, state.revision - 1, [first_step, second_step], first)
	var changed_state := state.clone_state()
	changed_state.phase = "ATTACK"
	var changed_information := AIInformationSet.capture(
		changed_state, 0, catalog, legal)
	var stale := worker._take_cached_turn_action(
		cache_key, state.revision, legal, changed_information)
	_check(stale == null,
		"Turn-plan cache survived a mismatched public-state fingerprint/phase")


func _check_search_hot_path_contract(
	state: GameState,
	catalog: CardCatalog,
) -> void:
	var engine := GameEngine.new(catalog)
	var ephemeral := engine.query_legal_action_groups_ephemeral(state, 0)
	_check(ephemeral.success,
		"Native ephemeral legal-action query failed")
	var cached := engine.query_legal_action_groups(state, 0)
	_check(
		cached.success
		and ephemeral.to_dict() == cached.to_dict(),
		"Ephemeral legal-action query changed action content or ordering",
	)
	if not ephemeral.success:
		return
	var legal: Array[GameAction] = []
	legal.assign(ephemeral.concrete_actions())
	if legal.is_empty():
		_check(false, "Search hot-path fixture has no legal actions")
		return
	var history := [{
		"turn_number": state.turn_number,
		"revision": state.revision,
		"actor": 1,
		"kind": "END_TURN",
		"event_type": "turn_ended",
	}]
	var full := AIInformationSet.capture(
		state, 0, catalog, [legal[0]], history, TEST_SEED)
	var view_only := AIInformationSet.capture_view_only(
		state, 0, catalog, [], history, TEST_SEED)
	var derived_view := view_only.read_only_view_for_legal_actions([legal[0]])
	var shared_view := view_only.shared_read_only_view()
	_check(
		full.is_valid()
		and view_only.is_valid()
		and derived_view == full.read_only_view()
		and shared_view == view_only.read_only_view()
		and shared_view.is_read_only()
		and Array(shared_view.get("players", [])).is_read_only()
		and derived_view.is_read_only()
		and Array(derived_view.get("legal_actions", [])).is_read_only()
		and view_only.sample_state(TEST_SEED) == null,
		"View-only projection diverged from the full information-set public view",
	)
	var setup_state := state.clone_state()
	setup_state.phase = "SETUP"
	setup_state.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	setup_state.setup_actor_idx = 1
	setup_state.setup_bonus_card_ids = [
		["sv1-ener-2"],
		["sv1-ener-3"],
	]
	var setup_before := setup_state.snapshot()
	var setup_views_match := true
	for perspective in [0, 1]:
		var setup_full := AIInformationSet.capture(
			setup_state, perspective, catalog, [legal[0]], history, TEST_SEED)
		var setup_view_only := AIInformationSet.capture_view_only(
			setup_state, perspective, catalog, [legal[0]], history, TEST_SEED)
		setup_views_match = (
			setup_views_match
			and setup_full.is_valid()
			and setup_view_only.is_valid()
			and setup_full.read_only_view() == setup_view_only.read_only_view()
		)
	_check(
		setup_views_match and setup_state.snapshot() == setup_before,
		"View-only setup projection diverged by perspective or mutated its source",
	)
	var action_count := mini(3, legal.size())
	var actions: Array[GameAction] = []
	actions.assign(legal.slice(0, action_count))
	var observed_kinds: Array[String] = []
	var views_were_read_only := true
	var strategy := {
		"action_score": func(
			view: Dictionary,
			_action: Dictionary,
			_semantics: Dictionary,
		) -> float:
			var rows: Array = view.get("legal_actions", [])
			if (
				not view.is_read_only()
				or not rows.is_read_only()
				or rows.size() != 1
			):
				views_were_read_only = false
			observed_kinds.append(
				str(Dictionary(rows[0]).get("kind", ""))
				if rows.size() == 1
				else ""
			)
			return 0.0,
	}
	var ranked := AIPositionEvaluator.ranked_actions(
		state,
		0,
		actions,
		strategy,
		CardSemanticCatalog.new(catalog),
		catalog,
		TEST_SEED,
	)
	var expected_kinds: Array[String] = []
	for action in actions:
		expected_kinds.append(action.kind)
	_check(
		ranked.size() == actions.size()
		and views_were_read_only
		and observed_kinds == expected_kinds,
		"Batch action scoring did not preserve one-action read-only strategy views",
	)
	var seen: Dictionary = {}
	var best_complete: Dictionary = {}
	var best_partial: Dictionary = {}
	var retained_state := state.clone_state()
	var accepted := AITurnBeamPlanner._record_node(
		{
			"state": retained_state,
			"root_signature": "root",
			"state_fingerprint": "state",
			"sequence_signature": "action:a",
			"score_milli": 1,
			"depth": 1,
			"ended": false,
		},
		best_complete,
		best_partial,
		seen,
	)
	var seen_summary: Dictionary = seen.get("root|state", {})
	_check(
		accepted
		and not seen_summary.has("state")
		and seen_summary.get("sequence_signature") == "action:a",
		"Beam de-duplication retained a discarded full search state",
	)
	var fingerprint_state := state.clone_state()
	fingerprint_state.action_log.assign(["ignored-log"])
	fingerprint_state.processed_action_ids.assign(["ignored-action"])
	fingerprint_state.revision = 91
	fingerprint_state.choice_sequence = 37
	fingerprint_state.resolution_stack = {
		"schema_version": 3,
		"frames": [{"private": "ignored"}],
		"pending_request": {"request_id": "ignored"},
		"sequence": 9,
		"context": {"ignored": true},
	}
	var legacy_payload := fingerprint_state.to_dict()
	legacy_payload.erase("action_log")
	legacy_payload.erase("processed_action_ids")
	legacy_payload.erase("revision")
	legacy_payload.erase("choice_sequence")
	legacy_payload["resolution_stack"] = {}
	var legacy_state_wire := _legacy_stable_variant_signature(legacy_payload)
	var optimized_state_wire := AIPositionEvaluator.stable_variant_signature(
		legacy_payload)
	_check(
		optimized_state_wire == legacy_state_wire,
		"Optimized recursive state signature changed the frozen canonical wire",
	)
	var legacy_fingerprint := legacy_state_wire.sha256_text()
	_check(
		AITurnBeamPlanner._state_fingerprint(fingerprint_state)
			== legacy_fingerprint,
		"Direct beam-state fingerprint diverged from the frozen canonical wire",
	)


func _check_hot_path_string_wire_equivalence() -> void:
	var values: Array[String] = [
		"",
		"plain-ascii",
		"percent:%s|pipe",
		"first line\nsecond line",
		"宝可梦-é-Δ",
		"escaped-nul:" + "\\u0000" + ":tail",
	]
	for left in values:
		for right in values:
			var legacy_signature_wire := "%s|%s" % [left, right]
			var direct_signature_wire := left + "|" + right
			_check(
				direct_signature_wire == legacy_signature_wire,
				"Typed sequence/seen signature concatenation changed the frozen wire",
			)

	for previous_hash in values:
		for event in values:
			var trajectory := {
				"hash": previous_hash,
				"events": 0,
			}
			var legacy_trace_wire := "%s\n%s" % [previous_hash, event]
			AITurnBeamPlanner._trace_event(trajectory, event)
			_check(
				str(trajectory.get("hash", ""))
					== legacy_trace_wire.sha256_text()
				and int(trajectory.get("events", -1)) == 1,
				"Typed trace concatenation changed the frozen trace wire",
			)

	var rolling_hash := "turn_beam_v2:trajectory:v1".sha256_text()
	var rolling_trajectory := {
		"hash": rolling_hash,
		"events": 0,
	}
	for event_index in range(values.size()):
		var event := values[event_index]
		rolling_hash = ("%s\n%s" % [rolling_hash, event]).sha256_text()
		AITurnBeamPlanner._trace_event(rolling_trajectory, event)
		_check(
			str(rolling_trajectory.get("hash", "")) == rolling_hash
			and int(rolling_trajectory.get("events", -1)) == event_index + 1,
			"Typed trace concatenation changed the rolling trajectory hash",
		)


func _check_trace_format_wire_equivalence() -> void:
	var numbers: Array[int] = [
		-2147483648,
		-1,
		0,
		1,
		8,
		2147483647,
	]
	var flags: Array[bool] = [false, true]
	var values: Array[String] = [
		"",
		"plain-ascii",
		"percent:%s|pipe",
		"first line\nsecond line",
		"宝可梦-é-Δ",
	]
	for number in numbers:
		for flag in flags:
			var flag_text := str(flag)
			for value in values:
				var action_hash := value.sha256_text()
				var wires: Array[Dictionary] = [
					{
						"legacy": "seed=%d|roots=%s" % [number, value],
						"direct": "seed=" + str(number) + "|roots=" + value,
					},
					{
						"legacy": "root=%d|%s|failed" % [number, value],
						"direct":
							"root=" + str(number) + "|" + value + "|failed",
					},
					{
						"legacy": (
							"root=%d|%s|state=%s|ended=%s|score=%d" % [
								number,
								value,
								value,
								flag_text,
								number,
							]
						),
						"direct": (
							"root=" + str(number)
							+ "|" + value
							+ "|state=" + value
							+ "|ended=" + flag_text
							+ "|score=" + str(number)
						),
					},
					{
						"legacy": (
							"depth=%d|root=%s|parent=%s|action=%s|failed" % [
								number,
								value,
								value,
								value,
							]
						),
						"direct": (
							"depth=" + str(number)
							+ "|root=" + value
							+ "|parent=" + value
							+ "|action=" + value
							+ "|failed"
						),
					},
					{
						"legacy": (
							"depth=%d|root=%s|parent=%s|action=%s|state=%s|ended=%s|score=%d" % [
								number,
								value,
								value,
								value,
								value,
								flag_text,
								number,
							]
						),
						"direct": (
							"depth=" + str(number)
							+ "|root=" + value
							+ "|parent=" + value
							+ "|action=" + value
							+ "|state=" + value
							+ "|ended=" + flag_text
							+ "|score=" + str(number)
						),
					},
					{
						"legacy": "reply_yield|state=%s" % value,
						"direct": "reply_yield|state=" + value,
					},
					{
						"legacy": (
							"reply_depth=%d|deck=%s|action=%s|failed" % [
								number,
								value,
								value,
							]
						),
						"direct": (
							"reply_depth=" + str(number)
							+ "|deck=" + value
							+ "|action=" + value
							+ "|failed"
						),
					},
					{
						"legacy": (
							"reply_depth=%d|deck=%s|action=%s|state=%s|ended=%s|score=%d" % [
								number,
								value,
								value,
								value,
								flag_text,
								number,
							]
						),
						"direct": (
							"reply_depth=" + str(number)
							+ "|deck=" + value
							+ "|action=" + value
							+ "|state=" + value
							+ "|ended=" + flag_text
							+ "|score=" + str(number)
						),
					},
					{
						"legacy": "action:%s" % action_hash,
						"direct": "action:" + action_hash,
					},
					{
						"legacy": "other:%s" % value,
						"direct": "other:" + value,
					},
				]
				for wire_value in wires:
					var wire: Dictionary = wire_value
					var legacy_wire := str(wire.get("legacy", ""))
					var direct_wire := str(wire.get("direct", ""))
					_check(
						direct_wire.to_utf8_buffer()
							== legacy_wire.to_utf8_buffer(),
						"Typed trace/action prefix changed the frozen UTF-8 wire",
					)


func _check_stable_variant_signature_wire_equivalence() -> void:
	var signature_sequence: Array = [
		GameAction.create(
			"PLAY_TRAINER",
			{"note": "宝可梦\n%s|pipe"},
			0,
			null,
			null,
			"action|一",
			17,
		),
		"ignored non-action",
		GameAction.create(
			"END_TURN",
			{"flag": true, "score": -17},
			1,
			null,
			null,
			"action\n%二",
			23,
		),
	]
	var legacy_sequence_wire := _legacy_sequence_signature(signature_sequence)
	var packed_sequence_wire := AIPositionEvaluator.sequence_signature(
		signature_sequence)
	_check(
		packed_sequence_wire.to_utf8_buffer()
			== legacy_sequence_wire.to_utf8_buffer(),
		"Packed sequence signature changed the frozen UTF-8 wire",
	)
	var values: Array = [
		null,
		false,
		true,
		0,
		-17,
		1.25,
		"",
		"plain-ascii",
		"percent:%s|pipe",
		"first line\nsecond line",
		"宝可梦-é-Δ",
		"escaped-nul:" + "\\u0000" + ":tail",
		[],
		[null, false, 7, "nested\narray", ["deep", "%s", "\\u0000"]],
		{},
		{
			"z-last": [3, 2, 1],
			"a-first": {
				"equals=comma,braces{}[]": "宝可梦\n" + "\\u0000",
				"percent": "%s",
			},
			"键\n%s": ["line\nbreak", true, -17],
		},
	]
	for value in values:
		var legacy_wire := _legacy_stable_variant_signature(value)
		var optimized_wire := AIPositionEvaluator.stable_variant_signature(value)
		_check(
			optimized_wire == legacy_wire,
			"Optimized recursive variant signature changed the frozen wire",
		)


func _legacy_sequence_signature(sequence_value: Variant) -> String:
	var parts: Array[String] = []
	for action_value in sequence_value:
		if action_value is GameAction:
			parts.append(AIPositionEvaluator.action_signature(action_value))
	return "|".join(parts)


func _legacy_stable_variant_signature(value: Variant) -> String:
	if value is Dictionary:
		var dictionary: Dictionary = value
		var keys: Array[String] = []
		for key_value in dictionary:
			keys.append(str(key_value))
		keys.sort()
		var parts: Array[String] = []
		for key in keys:
			parts.append("%s=%s" % [
				key,
				_legacy_stable_variant_signature(dictionary[key]),
			])
		return "{%s}" % ",".join(parts)
	if value is Array:
		var parts: Array[String] = []
		for item in value:
			parts.append(_legacy_stable_variant_signature(item))
		return "[%s]" % ",".join(parts)
	return JSON.stringify(value)


func _check_search_action_apply_equivalence(catalog: CardCatalog) -> void:
	var deterministic_state := _planner_state()
	deterministic_state.set_type_matchups_enabled(false)
	var deterministic_query := GameEngine.new(
		catalog).query_legal_action_groups_ephemeral(deterministic_state, 0)
	var deterministic_action: GameAction = null
	if deterministic_query.success:
		for candidate in deterministic_query.concrete_actions():
			if candidate.kind not in ["PLAY_TRAINER", "RETREAT"]:
				deterministic_action = candidate
				break
	_check(
		deterministic_action != null
		and _search_apply_paths_match(
			deterministic_state,
			deterministic_action,
			catalog,
			TEST_SEED + 3101,
			true,
		).get("equal", false),
		"Search-only action apply changed a deterministic legal transition",
	)

	# A stale envelope exercises the disposable failure result. It still takes
	# the full validation path and must be indistinguishable from public apply.
	if deterministic_action != null:
		var stale_action := GameAction.from_dict(deterministic_action.to_dict())
		stale_action.base_revision += 1
		var failed_pair := _search_apply_paths_match(
			deterministic_state,
			stale_action,
			catalog,
			TEST_SEED + 3102,
			false,
		)
		_check(
			bool(failed_pair.get("equal", false))
			and not bool(Dictionary(failed_pair.get(
				"normal_step", {})).get("success", true)),
			"Disposable search failure changed rollback-visible StepResult state",
		)

	# Coin outcomes and the local RNG state must remain byte-for-byte equal.
	var random_state := _planner_state()
	random_state.set_type_matchups_enabled(false)
	random_state.public_deck_keys = ["water", "fire"]
	random_state.players[0].active = PokemonState.new("sv2-38")
	random_state.players[0].active.placed_this_turn = false
	random_state.players[0].active.energy_card_ids.assign(["sv1-ener-3"])
	random_state.players[0].hand.clear()
	random_state.players[1].active = PokemonState.new("svi-ente")
	random_state.players[1].active.placed_this_turn = false
	var random_action := _first_action_of_kind(
		GameEngine.new(catalog), random_state, 0, "DECLARE_ATTACK", 0)
	var random_pair := _search_apply_paths_match(
		random_state, random_action, catalog, TEST_SEED + 3103, true)
	_check(
		random_action != null
		and bool(random_pair.get("equal", false))
		and JSON.stringify(Dictionary(random_pair.get(
			"normal_step", {}))).contains("coin"),
		"Search-only action apply changed a seeded random transition",
	)

	# A guaranteed KO covers knockout settlement and a pending Prize continuation.
	var knockout_state := _colorless_pre_knockout_state(6, "sv2-38", 1)
	knockout_state.revision = 41
	knockout_state.players[1].active.damage_counters = 6
	var knockout_action := _first_action_of_kind(
		GameEngine.new(catalog), knockout_state, 0, "DECLARE_ATTACK", 1)
	var knockout_pair := _search_apply_paths_match(
		knockout_state, knockout_action, catalog, TEST_SEED + 3104, true)
	_check(
		knockout_action != null
		and bool(knockout_pair.get("equal", false)),
		"Search-only action apply changed KO/Prize continuation settlement",
	)

	# Trainer actions keep the full pre-action checkpoint. Cancelling their first
	# Choice must therefore restore exactly the same state, events and RNG.
	var trainer_state := _planner_state()
	trainer_state.set_type_matchups_enabled(false)
	trainer_state.turn_number = 8
	trainer_state.public_deck_keys = ["lightning", "water"]
	trainer_state.players[0].supporter_played_this_turn = false
	trainer_state.players[0].hand = ["svi-cait", "svl-lant"]
	trainer_state.players[0].deck = [
		"svl-pikaex", "svl-flaa2", "svl-thun", "sv1-ener-4",
	]
	var trainer_engine := GameEngine.new(catalog)
	var trainer_action: GameAction = null
	var trainer_query := trainer_engine.query_legal_action_groups_ephemeral(
		trainer_state, 0)
	if trainer_query.success:
		for candidate in trainer_query.concrete_actions():
			if (
				candidate.kind == "PLAY_TRAINER"
				and candidate.source != null
				and candidate.source.card_id == "svi-cait"
			):
				trainer_action = candidate
				break
	var normal_trainer_state := trainer_state.clone_state()
	var search_trainer_state: GameState = null
	var normal_trainer_rng := PortableRandomSource.new(TEST_SEED + 3105)
	var search_trainer_rng := PortableRandomSource.new(TEST_SEED + 3105)
	var normal_trainer_step: StepResult = null
	var search_trainer_step: StepResult = null
	if trainer_action != null:
		normal_trainer_step = trainer_engine.apply_action(
			normal_trainer_state, trainer_action, normal_trainer_rng)
		var search_applied := trainer_engine.apply_search_action_ephemeral(
			trainer_state, trainer_action, search_trainer_rng)
		search_trainer_state = search_applied.get("state")
		search_trainer_step = search_applied.get("step")
	var trainer_started_equal := _steps_and_states_match(
		normal_trainer_step,
		search_trainer_step,
		normal_trainer_state,
		search_trainer_state,
		normal_trainer_rng,
		search_trainer_rng,
	)
	var trainer_cancelled_equal := false
	if (
		trainer_started_equal
		and normal_trainer_step.pending_choice != null
		and search_trainer_step.pending_choice != null
	):
		var normal_cancelled := trainer_engine.apply_choice_response(
			normal_trainer_state,
			ChoiceResponse.new(
				normal_trainer_step.pending_choice.request_id, [], true),
			normal_trainer_rng,
		)
		var search_cancelled := trainer_engine.apply_choice_response(
			search_trainer_state,
			ChoiceResponse.new(
				search_trainer_step.pending_choice.request_id, [], true),
			search_trainer_rng,
		)
		trainer_cancelled_equal = _steps_and_states_match(
			normal_cancelled,
			search_cancelled,
			normal_trainer_state,
			search_trainer_state,
			normal_trainer_rng,
			search_trainer_rng,
		)
	_check(
		trainer_action != null
		and trainer_started_equal
		and trainer_cancelled_equal,
		"Search-only action apply lost Trainer Choice cancellation rollback",
	)

	# A same-revision action that was not returned by the native legal query must
	# still fail closed. The binding facade canonicalizes against ptcg_core before
	# submitting the action; there is no GDScript preflight-proof cache anymore.
	var setup_state := _planner_state()
	setup_state.phase = "SETUP"
	setup_state.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	setup_state.setup_actor_idx = 0
	setup_state.setup_ready = [false, false]
	var proof_engine := GameEngine.new(catalog)
	var setup_query := proof_engine.query_legal_action_groups_ephemeral(
		setup_state, 0)
	var forged_end := GameAction.create(
		"END_TURN",
		{},
		0,
		null,
		null,
		"forged-setup-end-turn",
		setup_state.revision,
	)
	var forged_result := proof_engine.apply_search_action_ephemeral(
		setup_state,
		forged_end,
		PortableRandomSource.new(TEST_SEED + 3106),
	)
	var forged_step: StepResult = forged_result.get("step")
	_check(
		setup_query.success
		and forged_end.terminal
		and forged_step != null
		and not forged_step.success,
		"Forged same-revision SETUP END_TURN bypassed native legality",
	)
	var malformed_choice_state := _planner_state()
	malformed_choice_state.resolution_stack["pending_request"] = {
		"request_id": "malformed-player",
		"player": 7,
	}
	_check(
		not AITurnBeamPlanner._resolve_choices(
			malformed_choice_state,
			0,
			GameEngine.new(catalog),
			null,
			CardSemanticCatalog.new(catalog),
			PortableRandomSource.new(TEST_SEED + 3107),
			Callable(),
			TEST_SEED,
		),
		"Malformed pending Choice player was treated as an empty Choice stack",
	)


func _search_apply_paths_match(
	source_state: GameState,
	action: GameAction,
	catalog: CardCatalog,
	seed: int,
	use_query_proof: bool,
) -> Dictionary:
	if source_state == null or action == null:
		return {"equal": false, "normal_step": {}}
	var engine := GameEngine.new(catalog)
	var normal_state := source_state.clone_state()
	var normal_rng := PortableRandomSource.new(seed)
	var search_rng := PortableRandomSource.new(seed)
	var normal_step := engine.apply_action(normal_state, action, normal_rng)
	var normal_query := engine.query_legal_action_groups(source_state, action.actor)
	var ephemeral_query: LegalActionQueryResult = null
	if use_query_proof:
		ephemeral_query = engine.query_legal_action_groups_ephemeral(
			source_state, action.actor)
	var search_applied := engine.apply_search_action_ephemeral(
		source_state, action, search_rng)
	var search_state: GameState = search_applied.get("state")
	var search_step: StepResult = search_applied.get("step")
	return {
		"equal": (
			normal_query.success
			and (
				not use_query_proof
				or (
					ephemeral_query != null
					and ephemeral_query.success
					and ephemeral_query.to_dict() == normal_query.to_dict()
				)
			)
			and _steps_and_states_match(
				normal_step,
				search_step,
				normal_state,
				search_state,
				normal_rng,
				search_rng,
			)
		),
		"normal_step": normal_step.to_dict() if normal_step != null else {},
	}


func _steps_and_states_match(
	normal_step: StepResult,
	search_step: StepResult,
	normal_state: GameState,
	search_state: GameState,
	normal_rng: PortableRandomSource,
	search_rng: PortableRandomSource,
) -> bool:
	return (
		normal_step != null
		and search_step != null
		and normal_step.to_dict() == search_step.to_dict()
		and normal_state.snapshot() == search_state.snapshot()
		and normal_rng.get_state() == search_rng.get_state()
	)


func _first_action_of_kind(
	engine: GameEngine,
	state: GameState,
	actor: int,
	kind: String,
	attack_index: int = -1,
) -> GameAction:
	var query := engine.query_legal_action_groups_ephemeral(state, actor)
	if not query.success:
		return null
	for action in query.concrete_actions():
		if action.kind != kind:
			continue
		if (
			attack_index >= 0
			and int(action.payload.get("attack_index", -1)) != attack_index
		):
			continue
		return action
	return null


func _check_strategy_registry(
	information_set: AIInformationSet,
) -> AIStrategyRegistry:
	var registry := AIStrategyRegistry.new()
	_check(registry.is_valid(), (
		"AIStrategyRegistry is invalid: %s" % JSON.stringify(
			registry.validation_errors())))
	_check(registry.known_deck_keys() == RELEASE_DECK_KEYS,
		"AIStrategyRegistry does not cover the ten release decks")
	_check(registry.catalog_hash().length() == 64,
		"AIStrategyRegistry catalog hash is missing")
	var ids: Dictionary = {}
	var info := (
		information_set.read_only_view()
		if information_set != null and information_set.is_valid()
		else {}
	)
	for deck_key in RELEASE_DECK_KEYS:
		var strategy := registry.strategy_for(deck_key)
		var goals := strategy.turn_goals(info)
		_check(
			strategy != null
			and strategy.deck_key() == deck_key
			and not strategy.strategy_id().is_empty()
			and strategy.strategy_id() != "generic_balanced_v1"
			and str(goals.get("strategy_id", "")) == strategy.strategy_id()
			and not str(goals.get("stage", "")).is_empty(),
			"AIStrategyRegistry returned an invalid strategy for %s" % deck_key,
		)
		ids[strategy.strategy_id()] = true
	var generic := registry.strategy_for("not-a-release-deck")
	_check(
		generic is GenericDeckStrategy
		and generic.deck_key() == "generic"
		and generic.strategy_id() == "generic_balanced_v1",
		"AIStrategyRegistry unknown-deck fallback is not the generic strategy",
	)
	ids[generic.strategy_id()] = true
	_check(ids.size() == RELEASE_DECK_KEYS.size() + 1,
		"AIStrategyRegistry strategy ids are not unique across ten decks + generic")
	return registry


func _check_dragon_strategy_regressions(registry: AIStrategyRegistry) -> void:
	if not registry.is_valid():
		return
	var strategy := registry.strategy_for("dragon")
	var split_energy_info := {
		"perspective": 0,
		"turn_number": 5,
		"players": [
			{
				"active": {
					"card_id": "svg-alt",
					"damage_counters": 0,
					"energy_card_ids": ["sv1-ener-3"],
				},
				"bench": [{
					"card_id": "svg-alt",
					"damage_counters": 0,
					"energy_card_ids": ["sv1-ener-8"],
				}],
				"hand": [],
				"prizes_remaining": 6,
			},
			{"active": {}, "bench": [], "hand": [], "prizes_remaining": 6},
		],
	}
	_check(
		strategy.plan_stage(split_energy_info) == "balance_energy",
		"Dragon strategy combined Water/Metal Energy from different Altaria",
	)
	var balanced_info: Dictionary = split_energy_info.duplicate(true)
	balanced_info["players"][0]["active"]["energy_card_ids"] = [
		"sv1-ener-3", "sv1-ener-8",
	]
	_check(
		strategy.plan_stage(balanced_info) == "healing_lock",
		"Dragon strategy did not recognize dual Energy on one Altaria",
	)

	var balance_attachment := {
		"kind": "ATTACH_ENERGY",
		"card_id": "sv1-ener-3",
		"target_card_id": "svg-alt",
		"target": {"player": 0, "slot": "bench_0", "card_id": "svg-alt"},
	}
	var duplicate_attachment := balance_attachment.duplicate(true)
	duplicate_attachment["target"] = {
		"player": 0, "slot": "active", "card_id": "svg-alt",
	}
	_check(
		strategy.action_score(split_energy_info, balance_attachment)
		> strategy.action_score(split_energy_info, duplicate_attachment),
		"Dragon strategy did not score dual Energy on the targeted Altaria",
	)

	var healthy_info := balanced_info.duplicate(true)
	healthy_info["players"][0]["bench"] = []
	var damaged_info: Dictionary = healthy_info.duplicate(true)
	damaged_info["players"][0]["active"]["damage_counters"] = 4
	_check(
		strategy.state_score(damaged_info) < strategy.state_score(healthy_info),
		"Dragon strategy positively rewarded residual damage on its own board",
	)


func _check_shared_strategy_scoring_regressions(
	registry: AIStrategyRegistry,
) -> void:
	if not registry.is_valid():
		return
	var generic := registry.strategy_for("custom-deck")
	var neutral := {
		"perspective": 0,
		"players": [
			{"active": {}, "bench": [], "hand": [], "prizes_remaining": 6},
			{"active": {}, "bench": [], "hand": [], "prizes_remaining": 6},
		],
	}
	var own_closeout: Dictionary = neutral.duplicate(true)
	own_closeout["players"][0]["prizes_remaining"] = 2
	var opponent_closeout: Dictionary = neutral.duplicate(true)
	opponent_closeout["players"][1]["prizes_remaining"] = 2
	_check(
		generic.state_score(own_closeout) > generic.state_score(neutral)
		and generic.state_score(opponent_closeout) < generic.state_score(neutral),
		"Deck strategy closeout score has the prize-count sign reversed",
	)

	var grass := registry.strategy_for("grass")
	var fill_info := {
		"perspective": 0,
		"turn_number": 1,
		"players": [
			{
				"active": {"card_id": "svg2-zaru", "energy_card_ids": []},
				"bench": [], "hand": [], "prizes_remaining": 6,
			},
			{"active": {}, "bench": [], "hand": [], "prizes_remaining": 6},
		],
	}
	var attack_progress := grass.stage_goal_action_adjustment(
		fill_info, {"kind": "DECLARE_ATTACK", "card_id": "svg2-zaru"})
	var basic_progress := grass.stage_goal_action_adjustment(
		fill_info, {"kind": "PLAY_BASIC", "card_id": "svg2-turt"})
	_check(
		is_zero_approx(attack_progress)
		and basic_progress > 0.0
		and basic_progress <= DeckStrategy.MAX_STAGE_ACTION_SCORE,
		"Stage goals count attacks as board development or exceed their cap",
	)
	var energy_choice := {
		"request_type": "select_energy_target",
		"presentation": {"purpose": "attach_energy", "card_id": "sv1-ener-1"},
	}
	_check(
		is_zero_approx(grass.choice_option_score(
			fill_info, energy_choice, {"card_id": "svg2-tort"}))
		and is_zero_approx(grass.choice_option_score(
			fill_info, energy_choice, {"card_id": "svg2-turt"})),
		"Deck search-role weights leaked into Energy target choices",
	)

	var fire := registry.strategy_for("fire")
	var fire_opening: Dictionary = fill_info.duplicate(true)
	fire_opening["players"][0]["active"] = {}
	fire_opening["players"][0]["hand"] = ["svi-ente", "svi-chiy"]
	var chiyu_active := {
		"kind": "PLAY_BASIC", "card_id": "svi-chiy",
		"target": {"player": 0, "slot": "active", "card_id": "svi-chiy"},
	}
	var entei_active := {
		"kind": "PLAY_BASIC", "card_id": "svi-ente",
		"target": {"player": 0, "slot": "active", "card_id": "svi-ente"},
	}
	_check(
		fire.action_score(fire_opening, chiyu_active)
		> fire.action_score(fire_opening, entei_active),
		"Fire strategy opened Entei over the immediately useful Chi-Yu engine",
	)
	var fire_lone_active: Dictionary = fill_info.duplicate(true)
	fire_lone_active["players"][0]["active"] = {
		"card_id": "svi-chim", "energy_card_ids": ["sv1-ener-2"],
	}
	var fire_search_choice := {
		"request_type": "select_cards",
		"presentation": {"purpose": "search"},
	}
	_check(
		fire.choice_score(
			fire_lone_active, fire_search_choice, {"card_id": "svi-chiy"})
		> fire.choice_score(
			fire_lone_active, fire_search_choice, {"card_id": "svi-monf"}),
		"Fire strategy searched a stranded evolution over a lone-Active Basic backup",
	)


func _check_water_psychic_strategy_regressions(
	registry: AIStrategyRegistry,
) -> void:
	if not registry.is_valid():
		return
	var base_info := {
		"perspective": 0,
		"first_player_idx": 1,
		"turn_number": 1,
		"players": [
			{
				"active": {}, "bench": [], "hand": [],
				"discard": [], "prizes_remaining": 6,
			},
			{
				"active": {}, "bench": [], "hand": [],
				"discard": [], "prizes_remaining": 6,
			},
		],
	}

	var water := registry.strategy_for("water")
	var tatsugiri_active := {
		"kind": "PLAY_BASIC",
		"card_id": "sv2-tatsu",
		"target": {"player": 0, "slot": "active", "card_id": "sv2-tatsu"},
	}
	var water_first: Dictionary = base_info.duplicate(true)
	water_first["first_player_idx"] = 0
	_check(
		water.action_score(base_info, tatsugiri_active)
		> water.action_score(water_first, tatsugiri_active),
		"Water strategy applied the Tatsugiri going-second opening bonus when going first",
	)
	var candy_ready: Dictionary = base_info.duplicate(true)
	candy_ready["players"][0]["active"] = {
		"card_id": "sv2-38", "energy_card_ids": [],
	}
	candy_ready["players"][0]["hand"] = ["sv1-152", "sv2-grex"]
	var candy_unready: Dictionary = candy_ready.duplicate(true)
	candy_unready["players"][0]["hand"] = ["sv1-152"]
	var rare_candy := {"kind": "PLAY_TRAINER", "card_id": "sv1-152"}
	_check(
		water.action_score(candy_ready, rare_candy)
		> water.action_score(candy_unready, rare_candy),
		"Water strategy did not preserve the public Rare Candy to Greninja route",
	)
	var no_staryu: Dictionary = base_info.duplicate(true)
	var starmie_choice := {"card_id": "sv2-starm"}
	var greninja_choice := {"card_id": "sv2-grex"}
	var search_choice := {
		"request_type": "select_cards",
		"presentation": {"purpose": "search"},
	}
	_check(
		water.choice_option_score(no_staryu, search_choice, greninja_choice)
		> water.choice_option_score(no_staryu, search_choice, starmie_choice),
		"Water strategy searched an unexecutable Starmie over Greninja",
	)

	var psychic := registry.strategy_for("psychic")
	var cresselia_active := {
		"kind": "PLAY_BASIC",
		"card_id": "sv1-113",
		"target": {"player": 0, "slot": "active", "card_id": "sv1-113"},
	}
	var psychic_first: Dictionary = base_info.duplicate(true)
	psychic_first["first_player_idx"] = 0
	_check(
		psychic.action_score(base_info, cresselia_active)
		> psychic.action_score(psychic_first, cresselia_active),
		"Psychic strategy applied Cresselia's opening acceleration bonus when going first",
	)
	var cresselia_route: Dictionary = base_info.duplicate(true)
	cresselia_route["phase"] = "MAIN"
	cresselia_route["turn_number"] = 2
	cresselia_route["active_player_idx"] = 0
	cresselia_route["players"][0]["active"] = {
		"card_id": "sv1-107", "energy_card_ids": [],
	}
	cresselia_route["players"][0]["bench"] = [{
		"card_id": "sv1-113", "energy_card_ids": ["sv1-ener-5"],
	}]
	cresselia_route["players"][0]["hand"] = ["sv1-204", "sv1-ener-5"]
	cresselia_route["players"][0]["energy_attached_this_turn"] = false
	cresselia_route["legal_actions"] = []
	var route_closed: Dictionary = cresselia_route.duplicate(true)
	route_closed["turn_number"] = 3
	var arven_action := {"kind": "PLAY_TRAINER", "card_id": "sv1-204"}
	var switch_action := {"kind": "PLAY_TRAINER", "card_id": "sv1-150"}
	var growth_action := {
		"kind": "DECLARE_ATTACK", "card_id": "sv1-113",
		"payload": {"attack_index": 0},
	}
	_check(
		psychic.action_score(cresselia_route, arven_action)
		> psychic.action_score(route_closed, arven_action)
		and psychic.action_score(cresselia_route, switch_action)
		> psychic.action_score(route_closed, switch_action)
		and psychic.action_score(cresselia_route, growth_action)
		> psychic.action_score(route_closed, growth_action),
		"Psychic strategy did not preserve the exact turn-two Cresselia route",
	)
	var xatu_setup: Dictionary = base_info.duplicate(true)
	xatu_setup["players"][0]["active"] = {
		"card_id": "sv1-104", "energy_card_ids": [],
	}
	xatu_setup["players"][0]["bench"] = [{
		"card_id": "sv1-107", "energy_card_ids": [],
	}]
	_check(
		psychic.action_score(
			xatu_setup, {"kind": "EVOLVE", "card_id": "sv1-108"})
		> psychic.action_score(
			xatu_setup, {"kind": "EVOLVE", "card_id": "sv1-106"}),
		"Psychic strategy evolved Houndstone before establishing the first Xatu",
	)
	var psychic_energy_choice := {
		"request_type": "select_energy_target",
		"presentation": {"purpose": "attach_energy", "card_id": "sv1-ener-5"},
	}
	_check(
		is_zero_approx(psychic.choice_option_score(
			xatu_setup, psychic_energy_choice, {"card_id": "sv1-107"}))
		and is_zero_approx(psychic.choice_option_score(
			xatu_setup, psychic_energy_choice, {"card_id": "sv1-111"})),
		"Psychic search roles leaked into Xatu's Energy target choice",
	)


func _check_lightning_strategy_regressions(
	registry: AIStrategyRegistry,
) -> void:
	if not registry.is_valid():
		return
	var strategy := registry.strategy_for("lightning")
	var opening_info := {
		"perspective": 0,
		"first_player_idx": 0,
		"turn_number": 1,
		"players": [
			{
				"active": {}, "bench": [],
				"hand": ["svl-mare2", "svl-zera"],
				"discard": [], "prizes_remaining": 6,
			},
			{
				"active": {}, "bench": [], "hand": [],
				"discard": [], "prizes_remaining": 6,
			},
		],
	}
	var zeraora_active := {
		"kind": "PLAY_BASIC", "card_id": "svl-zera",
		"target": {"player": 0, "slot": "active", "card_id": "svl-zera"},
	}
	var mareep_active := {
		"kind": "PLAY_BASIC", "card_id": "svl-mare2",
		"target": {"player": 0, "slot": "active", "card_id": "svl-mare2"},
	}
	_check(
		AIDeckProfiles.contains("lightning", "setup", "svl-zera")
		and strategy.action_score(opening_info, zeraora_active)
		> strategy.action_score(opening_info, mareep_active),
		"Lightning strategy opened the bench-only Mareep engine over Zeraora",
	)


func _check_trusted_dynamic_scoring(catalog: CardCatalog) -> void:
	var worker := NativeChallengeAI.new()
	var water_energy_id := "sv1-ener-3"
	var tatsugiri_attach_state := GameState.new()
	tatsugiri_attach_state.set_type_matchups_enabled(false)
	tatsugiri_attach_state.public_deck_keys = ["water", "steel"]
	tatsugiri_attach_state.players[0].active = PokemonState.new("sv2-tatsu")
	tatsugiri_attach_state.players[0].bench[0] = PokemonState.new("sv2-38")
	tatsugiri_attach_state.players[1].active = PokemonState.new("svm-orthworm")
	var tatsugiri_bridge_bonus := worker._energy_plan_target_bonus(
		tatsugiri_attach_state, 0, "active", water_energy_id, "water", catalog)
	var no_bridge_state := GameState.from_dict(tatsugiri_attach_state.snapshot())
	no_bridge_state.players[0].bench[0] = null
	var no_bridge_bonus := worker._energy_plan_target_bonus(
		no_bridge_state, 0, "active", water_energy_id, "water", catalog)
	_check(
		tatsugiri_bridge_bonus >= no_bridge_bonus + 280.0,
		"Trusted Energy plan did not unlock Tatsugiri's public Prepare bridge",
	)

	var keldeo_energy_state := GameState.new()
	keldeo_energy_state.set_type_matchups_enabled(false)
	keldeo_energy_state.public_deck_keys = ["water", "steel"]
	keldeo_energy_state.players[0].active = PokemonState.new("sv2-keldeo")
	keldeo_energy_state.players[0].active.energy_card_ids = [water_energy_id]
	for index in range(3):
		keldeo_energy_state.players[0].bench[index] = PokemonState.new("sv2-38")
	keldeo_energy_state.players[1].active = PokemonState.new("svm-orthworm")
	var queue_bonus := worker._energy_plan_target_bonus(
		keldeo_energy_state, 0, "active", water_energy_id, "water", catalog)
	var short_bench_state := GameState.from_dict(keldeo_energy_state.snapshot())
	short_bench_state.players[0].bench[2] = null
	var kick_only_bonus := worker._energy_plan_target_bonus(
		short_bench_state, 0, "active", water_energy_id, "water", catalog)
	_check(
		queue_bonus >= kick_only_bonus + 190.0,
		"Trusted Energy plan used Keldeo's already-ready first attack instead of its W+C route",
	)
	var promotion_state := GameState.new()
	promotion_state.set_type_matchups_enabled(false)
	promotion_state.public_deck_keys = ["dragon", "grass"]
	var ready_miltank := PokemonState.new("svg-milt")
	ready_miltank.energy_card_ids.assign(["sv1-ener-3", "sv1-ener-8"])
	var unready_altaria := PokemonState.new("svg-alt")
	promotion_state.players[0].active = PokemonState.new("svg-dram")
	promotion_state.players[0].bench[0] = ready_miltank
	promotion_state.players[0].bench[1] = unready_altaria
	promotion_state.players[1].active = PokemonState.new("svg2-zaru")
	_check(
		worker._promotion_value_for_state(
			promotion_state, 0, ready_miltank, "dragon", catalog)
		> worker._promotion_value_for_state(
			promotion_state, 0, unready_altaria, "dragon", catalog),
		"Promotion scoring preferred unready printed damage over a ready attacker",
	)
	var bench_torterra := PokemonState.new("svg2-tort")
	bench_torterra.evolution_stack_ids.assign(["svg2-turt", "svg2-grot"])
	bench_torterra.energy_card_ids.assign(["sv1-ener-1", "sv1-ener-1"])
	var bench_breloom := PokemonState.new("svg2-brel")
	bench_breloom.evolution_stack_ids.assign(["svg2-shro"])
	var bench_empoleon := PokemonState.new("svg2-empo")
	bench_empoleon.evolution_stack_ids.assign(["svg2-pipl"])
	var bench_damage_state := GameState.new()
	bench_damage_state.set_type_matchups_enabled(false)
	bench_damage_state.players[0].active = PokemonState.new("svg2-zaru")
	bench_damage_state.players[0].bench[0] = bench_torterra
	bench_damage_state.players[0].bench[1] = bench_breloom
	bench_damage_state.players[0].bench[2] = bench_empoleon
	bench_damage_state.players[1].active = PokemonState.new("svg-dram")
	var bench_snapshot := bench_damage_state.snapshot()
	_check(
		worker._best_ready_pokemon_damage(
			bench_damage_state, 0, bench_torterra, catalog) == 150
		and bench_damage_state.snapshot() == bench_snapshot,
		"Temporary promotion duplicated a bench attacker or mutated the state",
	)

	var torterra_state := GameState.new()
	torterra_state.set_type_matchups_enabled(false)
	var torterra := PokemonState.new("svg2-tort")
	torterra.evolution_stack_ids.assign(["svg2-turt", "svg2-grot"])
	var breloom := PokemonState.new("svg2-brel")
	breloom.evolution_stack_ids.assign(["svg2-shro"])
	var empoleon := PokemonState.new("svg2-empo")
	empoleon.evolution_stack_ids.assign(["svg2-pipl"])
	torterra_state.players[0].active = torterra
	torterra_state.players[0].bench[0] = breloom
	torterra_state.players[0].bench[1] = empoleon
	torterra_state.players[1].active = PokemonState.new("svg-dram")
	_check(
		worker._high_impact_missing_energy(
			torterra_state, 0, torterra, "", catalog) == 2
		and worker._high_impact_missing_energy(
			torterra_state, 0, torterra, "sv1-ener-1", catalog) == 1,
		"Dynamic Torterra damage did not drive high-impact Energy readiness",
	)
	torterra.energy_card_ids.assign(["sv1-ener-1"])
	var energy_option := {
		"option_id": "pokemon:0:active:svg2-tort",
		"ref": EntityRef.new(
			"pokemon", 0, "", "active", -1, "", "svg2-tort").to_dict(),
	}
	var energy_request := ChoiceView.new(
		"choice:grass-marginal", torterra_state.revision,
		"select_energy_target", 0, "", [energy_option],
		0, 2, true, true,
		{"purpose": "attach_energy", "card_id": "sv1-ener-1",
		 "same_target": true, "max_per_target": 2},
	)
	_check(
		worker._useful_energy_target_selection_count(
			torterra_state, energy_request, energy_option,
			"grass", catalog, 2) == 1,
		"Multi-Energy choice exceeded the target's public attack deficit",
	)

	var tatsugiri_state := GameState.new()
	tatsugiri_state.set_type_matchups_enabled(false)
	tatsugiri_state.public_deck_keys = ["water", "steel"]
	tatsugiri_state.players[0].active = PokemonState.new("sv2-tatsu")
	tatsugiri_state.players[0].active.energy_card_ids.append(water_energy_id)
	tatsugiri_state.players[0].bench[0] = PokemonState.new("sv2-38")
	tatsugiri_state.players[1].active = PokemonState.new("svm-orthworm")
	var froakie_option := {
		"option_id": "pokemon:0:bench_0:sv2-38",
		"ref": EntityRef.new(
			"pokemon", 0, "", "bench_0", -1, "", "sv2-38").to_dict(),
	}
	var tatsugiri_request := ChoiceView.new(
		"choice:tatsugiri-prefix", tatsugiri_state.revision,
		"select_energy_target", 0, "", [froakie_option],
		0, 2, true, true,
		{"purpose": "attach_energy", "card_ids": [water_energy_id, water_energy_id],
		 "same_target": true, "max_per_target": 2},
	)
	var tatsugiri_snapshot := tatsugiri_state.snapshot()
	var tatsugiri_info := AIInformationSet.capture(
		tatsugiri_state, 0, catalog, [], [], TEST_SEED)
	var tatsugiri_response := worker._traditional_choice_response(
		tatsugiri_state, tatsugiri_info, tatsugiri_request, "water",
		AIStrategyRegistry.new().strategy_for("water"), catalog)
	var tatsugiri_repeat := worker._traditional_choice_response(
		tatsugiri_state, tatsugiri_info, tatsugiri_request, "water",
		AIStrategyRegistry.new().strategy_for("water"), catalog)
	_check(
		worker._useful_energy_target_selection_count(
			tatsugiri_state, tatsugiri_request, froakie_option,
			"water", catalog, 2) == 2
		and tatsugiri_response != null
		and tatsugiri_response.option_ids == [
			"pokemon:0:bench_0:sv2-38", "pokemon:0:bench_0:sv2-38"]
		and tatsugiri_repeat.to_dict() == tatsugiri_response.to_dict()
		and tatsugiri_state.snapshot() == tatsugiri_snapshot,
		"Tatsugiri did not bridge two Energy to the future Greninja route",
	)
	var hidden_route_a := GameState.from_dict(tatsugiri_state.snapshot())
	hidden_route_a.players[0].deck.assign(["sv2-grex", "sv2-cand"])
	hidden_route_a.players[0].prizes.assign([water_energy_id])
	var hidden_route_b := GameState.from_dict(hidden_route_a.snapshot())
	hidden_route_b.players[0].deck.assign([water_energy_id, "sv2-cand"])
	hidden_route_b.players[0].prizes.assign(["sv2-grex"])
	var hidden_info_a := AIInformationSet.capture(
		hidden_route_a, 0, catalog, [], [], TEST_SEED)
	var hidden_info_b := AIInformationSet.capture(
		hidden_route_b, 0, catalog, [], [], TEST_SEED)
	var hidden_response_a := worker._traditional_choice_response(
		hidden_route_a, hidden_info_a, tatsugiri_request, "water",
		AIStrategyRegistry.new().strategy_for("water"), catalog)
	var hidden_response_b := worker._traditional_choice_response(
		hidden_route_b, hidden_info_b, tatsugiri_request, "water",
		AIStrategyRegistry.new().strategy_for("water"), catalog)
	_check(
		hidden_response_a != null
		and hidden_response_b != null
		and hidden_response_a.to_dict() == hidden_response_b.to_dict(),
		"Hidden Greninja deck/Prize placement changed Tatsugiri's public route",
	)

	var psychic_energy_id := "sv1-ener-5"
	var arven_state := GameState.new()
	arven_state.set_type_matchups_enabled(false)
	arven_state.public_deck_keys = ["psychic", "steel"]
	arven_state.phase = "MAIN"
	arven_state.turn_number = 2
	arven_state.active_player_idx = 0
	arven_state.first_player_idx = 1
	arven_state.players[0].active = PokemonState.new("sv1-107")
	arven_state.players[0].bench[0] = PokemonState.new("sv1-113")
	arven_state.players[0].bench[0].energy_card_ids.append(psychic_energy_id)
	arven_state.players[1].active = PokemonState.new("svm-orthworm")
	var arven_options: Array[Dictionary] = [
		{
			"option_id": "arven:item:switch",
			"ref": EntityRef.new(
				"card", 0, "deck", "", 0, "", "sv1-150").to_dict(),
		},
		{
			"option_id": "arven:item:ultra-ball",
			"ref": EntityRef.new(
				"card", 0, "deck", "", 1, "", "sv1-153").to_dict(),
		},
		{
			"option_id": "arven:tool:charm",
			"ref": EntityRef.new(
				"card", 0, "deck", "", 2, "", "sv1-202").to_dict(),
		},
	]
	var arven_request := ChoiceView.new(
		"choice:psychic-opening-arven", arven_state.revision,
		"arven", 0, "", arven_options, 1, 2, false, false,
		{"domain": "effect", "purpose": "arven"},
	)
	var arven_snapshot := arven_state.snapshot()
	var arven_info := AIInformationSet.capture(
		arven_state, 0, catalog, [], [], TEST_SEED)
	var arven_response := worker._traditional_choice_response(
		arven_state, arven_info, arven_request, "psychic",
		AIStrategyRegistry.new().strategy_for("psychic"), catalog)
	var arven_late := GameState.from_dict(arven_state.snapshot())
	arven_late.turn_number = 3
	var arven_first := GameState.from_dict(arven_state.snapshot())
	arven_first.first_player_idx = 0
	var arven_has_switch := GameState.from_dict(arven_state.snapshot())
	arven_has_switch.players[0].hand.append("sv1-150")
	var arven_cannot_pay := GameState.from_dict(arven_state.snapshot())
	arven_cannot_pay.players[0].bench[0].energy_card_ids.clear()
	arven_cannot_pay.players[0].energy_attached_this_turn = true
	var arven_can_retreat := GameState.from_dict(arven_state.snapshot())
	arven_can_retreat.players[0].active.energy_card_ids.append(psychic_energy_id)
	_check(
		arven_response != null
		and arven_response.option_ids == [
			"arven:item:switch", "arven:tool:charm"]
		and worker._psychic_arven_opening_switch_option(
			arven_state, arven_request, "psychic", catalog) == 0
		and worker._psychic_arven_opening_switch_option(
			arven_late, arven_request, "psychic", catalog) == -1
		and worker._psychic_arven_opening_switch_option(
			arven_first, arven_request, "psychic", catalog) == -1
		and worker._psychic_arven_opening_switch_option(
			arven_has_switch, arven_request, "psychic", catalog) == -1
		and worker._psychic_arven_opening_switch_option(
			arven_cannot_pay, arven_request, "psychic", catalog) == -1
		and worker._psychic_arven_opening_switch_option(
			arven_can_retreat, arven_request, "psychic", catalog) == -1
		and arven_state.snapshot() == arven_snapshot,
		"Arven did not preserve the guarded Cresselia opening Switch route",
	)
	var engine_search_state := GameState.new()
	engine_search_state.set_type_matchups_enabled(false)
	engine_search_state.public_deck_keys = ["psychic", "steel"]
	engine_search_state.phase = "MAIN"
	engine_search_state.turn_number = 8
	engine_search_state.active_player_idx = 0
	engine_search_state.players[0].active = PokemonState.new("sv1-109")
	engine_search_state.players[0].bench[0] = PokemonState.new("sv1-104")
	engine_search_state.players[0].bench[1] = PokemonState.new("sv1-110")
	engine_search_state.players[0].bench[2] = PokemonState.new("sv1-111")
	engine_search_state.players[0].bench[3] = PokemonState.new("sv1-111")
	engine_search_state.players[1].active = PokemonState.new("svm-orthworm")
	var engine_search_options: Array[Dictionary] = [
		{
			"option_id": "search:cresselia",
			"ref": EntityRef.new(
				"card", 0, "deck", "", 0, "", "sv1-113").to_dict(),
		},
		{
			"option_id": "search:deoxys",
			"ref": EntityRef.new(
				"card", 0, "deck", "", 1, "", "sv1-112").to_dict(),
		},
		{
			"option_id": "search:natu",
			"ref": EntityRef.new(
				"card", 0, "deck", "", 2, "", "sv1-107").to_dict(),
		},
		{
			"option_id": "search:xatu",
			"ref": EntityRef.new(
				"card", 0, "deck", "", 3, "", "sv1-108").to_dict(),
		},
	]
	var engine_search_request := ChoiceView.new(
		"choice:psychic-first-engine", engine_search_state.revision,
		"search_move", 0, "", engine_search_options, 1, 1, false, false,
		{"domain": "effect", "purpose": "search"},
	)
	var engine_search_snapshot := engine_search_state.snapshot()
	var engine_search_info := AIInformationSet.capture(
		engine_search_state, 0, catalog, [], [], TEST_SEED)
	var engine_search_response := worker._traditional_choice_response(
		engine_search_state, engine_search_info, engine_search_request, "psychic",
		AIStrategyRegistry.new().strategy_for("psychic"), catalog)
	_check(
		engine_search_response != null
		and engine_search_response.option_ids == ["search:natu"]
		and engine_search_state.snapshot() == engine_search_snapshot,
		"Psychic search chose another attacker before starting the first Xatu line",
	)

	var deoxys_state := GameState.new()
	deoxys_state.set_type_matchups_enabled(false)
	deoxys_state.public_deck_keys = ["psychic", "steel"]
	deoxys_state.players[0].active = PokemonState.new("sv1-113")
	deoxys_state.players[0].active.energy_card_ids.append(psychic_energy_id)
	deoxys_state.players[0].bench[0] = PokemonState.new("sv1-112")
	deoxys_state.players[1].active = PokemonState.new("svm-orthworm")
	var deoxys_option := {
		"option_id": "pokemon:0:bench_0:sv1-112",
		"ref": EntityRef.new(
			"pokemon", 0, "", "bench_0", -1, "", "sv1-112").to_dict(),
	}
	var deoxys_request := ChoiceView.new(
		"choice:deoxys-prefix", deoxys_state.revision,
		"select_energy_target", 0, "", [deoxys_option],
		0, 3, true, true,
		{"purpose": "attach_energy",
		 "card_ids": [psychic_energy_id, psychic_energy_id, psychic_energy_id],
		 "same_target": true, "max_per_target": 3},
	)
	var deoxys_snapshot := deoxys_state.snapshot()
	var deoxys_info := AIInformationSet.capture(
		deoxys_state, 0, catalog, [], [], TEST_SEED)
	var deoxys_response := worker._traditional_choice_response(
		deoxys_state, deoxys_info, deoxys_request, "psychic",
		AIStrategyRegistry.new().strategy_for("psychic"), catalog)
	_check(
		worker._useful_energy_target_selection_count(
			deoxys_state, deoxys_request, deoxys_option,
			"psychic", catalog, 3) == 3
		and deoxys_response != null
		and deoxys_response.option_ids == [
			"pokemon:0:bench_0:sv1-112",
			"pokemon:0:bench_0:sv1-112",
			"pokemon:0:bench_0:sv1-112",
		]
		and deoxys_state.snapshot() == deoxys_snapshot,
		"Cresselia did not preserve the bridge prefix to Deoxys's third Energy",
	)

	var cresselia_option := {
		"option_id": "pokemon:0:active:sv1-113",
		"ref": EntityRef.new(
			"pokemon", 0, "", "active", -1, "", "sv1-113").to_dict(),
	}
	var cresselia_request := ChoiceView.new(
		"choice:cresselia-prefix", deoxys_state.revision,
		"select_energy_target", 0, "", [cresselia_option],
		0, 3, true, true,
		{"purpose": "attach_energy", "card_id": psychic_energy_id,
		 "same_target": true, "max_per_target": 3},
	)
	_check(
		worker._useful_energy_target_selection_count(
			deoxys_state, cresselia_request, cresselia_option,
			"psychic", catalog, 3) == 1
		and deoxys_state.snapshot() == deoxys_snapshot,
		"Cresselia over-attached after readying Photon Laser",
	)
	deoxys_state.players[0].bench[0].energy_card_ids.append(psychic_energy_id)
	deoxys_state.players[0].bench[1] = PokemonState.new("sv1-107")
	deoxys_state.players[0].bench[1].energy_card_ids.append(psychic_energy_id)
	var field_energy_snapshot := deoxys_state.snapshot()
	_check(
		worker._useful_energy_target_selection_count(
			deoxys_state, cresselia_request, cresselia_option,
			"psychic", catalog, 3) == 2
		and deoxys_state.snapshot() == field_energy_snapshot,
		"Cresselia did not stop at the five-Energy Photon Laser threshold",
	)
	deoxys_state.players[0].bench[1].energy_card_ids.clear()
	var natu_snapshot := deoxys_state.snapshot()
	var natu_option := {
		"option_id": "pokemon:0:bench_1:sv1-107",
		"ref": EntityRef.new(
			"pokemon", 0, "", "bench_1", -1, "", "sv1-107").to_dict(),
	}
	var natu_request := ChoiceView.new(
		"choice:natu-prefix", deoxys_state.revision,
		"select_energy_target", 0, "", [natu_option],
		0, 3, true, true,
		{"purpose": "attach_energy", "card_id": psychic_energy_id,
		 "same_target": true, "max_per_target": 3},
	)
	_check(
		worker._useful_energy_target_selection_count(
			deoxys_state, natu_request, natu_option,
			"psychic", catalog, 3) == 1
		and deoxys_state.snapshot() == natu_snapshot,
		"Natu over-attached toward a non-core Xatu attack",
	)

	var route_state := GameState.new()
	route_state.set_type_matchups_enabled(false)
	route_state.public_deck_keys = ["psychic", "steel"]
	route_state.players[0].active = PokemonState.new("sv1-107")
	route_state.players[0].bench[0] = PokemonState.new("sv1-111")
	route_state.players[0].bench[0].energy_card_ids.assign([
		psychic_energy_id, psychic_energy_id])
	route_state.players[0].bench[1] = PokemonState.new("sv1-113")
	route_state.players[1].active = PokemonState.new("svm-orthworm")
	var route_snapshot := route_state.snapshot()
	var latios_attach_value := worker._energy_choice_target_value(
		route_state, 0, "bench_0", psychic_energy_id, "psychic", catalog)
	var cresselia_attach_value := worker._energy_choice_target_value(
		route_state, 0, "bench_1", psychic_energy_id, "psychic", catalog)
	_check(
		worker._high_impact_missing_energy(
			route_state, 0, route_state.players[0].bench[0], "", catalog) == 1
		and worker._high_impact_missing_energy(
			route_state, 0, route_state.players[0].bench[1], "", catalog) == 2
		and latios_attach_value > cresselia_attach_value
		and route_state.snapshot() == route_snapshot,
		"Energy scoring combined Cresselia's cheap setup cost with Photon damage: "
		+ "Latios %.3f/Cresselia %.3f, missing %d/%d" % [
			latios_attach_value,
			cresselia_attach_value,
			worker._high_impact_missing_energy(
				route_state, 0, route_state.players[0].bench[0], "", catalog),
			worker._high_impact_missing_energy(
				route_state, 0, route_state.players[0].bench[1], "", catalog),
		],
	)

	var keldeo_state := GameState.new()
	keldeo_state.set_type_matchups_enabled(false)
	keldeo_state.public_deck_keys = ["water", "steel"]
	keldeo_state.players[0].active = PokemonState.new("sv2-grex")
	keldeo_state.players[0].active.energy_card_ids.assign([
		water_energy_id, water_energy_id])
	keldeo_state.players[0].bench[0] = PokemonState.new("sv2-keldeo")
	keldeo_state.players[0].bench[0].energy_card_ids.append(water_energy_id)
	keldeo_state.players[0].bench[1] = PokemonState.new("sv2-38")
	keldeo_state.players[0].bench[2] = PokemonState.new("sv2-staryu")
	keldeo_state.players[0].bench[3] = PokemonState.new("sv2-tatsu")
	keldeo_state.players[1].active = PokemonState.new("svm-orthworm")
	var keldeo_snapshot := keldeo_state.snapshot()
	_check(
		worker._best_pokemon_damage_for_state(
			keldeo_state, 0, keldeo_state.players[0].bench[0], catalog) == 90
		and worker._energy_choice_target_value(
			keldeo_state, 0, "bench_0", water_energy_id, "water", catalog)
		> worker._energy_choice_target_value(
			keldeo_state, 0, "active", water_energy_id, "water", catalog)
		and keldeo_state.snapshot() == keldeo_snapshot,
		"Water Energy ignored ready Keldeo or over-attached a supplied Greninja",
	)

	var distribution_state := GameState.new()
	distribution_state.set_type_matchups_enabled(false)
	distribution_state.public_deck_keys = ["psychic", "steel"]
	distribution_state.players[0].active = PokemonState.new("sv1-112")
	distribution_state.players[0].active.energy_card_ids.assign([
		psychic_energy_id, psychic_energy_id, psychic_energy_id])
	distribution_state.players[0].bench[0] = PokemonState.new("sv1-111")
	distribution_state.players[0].bench[1] = PokemonState.new("sv1-113")
	distribution_state.players[0].bench[1].energy_card_ids.append(psychic_energy_id)
	distribution_state.players[1].active = PokemonState.new("svm-orthworm")
	var distribution_options: Array[Dictionary] = [
		{
			"option_id": "pokemon:0:bench_0:sv1-111",
			"ref": EntityRef.new(
				"pokemon", 0, "", "bench_0", -1, "", "sv1-111").to_dict(),
		},
		{
			"option_id": "pokemon:0:bench_1:sv1-113",
			"ref": EntityRef.new(
				"pokemon", 0, "", "bench_1", -1, "", "sv1-113").to_dict(),
		},
	]
	var distribution_refs: Array[Dictionary] = []
	for index in range(3):
		distribution_refs.append(EntityRef.new(
			"attachment", 0, "", "active", index, "energy",
			psychic_energy_id).to_dict())
	var distribution_request := ChoiceView.new(
		"choice:deoxys-distribution", distribution_state.revision,
		"distribute_energy", 0, "", distribution_options,
		3, 3, true, false,
		{"purpose": "energy_relocate_target",
		 "card_ids": [psychic_energy_id, psychic_energy_id, psychic_energy_id],
		 "attachment_refs": distribution_refs,
		 "source_player": 0, "source_slot": "active", "same_source": true,
		 "same_target": false, "max_per_target": 3},
	)
	var relocation_attachment_request := ChoiceView.new(
		"choice:canonical-relocation-source", distribution_state.revision,
		"select_attachment", 0, "", [{
			"option_id": "attachment:0:active:energy:0:%s" % psychic_energy_id,
			"ref": distribution_refs[0],
		}], 1, 1, false, false,
		{"purpose": "energy_relocate_attachments", "source_player": 0},
	)
	var discard_hand_request := ChoiceView.new(
		"choice:canonical-discard-hand", distribution_state.revision,
		"search_move", 0, "", [distribution_options[0]],
		1, 1, false, false,
		{"purpose": "discard_hand_then_draw"},
	)
	var searched_switch_request := ChoiceView.new(
		"choice:canonical-search-switch", distribution_state.revision,
		"select_bench", 0, "", [distribution_options[0]],
		1, 1, false, false,
		{"purpose": "search_any_switch_bench"},
	)
	var choice_mode_strategy := AIStrategyRegistry.new().strategy_for("psychic")
	var no_switch_state := GameState.new()
	no_switch_state.public_deck_keys = ["psychic", "steel"]
	no_switch_state.players[0].active = PokemonState.new("sv1-112")
	var search_switch_confirmation := ChoiceView.new(
		"choice:canonical-search-switch-confirm", no_switch_state.revision,
		"confirm", 0, "", [
			{"option_id": "confirm:yes"}, {"option_id": "confirm:no"},
		], 1, 1, false, false,
		{"purpose": "search_any_switch_confirm"},
	)
	_check(
		worker._choice_score_mode(
			relocation_attachment_request,
			relocation_attachment_request.presentation) == "energy_source"
		and worker._choice_score_mode(
			discard_hand_request, discard_hand_request.presentation) == "discard"
		and worker._choice_score_mode(
			searched_switch_request,
			searched_switch_request.presentation) == "self_switch"
		and choice_mode_strategy.choice_mode(
			{}, relocation_attachment_request.to_dict()) == "source"
		and choice_mode_strategy.choice_mode(
			{}, discard_hand_request.to_dict()) == "discard"
		and not worker._confirm_choice(
			no_switch_state, search_switch_confirmation,
			search_switch_confirmation.presentation, "psychic", catalog),
		"Canonical native Choice purposes were interpreted with legacy/inverted semantics",
	)
	var distribution_snapshot := distribution_state.snapshot()
	var distribution_info := AIInformationSet.capture(
		distribution_state, 0, catalog, [], [], TEST_SEED)
	var distribution_response := worker._traditional_choice_response(
		distribution_state, distribution_info, distribution_request, "psychic",
		AIStrategyRegistry.new().strategy_for("psychic"), catalog)
	var distribution_repeat := worker._traditional_choice_response(
		distribution_state, distribution_info, distribution_request, "psychic",
		AIStrategyRegistry.new().strategy_for("psychic"), catalog)
	_check(
		distribution_response != null
		and distribution_response.option_ids == [
			"pokemon:0:bench_0:sv1-111",
			"pokemon:0:bench_0:sv1-111",
			"pokemon:0:bench_0:sv1-111",
		]
		and AIChoiceSelector.response_is_shape_legal(
			distribution_request, distribution_response.option_ids, catalog)
		and distribution_repeat != null
		and distribution_repeat.to_dict() == distribution_response.to_dict()
		and distribution_state.snapshot() == distribution_snapshot,
		"Deoxys did not preserve all three ordered Energy for Latios's 180 route",
	)

	var split_state := GameState.from_dict(distribution_snapshot)
	split_state.players[0].active.energy_card_ids.assign([
		psychic_energy_id, psychic_energy_id])
	split_state.players[0].bench[0].energy_card_ids.assign([
		psychic_energy_id, psychic_energy_id])
	var split_refs: Array[Dictionary] = []
	for index in range(2):
		split_refs.append(EntityRef.new(
			"attachment", 0, "", "active", index, "energy",
			psychic_energy_id).to_dict())
	var split_request := ChoiceView.new(
		"choice:deoxys-split", split_state.revision,
		"distribute_energy", 0, "", distribution_options,
		2, 2, true, false,
		{"purpose": "energy_relocate_target",
		 "card_ids": [psychic_energy_id, psychic_energy_id],
		 "attachment_refs": split_refs,
		 "source_player": 0, "source_slot": "active", "same_source": true,
		 "same_target": false, "max_per_target": 2},
	)
	var split_snapshot := split_state.snapshot()
	var split_info := AIInformationSet.capture(
		split_state, 0, catalog, [], [], TEST_SEED)
	var split_response := worker._traditional_choice_response(
		split_state, split_info, split_request, "psychic",
		AIStrategyRegistry.new().strategy_for("psychic"), catalog)
	_check(
		split_response != null
		and split_response.option_ids == [
			"pokemon:0:bench_0:sv1-111",
			"pokemon:0:bench_1:sv1-113",
		]
		and AIChoiceSelector.response_is_shape_legal(
			split_request, split_response.option_ids, catalog)
		and split_state.snapshot() == split_snapshot,
		"Ordered Energy allocation repeated a static target after its marginal value ended",
	)

	var combo_state := GameState.new()
	combo_state.set_type_matchups_enabled(false)
	combo_state.public_deck_keys = ["water", "steel"]
	combo_state.players[0].active = PokemonState.new("sv2-grex")
	combo_state.players[0].active.energy_card_ids.assign([
		water_energy_id, water_energy_id])
	combo_state.players[0].bench[0] = PokemonState.new("sv2-starm")
	combo_state.players[1].active = PokemonState.new("sv2-glast")
	combo_state.players[1].bench[0] = PokemonState.new("sv2-grex")
	var combo_options: Array[Dictionary] = [
		{
			"option_id": "pokemon:1:active:sv2-glast",
			"ref": EntityRef.new(
				"pokemon", 1, "", "active", -1, "", "sv2-glast").to_dict(),
		},
		{
			"option_id": "pokemon:1:bench_0:sv2-grex",
			"ref": EntityRef.new(
				"pokemon", 1, "", "bench_0", -1, "", "sv2-grex").to_dict(),
		},
	]
	var combo_request := ChoiceView.new(
		"choice:starmie-combo", combo_state.revision,
		"place_counters_self_discard", 0, "", combo_options,
		1, 1, false, false,
		{"purpose": "place_counters_self_discard", "amount": 20,
		 "source_player": 0, "source_slot": "bench_0",
		 "source_card_id": "sv2-starm", "target_player": 1},
	)
	var combo_snapshot := combo_state.snapshot()
	var combo_info := AIInformationSet.capture(
		combo_state, 0, catalog, [], [], TEST_SEED)
	var combo_response := worker._traditional_choice_response(
		combo_state, combo_info, combo_request, "water",
		AIStrategyRegistry.new().strategy_for("water"), catalog)
	_check(
		combo_response != null
		and combo_response.option_ids == ["pokemon:1:active:sv2-glast"]
		and combo_state.snapshot() == combo_snapshot,
		"Starmie's public 20-damage marker did not select the Torrent KO route",
	)
	var promoted_combo_state := GameState.from_dict(combo_state.snapshot())
	var promoted_greninja: PokemonState = promoted_combo_state.players[0].active
	promoted_combo_state.players[0].active = promoted_combo_state.players[0].bench[0]
	promoted_combo_state.players[0].bench[0] = promoted_greninja
	var promoted_combo_request := ChoiceView.new(
		"choice:starmie-promote-combo", promoted_combo_state.revision,
		"place_counters_self_discard", 0, "", combo_options,
		1, 1, false, false,
		{"purpose": "place_counters_self_discard", "amount": 20,
		 "source_player": 0, "source_slot": "active",
		 "source_card_id": "sv2-starm", "target_player": 1},
	)
	var promoted_combo_snapshot := promoted_combo_state.snapshot()
	var promoted_combo_info := AIInformationSet.capture(
		promoted_combo_state, 0, catalog, [], [], TEST_SEED)
	var promoted_combo_response := worker._traditional_choice_response(
		promoted_combo_state, promoted_combo_info, promoted_combo_request, "water",
		AIStrategyRegistry.new().strategy_for("water"), catalog)
	var starmie_ability_name := str(
		catalog.get_card("sv2-starm").get("abilities", [])[0].get("name", ""))
	var promoted_combo_value := worker._development_action_value(
		promoted_combo_state,
		0,
		GameAction.create(
			"USE_ABILITY", {"ability_name": starmie_ability_name}, 0,
			EntityRef.new(
				"pokemon", 0, "", "active", -1, "", "sv2-starm")),
		"water",
		catalog,
	)
	_check(
		promoted_combo_response != null
		and promoted_combo_response.option_ids == ["pokemon:1:active:sv2-glast"]
		and promoted_combo_value > 0.0
		and promoted_combo_state.snapshot() == promoted_combo_snapshot,
		"Active Starmie did not retain the promote-Greninja Torrent route",
	)

	var shuriken_target: PokemonState = combo_state.players[1].bench[0]
	shuriken_target.damage_counters = maxi(
		0, int(catalog.get_card(shuriken_target.card_id).get("hp", 0)) / 10 - 4)
	var shuriken_snapshot := combo_state.snapshot()
	var shuriken_request := ChoiceView.new(
		"choice:shuriken-ko", combo_state.revision,
		"damage_target", 0, "", combo_options,
		1, 1, false, false,
		{"purpose": "damage_target", "amount": 40,
		 "source_player": 0, "source_slot": "active",
		 "source_card_id": "sv2-grex", "target_player": 1},
	)
	var shuriken_info := AIInformationSet.capture(
		combo_state, 0, catalog, [], [], TEST_SEED)
	var shuriken_response := worker._traditional_choice_response(
		combo_state, shuriken_info, shuriken_request, "water",
		AIStrategyRegistry.new().strategy_for("water"), catalog)
	_check(
		shuriken_response != null
		and shuriken_response.option_ids == ["pokemon:1:bench_0:sv2-grex"]
		and combo_state.snapshot() == shuriken_snapshot,
		"Greninja did not take a public 40-damage Bench knockout",
	)

	var catcher_state := GameState.new()
	catcher_state.set_type_matchups_enabled(false)
	catcher_state.public_deck_keys = ["water", "steel"]
	catcher_state.players[0].active = PokemonState.new("sv2-grex")
	catcher_state.players[0].active.energy_card_ids.assign([
		water_energy_id, water_energy_id])
	catcher_state.players[1].active = PokemonState.new("svm-orthworm")
	catcher_state.players[1].bench[0] = PokemonState.new("sv2-glast")
	catcher_state.players[1].bench[0].damage_counters = 3
	catcher_state.players[1].bench[1] = PokemonState.new("sv2-grex")
	var catcher_options: Array[Dictionary] = [
		{
			"option_id": "pokemon:1:bench_0:sv2-glast",
			"ref": EntityRef.new(
				"pokemon", 1, "", "bench_0", -1, "", "sv2-glast").to_dict(),
		},
		{
			"option_id": "pokemon:1:bench_1:sv2-grex",
			"ref": EntityRef.new(
				"pokemon", 1, "", "bench_1", -1, "", "sv2-grex").to_dict(),
		},
	]
	var catcher_request := ChoiceView.new(
		"choice:catcher-ko", catcher_state.revision,
		"select_opponent_bench", 0, "", catcher_options,
		1, 1, false, false,
		{"purpose": "switch_opponent", "source_player": 0,
		 "target_player": 1},
	)
	var catcher_snapshot := catcher_state.snapshot()
	var catcher_info := AIInformationSet.capture(
		catcher_state, 0, catalog, [], [], TEST_SEED)
	var catcher_response := worker._traditional_choice_response(
		catcher_state, catcher_info, catcher_request, "water",
		AIStrategyRegistry.new().strategy_for("water"), catalog)
	_check(
		catcher_response != null
		and catcher_response.option_ids == ["pokemon:1:bench_0:sv2-glast"]
		and catcher_state.snapshot() == catcher_snapshot,
		"Opponent switch ignored an immediate public Greninja knockout route",
	)

	var choice_state := GameState.new()
	choice_state.set_type_matchups_enabled(false)
	choice_state.public_deck_keys = ["grass", "dragon"]
	choice_state.players[0].active = PokemonState.new("svg2-zaru")
	choice_state.players[0].bench[0] = bench_torterra.clone_state()
	choice_state.players[0].bench[1] = PokemonState.new("svg2-brel")
	choice_state.players[0].bench[1].evolution_stack_ids.assign(["svg2-shro"])
	choice_state.players[0].bench[2] = PokemonState.new("svg2-empo")
	choice_state.players[0].bench[2].evolution_stack_ids.assign(["svg2-pipl"])
	choice_state.players[1].active = PokemonState.new("svg-dram")
	var energy_options: Array[Dictionary] = [
		{
			"option_id": "pokemon:0:bench_0:svg2-tort",
			"ref": EntityRef.new(
				"pokemon", 0, "", "bench_0", -1, "", "svg2-tort").to_dict(),
		},
		{
			"option_id": "pokemon:0:bench_1:svg2-brel",
			"ref": EntityRef.new(
				"pokemon", 0, "", "bench_1", -1, "", "svg2-brel").to_dict(),
		},
	]
	var productive_request := ChoiceView.new(
		"choice:productive-target", choice_state.revision,
		"select_energy_target", 0, "", energy_options,
		0, 2, true, true,
		{"purpose": "attach_energy", "card_id": "sv1-ener-1",
		 "same_target": true, "max_per_target": 2},
	)
	var choice_info := AIInformationSet.capture(
		choice_state, 0, catalog, [], [], TEST_SEED)
	var productive_response := worker._traditional_choice_response(
		choice_state, choice_info, productive_request, "grass",
		AIStrategyRegistry.new().strategy_for("grass"), catalog)
	_check(
		productive_response != null
		and not productive_response.cancelled
		and not productive_response.option_ids.is_empty()
		and productive_response.option_ids[0] == "pokemon:0:bench_1:svg2-brel",
		"Zero-marginal Energy target hid a productive second target: %s" % [
			JSON.stringify(productive_response.to_dict())
			if productive_response != null else "null"
		],
	)

	var discard_state := GameState.new()
	discard_state.set_type_matchups_enabled(false)
	discard_state.public_deck_keys = ["grass", "dragon"]
	discard_state.players[0].active = PokemonState.new("svg2-grot")
	discard_state.players[0].hand.assign(["svg2-tort", "sv2-young"])
	discard_state.players[1].active = PokemonState.new("svg-dram")
	var unique_keep := worker._discard_choice_score(
		discard_state, 0, "svg2-tort", "grass", catalog)
	var trainer_discard := worker._discard_choice_score(
		discard_state, 0, "sv2-young", "grass", catalog)
	discard_state.players[0].hand.append("svg2-tort")
	var duplicate_keep := worker._discard_choice_score(
		discard_state, 0, "svg2-tort", "grass", catalog)
	_check(
		unique_keep < trainer_discard and duplicate_keep > unique_keep,
		"Discard scoring treated the only executable evolution as a duplicate",
	)
	var psychic_discard_state := GameState.new()
	psychic_discard_state.set_type_matchups_enabled(false)
	psychic_discard_state.public_deck_keys = ["psychic", "water"]
	psychic_discard_state.players[0].active = PokemonState.new("sv1-113")
	psychic_discard_state.players[0].hand.assign([
		"sv1-107", "sv1-107", "sv1-180",
	])
	psychic_discard_state.players[0].deck.assign(["sv1-106"])
	var duplicate_psychic_discard := worker._discard_choice_score(
		psychic_discard_state, 0, "sv1-107", "psychic", catalog)
	var draw_trainer_discard := worker._discard_choice_score(
		psychic_discard_state, 0, "sv1-180", "psychic", catalog)
	_check(
		duplicate_psychic_discard > draw_trainer_discard,
		"Duplicate Psychic discard fuel lost to draw Supporter: %.3f <= %.3f" % [
			duplicate_psychic_discard, draw_trainer_discard,
		],
	)

	var fire_joint_discard_state := GameState.new()
	fire_joint_discard_state.set_type_matchups_enabled(false)
	fire_joint_discard_state.public_deck_keys = ["fire", "water"]
	fire_joint_discard_state.players[0].active = PokemonState.new("svi-chim")
	fire_joint_discard_state.players[0].hand.assign([
		"svi-infr", "svi-infr", "svi-monf", "sv2-catch", "sv3-134", "sv1-180",
	])
	fire_joint_discard_state.players[1].active = PokemonState.new("sv2-keldeo")
	var fire_discard_options: Array[Dictionary] = []
	for fire_hand_index in range(fire_joint_discard_state.players[0].hand.size()):
		var fire_card_id := str(
			fire_joint_discard_state.players[0].hand[fire_hand_index])
		fire_discard_options.append({
			"option_id": "fire-discard:%d" % fire_hand_index,
			"ref": EntityRef.new(
				"card", 0, "hand", "", fire_hand_index, "", fire_card_id
			).to_dict(),
		})
	var fire_discard_request := ChoiceView.new(
		"choice:fire-joint-discard", fire_joint_discard_state.revision,
		"select_hand_to_discard", 0, "", fire_discard_options,
		2, 2, false, false,
		{"purpose": "discard_cost", "surface": "card"},
	)
	var fire_joint_snapshot := fire_joint_discard_state.snapshot()
	var fire_joint_info := AIInformationSet.capture(
		fire_joint_discard_state, 0, catalog, [], [], TEST_SEED)
	var fire_joint_response := worker._traditional_choice_response(
		fire_joint_discard_state, fire_joint_info, fire_discard_request, "fire",
		AIStrategyRegistry.new().strategy_for("fire"), catalog)
	var fire_selected_cards: Array[String] = []
	if fire_joint_response != null:
		for fire_option in fire_discard_options:
			if str(fire_option["option_id"]) in fire_joint_response.option_ids:
				fire_selected_cards.append(str(
					Dictionary(fire_option["ref"]).get("card_id", "")))
	var reversed_fire_options := fire_discard_options.duplicate(true)
	reversed_fire_options.reverse()
	var reversed_fire_request := ChoiceView.new(
		"choice:fire-joint-discard-reversed", fire_joint_discard_state.revision,
		"select_hand_to_discard", 0, "", reversed_fire_options,
		2, 2, false, false,
		{"purpose": "discard_cost", "surface": "card"},
	)
	var reversed_fire_response := worker._traditional_choice_response(
		fire_joint_discard_state, fire_joint_info, reversed_fire_request, "fire",
		AIStrategyRegistry.new().strategy_for("fire"), catalog)
	var reversed_fire_cards: Array[String] = []
	if reversed_fire_response != null:
		for fire_option in reversed_fire_options:
			if str(fire_option["option_id"]) in reversed_fire_response.option_ids:
				reversed_fire_cards.append(str(
					Dictionary(fire_option["ref"]).get("card_id", "")))
	fire_selected_cards.sort()
	reversed_fire_cards.sort()
	_check(
		fire_joint_response != null
		and fire_joint_response.option_ids.size() == 2
		and fire_selected_cards.count("svi-infr") <= 1
		and reversed_fire_cards == fire_selected_cards
		and fire_joint_discard_state.snapshot() == fire_joint_snapshot,
		"Sequential discard did not preserve the final Infernape or changed with option order: %s / %s"
		% [JSON.stringify(fire_selected_cards), JSON.stringify(reversed_fire_cards)],
	)

	var colorless_joint_state := GameState.new()
	colorless_joint_state.set_type_matchups_enabled(false)
	colorless_joint_state.public_deck_keys = ["colorless", "fire"]
	colorless_joint_state.players[0].active = PokemonState.new("svi-inde")
	colorless_joint_state.players[0].bench[0] = PokemonState.new("svi-maus")
	colorless_joint_state.players[0].bench[0].energy_card_ids.assign(["svi-mirc"])
	colorless_joint_state.players[0].hand.assign(["svi-ambi", "svi-dtur", "svi-trea"])
	colorless_joint_state.players[1].active = PokemonState.new("svi-chim")
	var colorless_discard_options: Array[Dictionary] = []
	for colorless_hand_index in range(colorless_joint_state.players[0].hand.size()):
		var colorless_card_id := str(
			colorless_joint_state.players[0].hand[colorless_hand_index])
		colorless_discard_options.append({
			"option_id": "colorless-discard:%d" % colorless_hand_index,
			"ref": EntityRef.new(
				"card", 0, "hand", "", colorless_hand_index, "", colorless_card_id
			).to_dict(),
		})
	var colorless_discard_request := ChoiceView.new(
		"choice:colorless-joint-discard", colorless_joint_state.revision,
		"select_hand_to_discard", 0, "", colorless_discard_options,
		2, 2, false, false,
		{"purpose": "discard_cost", "surface": "card"},
	)
	var colorless_joint_snapshot := colorless_joint_state.snapshot()
	var colorless_joint_info := AIInformationSet.capture(
		colorless_joint_state, 0, catalog, [], [], TEST_SEED)
	var colorless_joint_response := worker._traditional_choice_response(
		colorless_joint_state, colorless_joint_info, colorless_discard_request,
		"colorless", AIStrategyRegistry.new().strategy_for("colorless"), catalog)
	var selected_colorless_energy := 0
	if colorless_joint_response != null:
		for colorless_option in colorless_discard_options:
			if str(colorless_option["option_id"]) not in colorless_joint_response.option_ids:
				continue
			var selected_card_id := str(
				Dictionary(colorless_option["ref"]).get("card_id", ""))
			if selected_card_id in ["svi-dtur", "svi-trea"]:
				selected_colorless_energy += 1
	_check(
		colorless_joint_response != null
		and colorless_joint_response.option_ids.size() == 2
		and selected_colorless_energy == 1
		and colorless_joint_state.snapshot() == colorless_joint_snapshot,
		"Sequential discard removed every Energy that could ready Maushold: %s"
		% JSON.stringify(
			colorless_joint_response.to_dict()
			if colorless_joint_response != null else null),
	)

	var candice_state := GameState.new()
	candice_state.set_type_matchups_enabled(false)
	candice_state.public_deck_keys = ["water", "steel"]
	candice_state.players[0].active = PokemonState.new("sv2-keldeo")
	candice_state.players[0].hand.assign(["sv2-cand"])
	var public_water_list := catalog.expand_deck("water")
	candice_state.players[0].deck.assign(public_water_list.slice(0, 36))
	candice_state.players[0].prizes.assign(public_water_list.slice(36, 42))
	var candice_params := {
		"count": 7, "filter": "water_pokemon_and_energy",
		"min_select": 0, "take": 99,
	}
	var candice_a := worker._semantic_look_top_deck_value(
		candice_state, 0, candice_params, "water", catalog)
	var candice_hidden_variant := GameState.from_dict(candice_state.snapshot())
	candice_hidden_variant.players[0].deck.reverse()
	candice_hidden_variant.players[0].prizes.reverse()
	if (
		not candice_hidden_variant.players[0].deck.is_empty()
		and not candice_hidden_variant.players[0].prizes.is_empty()
	):
		var hidden_deck_card := candice_hidden_variant.players[0].deck[0]
		candice_hidden_variant.players[0].deck[0] = (
			candice_hidden_variant.players[0].prizes[0])
		candice_hidden_variant.players[0].prizes[0] = hidden_deck_card
	var candice_b := worker._semantic_look_top_deck_value(
		candice_hidden_variant, 0, candice_params, "water", catalog)
	_check(
		candice_a > 0.0 and is_equal_approx(candice_a, candice_b),
		"Candice value read hidden deck/Prize identities or missed its public hit rate",
	)

	var houb_state := GameState.new()
	houb_state.set_type_matchups_enabled(false)
	houb_state.public_deck_keys = ["fighting", "water"]
	houb_state.players[0].active = PokemonState.new("svf-farf")
	houb_state.players[0].deck.assign(
		catalog.expand_deck("fighting").slice(0, 30))
	houb_state.players[0].hand.assign([
		"svf-houb", "svf-luca", "svf-rio", "sv1-ener-6",
		"sv1-151", "sv1-153", "svf-potion",
	])
	var houb_full := worker._semantic_houb_value(
		houb_state, 0, 5, "fighting", catalog)
	houb_state.players[0].hand.assign(["svf-houb", "svf-potion"])
	var houb_low := worker._semantic_houb_value(
		houb_state, 0, 5, "fighting", catalog)
	_check(
		houb_full < 0.0 and houb_low > 0.0,
		"Houb was still treated as unconditional search instead of draw-to-five",
	)
	var damaged_cetitan := PokemonState.new("svg-ceti")
	damaged_cetitan.damage_counters = 4
	_check(
		worker._best_pokemon_damage(damaged_cetitan, catalog) < 200,
		"Cetitan damage ceiling ignored its self-damage penalty",
	)


func _check_no_progress_action_cycle_guard(_catalog: CardCatalog) -> void:
	var worker := NativeChallengeAI.new()
	var state := _planner_state()
	state.phase = "MAIN"
	state.active_player_idx = 0
	state.turn_number = 19
	state.revision = 41
	var trainer := GameAction.create(
		"PLAY_TRAINER",
		{},
		0,
		EntityRef.new("card", 0, "hand", "", 0, "", "svi-cait"),
	)
	var end_turn := GameAction.create("END_TURN", {}, 0)
	var actions: Array[GameAction] = [trainer, end_turn]
	var request := {
		"engine": NativeChallengeAI.TRADITIONAL_ENGINE_ID,
		"match_instance_id": "cycle-guard-contract",
		"revision": state.revision,
	}
	worker._record_action_cycle_selection(
		request,
		state,
		0,
		{"success": true, "action": trainer.to_dict()},
	)
	var identical_retry := worker._filter_no_progress_action_cycles(
		request, state, 0, actions)
	state.revision += 1
	request["revision"] = state.revision
	var after_no_progress := worker._filter_no_progress_action_cycles(
		request, state, 0, actions)
	_check(
		identical_retry.size() == 2
		and after_no_progress.size() == 1
		and after_no_progress[0].kind == "END_TURN",
		"AI did not blacklist an action after a newer revision returned to the same state",
	)


func _check_cancel_prediction_uses_live_choice_policy(
	registry: AIStrategyRegistry,
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	var worker := NativeChallengeAI.new()
	var state := _planner_state()
	state.phase = "MAIN"
	state.setup_stage = GameState.SETUP_COMPLETE
	state.setup_ready = [true, true]
	state.setup_actor_idx = -1
	state.active_player_idx = 0
	state.turn_number = 8
	state.public_deck_keys = ["lightning", "water"]
	state.players[0].supporter_played_this_turn = false
	state.players[0].hand = ["svi-cait", "svl-lant"]
	state.players[0].deck = [
		"svl-pikaex", "svl-flaa2", "svl-thun", "sv1-ener-4",
	]
	var query := engine.query_legal_action_groups(state, 0)
	var caitlin: GameAction = null
	if query.success:
		for action in query.concrete_actions():
			if (
				action.kind == "PLAY_TRAINER"
				and action.source != null
				and action.source.card_id == "svi-cait"
			):
				caitlin = action
				break
	var simulation := state.clone_state()
	var step: StepResult = null
	var live_response: ChoiceResponse = null
	if caitlin != null:
		step = engine.apply_action(
			simulation, caitlin, PortableRandomSource.new(TEST_SEED + 901))
	if step != null and step.success and step.pending_choice != null:
		var information := AIInformationSet.capture(
			simulation, 0, catalog, [], [], TEST_SEED + 901)
		if information.is_valid():
			live_response = worker._traditional_choice_response(
				simulation,
				information,
				step.pending_choice,
				"lightning",
				registry.strategy_for("lightning"),
				catalog,
			)
	var predicted_cancel := (
		worker._action_first_choice_cancelled(
			state,
			0,
			caitlin,
			"lightning",
			catalog,
			engine,
			TEST_SEED + 901,
		)
		if caitlin != null
		else false
	)
	_check(
		query.success
		and caitlin != null
		and live_response != null
		and live_response.cancelled
		and predicted_cancel == live_response.cancelled,
		"Post-plan Trainer cancellation predictor diverged from the live choice policy",
	)


func _check_target_variant_candidate_coverage() -> void:
	var evolve_left := GameAction.create(
		"EVOLVE",
		{},
		0,
		EntityRef.new("card", 0, "hand", "", 0, "", "svl-lant"),
		EntityRef.new("pokemon", 0, "", "bench_0", -1, "", "svl-chin"),
	)
	var evolve_right := GameAction.create(
		"EVOLVE",
		{},
		0,
		EntityRef.new("card", 0, "hand", "", 1, "", "svl-lant"),
		EntityRef.new("pokemon", 0, "", "bench_1", -1, "", "svl-chin"),
	)
	var actions: Array[GameAction] = [
		GameAction.create("DECLARE_ATTACK", {"attack_index": 0}, 0),
		evolve_left,
		evolve_right,
		GameAction.create("ATTACH_ENERGY", {}, 0),
		GameAction.create("PLAY_BASIC", {}, 0),
		GameAction.create("USE_ABILITY", {"ability_name": "test"}, 0),
		GameAction.create("PLAY_TRAINER", {}, 0),
		GameAction.create("RETREAT", {}, 0),
		GameAction.create("USE_STADIUM", {}, 0),
		GameAction.create("END_TURN", {}, 0),
	]
	var ranked: Array[Dictionary] = []
	for index in range(actions.size()):
		ranked.append({
			"action": actions[index],
			"score": 1000.0 - float(index) * 100.0,
			"index": index,
		})
	var selected := AITurnBeamPlanner._diverse_top_actions(ranked, 8)
	var evolve_targets: Dictionary = {}
	var has_attack := false
	var has_end := false
	for row in selected:
		var action: GameAction = row.get("action")
		if action == null:
			continue
		if action.kind == "EVOLVE" and action.target != null:
			evolve_targets[action.target.slot] = true
		elif action.kind == "DECLARE_ATTACK":
			has_attack = true
		elif action.kind == "END_TURN":
			has_end = true
	_check(
		selected.size() == 8
		and evolve_targets.size() == 2
		and has_attack
		and has_end,
		"Semantic candidate cap dropped alternate evolution targets",
	)


func _check_retreat_tempo_evaluation(catalog: CardCatalog) -> void:
	var state := _planner_state()
	state.set_type_matchups_enabled(false)
	state.players[0].retreated_this_turn = false
	var semantics := CardSemanticCatalog.new(catalog)
	var before := AIPositionEvaluator.state_score_milli(
		state, 0, null, semantics, catalog, TEST_SEED)
	state.players[0].retreated_this_turn = true
	var after := AIPositionEvaluator.state_score_milli(
		state, 0, null, semantics, catalog, TEST_SEED)
	_check(
		before - after
		== roundi(
			AIPositionEvaluator.RETREAT_TEMPO_COST
			* AIPositionEvaluator.SCORE_SCALE),
		"Position evaluator did not charge the deterministic retreat tempo cost",
	)


func _check_redundant_same_pokemon_retreat(
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	var state := GameState.new()
	state.setup_stage = GameState.SETUP_COMPLETE
	state.phase = "MAIN"
	state.turn_number = 3
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.public_deck_keys = ["fire", "grass"]
	state.set_type_matchups_enabled(false)
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.energy_card_ids = ["sv1-ener-2"]
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	state.players[0].bench[0].placed_this_turn = false
	state.players[1].active = PokemonState.new("svi-gree")
	state.players[1].active.placed_this_turn = false
	for _index in range(10):
		state.players[0].deck.append("sv1-ener-2")
		state.players[1].deck.append("sv1-ener-1")
	for _index in range(6):
		state.players[0].prizes.append("sv1-ener-2")
		state.players[1].prizes.append("sv1-ener-1")
	var snapshot := state.snapshot()
	var query := engine.query_legal_action_groups(state, 0)
	var actions := query.concrete_actions() if query.success else []
	var retreat: GameAction = null
	for action in actions:
		if action.kind == "RETREAT" and action.bench_index() == 0:
			retreat = action
			break
	var worker := NativeChallengeAI.new()
	var replacement: GameAction = null
	if retreat != null:
		replacement = worker._validated_or_fallback_action(
			state,
			0,
			retreat,
			actions,
			"fire",
			catalog,
			engine,
			TEST_SEED + 404,
		)
	_check(
		query.success
		and retreat != null
		and worker._redundant_same_pokemon_retreat(
			state, 0, 0, "fire", catalog)
		and not worker._retreat_has_good_target(
			state, 0, 0, "fire", catalog)
		and replacement != null
		and replacement.kind != "RETREAT"
		and state.snapshot() == snapshot,
		"AI accepted a resource-wasting retreat between equivalent copies",
	)


func _check_post_plan_tactical_guards(
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	var worker := NativeChallengeAI.new()

	var fire_state := GameState.new()
	fire_state.phase = "MAIN"
	fire_state.setup_stage = GameState.SETUP_COMPLETE
	fire_state.setup_ready = [true, true]
	fire_state.setup_actor_idx = -1
	fire_state.turn_number = 2
	fire_state.first_player_idx = 1
	fire_state.active_player_idx = 0
	fire_state.public_deck_keys = ["fire", "fire"]
	fire_state.set_type_matchups_enabled(false)
	fire_state.players[0].active = PokemonState.new("svi-chim")
	fire_state.players[0].active.placed_this_turn = false
	fire_state.players[0].active.can_evolve_this_turn = false
	fire_state.players[0].active.energy_card_ids.assign(["sv1-ener-2"])
	fire_state.players[0].hand = ["svi-monf"]
	fire_state.players[0].deck = ["svi-infr", "svi-ente"]
	fire_state.players[0].prizes = [
		"svi-chim", "svi-chim", "svi-chim", "svi-chim", "svi-chim", "svi-chim",
	]
	fire_state.players[1].active = PokemonState.new("svi-ente")
	fire_state.players[1].active.placed_this_turn = false
	fire_state.players[1].deck = ["svi-chim", "svi-monf"]
	fire_state.players[1].prizes = [
		"svi-chim", "svi-chim", "svi-chim", "svi-chim", "svi-chim", "svi-chim",
	]
	var fire_query := engine.query_legal_action_groups(fire_state, 0)
	var fire_actions: Array[GameAction] = []
	if fire_query.success:
		fire_actions.assign(fire_query.concrete_actions())
	var spark: GameAction = null
	for fire_action in fire_actions:
		if fire_action.kind == "DECLARE_ATTACK":
			spark = fire_action
			break
	var retained_fire_action: GameAction = null
	if spark != null:
		retained_fire_action = worker._validated_or_fallback_action(
			fire_state, 0, spark, fire_actions, "fire", catalog, engine, TEST_SEED)
	_check(
		fire_query.success
		and spark != null
		and worker._attack_squanders_only_fire_energy(
			fire_state, 0, spark, "fire", catalog)
		and retained_fire_action != null
		and retained_fire_action.kind == "END_TURN",
		"Fire tactical guard discarded lone Chimchar's last Energy for a non-KO",
	)

	var setup_state := GameState.new()
	setup_state.phase = "MAIN"
	setup_state.setup_stage = GameState.SETUP_COMPLETE
	setup_state.setup_ready = [true, true]
	setup_state.setup_actor_idx = -1
	setup_state.turn_number = 7
	setup_state.first_player_idx = 1
	setup_state.active_player_idx = 0
	setup_state.public_deck_keys = ["colorless", "colorless"]
	setup_state.set_type_matchups_enabled(false)
	setup_state.players[0].active = PokemonState.new("svi-maus")
	setup_state.players[0].active.placed_this_turn = false
	setup_state.players[0].active.energy_card_ids.assign(["svi-dtur"])
	setup_state.players[0].bench[0] = PokemonState.new("svi-flam")
	setup_state.players[0].bench[1] = PokemonState.new("svi-gree")
	setup_state.players[0].hand = ["svi-tand"]
	for _index in range(8):
		setup_state.players[0].deck.append("svi-trea")
	setup_state.players[0].prizes = [
		"svi-tand", "svi-tand", "svi-tand", "svi-tand", "svi-tand", "svi-tand",
	]
	setup_state.players[1].active = PokemonState.new("svi-maus")
	setup_state.players[1].active.placed_this_turn = false
	setup_state.players[1].deck = ["svi-trea", "svi-trea"]
	setup_state.players[1].prizes = [
		"svi-tand", "svi-tand", "svi-tand", "svi-tand", "svi-tand", "svi-tand",
	]
	var setup_query := engine.query_legal_action_groups(setup_state, 0)
	var setup_actions: Array[GameAction] = []
	if setup_query.success:
		setup_actions.assign(setup_query.concrete_actions())
	var setup_attack: GameAction = null
	for setup_action in setup_actions:
		if setup_action.kind == "DECLARE_ATTACK":
			setup_attack = setup_action
			break
	var setup_selection: GameAction = null
	if setup_attack != null:
		setup_selection = worker._validated_or_fallback_action(
			setup_state,
			0,
			setup_attack,
			setup_actions,
			"colorless",
			catalog,
			engine,
			TEST_SEED + 1,
		)
	_check(
		setup_query.success
		and setup_attack != null
		and setup_selection != null
		and setup_selection.kind == "PLAY_BASIC"
		and setup_selection.source != null
		and setup_selection.source.card_id == "svi-tand",
		"AI attacked before a proof-safe, role-relevant Basic Bench development",
	)
	var rejected_retreat: GameAction = null
	for setup_action in setup_actions:
		if setup_action.kind != "RETREAT" or setup_action.target == null:
			continue
		var bench_idx := int(setup_action.target.slot.trim_prefix("bench_"))
		if not worker._retreat_has_good_target(
			setup_state, 0, bench_idx, "colorless", catalog):
			rejected_retreat = setup_action
			break
	var retreat_replacement: GameAction = null
	if rejected_retreat != null:
		retreat_replacement = worker._validated_or_fallback_action(
			setup_state,
			0,
			rejected_retreat,
			setup_actions,
			"colorless",
			catalog,
			engine,
			TEST_SEED + 11,
		)
	_check(
		rejected_retreat != null
		and retreat_replacement != null
		and retreat_replacement.kind == "PLAY_BASIC"
		and retreat_replacement.source != null
		and retreat_replacement.source.card_id == "svi-tand",
		"Rejected retreat fallback attacked without re-running development validation",
	)

	var jet_state := GameState.from_dict(setup_state.snapshot())
	jet_state.players[0].bench[1] = null
	jet_state.players[0].hand = ["svi-jete"]
	jet_state.players[1].active = PokemonState.new("svi-gree")
	jet_state.players[1].active.energy_card_ids.assign(["svi-mirc"])
	var jet_query := engine.query_legal_action_groups(jet_state, 0)
	var jet_actions: Array[GameAction] = []
	if jet_query.success:
		jet_actions.assign(jet_query.concrete_actions())
	var jet_attach: GameAction = null
	var jet_attack: GameAction = null
	for jet_action in jet_actions:
		if jet_action.kind == "DECLARE_ATTACK":
			jet_attack = jet_action
		elif (
			jet_action.kind == "ATTACH_ENERGY"
			and jet_action.target != null
			and jet_action.target.slot == "bench_0"
		):
			jet_attach = jet_action
	var jet_selection: GameAction = null
	if jet_attach != null:
		jet_selection = worker._validated_or_fallback_action(
			jet_state,
			0,
			jet_attach,
			jet_actions,
			"colorless",
			catalog,
			engine,
			TEST_SEED + 2,
		)
	_check(
		jet_query.success
		and jet_attach != null
		and jet_attack != null
		and worker._switching_energy_regresses_current_attack(
			jet_state,
			0,
			jet_attach,
			"colorless",
			catalog,
			engine,
			TEST_SEED + 2,
		)
		and jet_selection != null
		and jet_selection.kind == "DECLARE_ATTACK",
		"Jet Energy guard replaced a ready Maushold attack with a 30-damage switch",
	)

	var doomed_state := GameState.new()
	doomed_state.phase = "MAIN"
	doomed_state.setup_stage = GameState.SETUP_COMPLETE
	doomed_state.turn_number = 9
	doomed_state.first_player_idx = 1
	doomed_state.active_player_idx = 0
	doomed_state.public_deck_keys = ["fire", "fire"]
	doomed_state.set_type_matchups_enabled(false)
	doomed_state.players[0].active = PokemonState.new("svi-ente")
	doomed_state.players[0].active.placed_this_turn = false
	doomed_state.players[0].active.damage_counters = 11
	doomed_state.players[0].bench[0] = PokemonState.new("svi-chiy")
	doomed_state.players[0].bench[0].energy_card_ids.assign(["sv1-ener-2"])
	doomed_state.players[0].hand = ["sv1-ener-2"]
	doomed_state.players[0].deck = ["svi-chim", "svi-monf"]
	doomed_state.players[0].prizes = [
		"svi-chim", "svi-chim", "svi-chim", "svi-chim", "svi-chim", "svi-chim",
	]
	doomed_state.players[1].active = PokemonState.new("svi-infr")
	doomed_state.players[1].active.placed_this_turn = false
	doomed_state.players[1].active.energy_card_ids.assign([
		"sv1-ener-2", "sv1-ener-2",
	])
	doomed_state.players[1].deck = ["svi-chim", "svi-monf"]
	doomed_state.players[1].prizes = [
		"svi-chim", "svi-chim", "svi-chim", "svi-chim", "svi-chim", "svi-chim",
	]
	var doomed_query := engine.query_legal_action_groups(doomed_state, 0)
	var active_attach: GameAction = null
	var bench_attach: GameAction = null
	if doomed_query.success:
		for doomed_action in doomed_query.concrete_actions():
			if doomed_action.kind != "ATTACH_ENERGY" or doomed_action.target == null:
				continue
			if doomed_action.target.slot == "active":
				active_attach = doomed_action
			elif doomed_action.target.slot == "bench_0":
				bench_attach = doomed_action
	var active_attach_value := -INF
	var bench_attach_value := -INF
	if active_attach != null:
		active_attach_value = worker._development_action_value(
			doomed_state, 0, active_attach, "fire", catalog)
	if bench_attach != null:
		bench_attach_value = worker._development_action_value(
			doomed_state, 0, bench_attach, "fire", catalog)
	_check(
		doomed_query.success
		and active_attach != null
		and bench_attach != null
		and bench_attach_value > active_attach_value + 300.0,
		"Energy scoring fed a publicly doomed Active instead of a live Bench attacker",
	)


func _check_tactical_goldens(
	registry: AIStrategyRegistry,
	catalog: CardCatalog,
) -> int:
	if not registry.is_valid():
		return 0
	var semantic_catalog := CardSemanticCatalog.new(catalog)
	var semantic_cards: Dictionary = {}
	var card_ids: Array = catalog.cards.keys()
	card_ids.sort()
	for card_id_value in card_ids:
		var card_id := str(card_id_value)
		semantic_cards[card_id] = semantic_catalog.semantics_for(card_id)
	semantic_cards.make_read_only()
	var semantic_context := {"cards": semantic_cards}
	semantic_context.make_read_only()
	var required_categories := [
		"setup", "evolution", "search", "switch", "attack", "prize_route",
		"resource_preservation", "loss_avoidance",
	]
	var seen_ids: Dictionary = {}
	var total := 0
	for deck_key in RELEASE_DECK_KEYS:
		var strategy := registry.strategy_for(deck_key)
		var scenarios: Array = strategy.profile().get("golden_scenarios", [])
		_check(
			scenarios.size() >= 8 and scenarios.size() <= 12,
			"%s must expose 8-12 tactical golden scenarios" % deck_key,
		)
		var categories: Dictionary = {}
		for scenario_value in scenarios:
			total += 1
			if not scenario_value is Dictionary:
				_check(false, "%s golden scenario is not an object" % deck_key)
				continue
			var scenario: Dictionary = scenario_value
			var scenario_id := str(scenario.get("id", ""))
			_check(
				not scenario_id.is_empty() and not seen_ids.has(scenario_id),
				"Duplicate or empty tactical golden id: %s/%s" % [deck_key, scenario_id],
			)
			seen_ids[scenario_id] = true
			categories[str(scenario.get("category", ""))] = true
			var info: Dictionary = scenario.get("context", {})
			var expected_stage := str(scenario.get("stage", ""))
			var actual_stage := strategy.plan_stage(info)
			_check(
				actual_stage == expected_stage,
				"%s golden %s stage mismatch: expected=%s actual=%s" % [
					deck_key, scenario_id, expected_stage, actual_stage,
				],
			)
			var preferred: Dictionary = scenario.get("preferred", {})
			var over: Dictionary = scenario.get("over", {})
			var preferred_score := 0.0
			var over_score := 0.0
			if str(scenario.get("surface", "")) == "choice":
				var choice_context: Dictionary = scenario.get("choice_context", {})
				preferred_score = strategy.choice_score(
					info, choice_context, preferred, semantic_context)
				over_score = strategy.choice_score(
					info, choice_context, over, semantic_context)
			else:
				preferred_score = strategy.action_score(
					info, preferred, semantic_context)
				over_score = strategy.action_score(info, over, semantic_context)
			_check(
				str(scenario.get("expected", "")) == "higher"
				and preferred_score > over_score,
				"%s golden %s failed: preferred=%.3f over=%.3f" % [
					deck_key, scenario_id, preferred_score, over_score,
				],
			)
		for category in required_categories:
			_check(
				categories.has(category),
				"%s tactical goldens do not cover %s" % [deck_key, category],
			)
	_check(total >= 100, "Traditional AI must expose at least 100 tactical goldens")
	return total


func _check_trusted_choice_bridge(
	source: GameState,
	registry: AIStrategyRegistry,
	catalog: CardCatalog,
) -> void:
	if source == null or not registry.is_valid():
		return
	var worker := NativeChallengeAI.new()
	var strategy := registry.strategy_for("fire")
	var resolver := Callable(
		worker, "_traditional_simulated_choice_response").bind(
			0, "fire", strategy, catalog, registry)
	var card_options: Array[Dictionary] = [
		{
			"option_id": "card:0:svi-chim",
			"label": "小火焰猴",
			"ref": EntityRef.new(
				"card", 0, "deck", "", 0, "", "svi-chim").to_dict(),
		},
		{
			"option_id": "card:1:svi-infr",
			"label": "烈焰猴",
			"ref": EntityRef.new(
				"card", 0, "deck", "", 1, "", "svi-infr").to_dict(),
		},
	]
	var request := ChoiceView.new(
		"trusted-choice:cards",
		source.revision,
		"select_card",
		0,
		"选择卡牌",
		card_options,
		1,
		1,
		false,
		false,
		{"purpose": "search"},
	)
	var live_state := source.clone_state()
	live_state.set_type_matchups_enabled(false)
	var information := AIInformationSet.capture(
		live_state, 0, catalog, [], [], TEST_SEED)
	var live_response := worker._traditional_choice_response(
		live_state,
		information,
		request,
		"fire",
		strategy,
		catalog,
	)
	var simulated_state := source.clone_state()
	var simulated_response: Variant = resolver.call(
		simulated_state,
		request,
		TEST_SEED,
		func() -> bool: return false,
		Time.get_ticks_usec() + 500000,
	)
	var simulated_choice := simulated_response as ChoiceResponse
	_check(
		simulated_choice != null
		and simulated_choice.to_dict() == live_response.to_dict()
		and not simulated_state.apply_type_matchups,
		"Trusted simulated Choice bridge diverged from the live base+strategy scorer",
	)

	# Rule-dominant choices must use the same special-case policy too; option
	# order deliberately puts the losing generic fallback first.
	var turn_request := ChoiceView.new(
		"trusted-choice:turn-order",
		source.revision,
		"choose_turn_order",
		0,
		"选择先后手",
		[
			{"option_id": "turn:second", "label": "后手"},
			{"option_id": "turn:first", "label": "先手"},
		],
		1,
		1,
	)
	var turn_response: Variant = resolver.call(
		source.clone_state(),
		turn_request,
		TEST_SEED,
		func() -> bool: return false,
		Time.get_ticks_usec() + 500000,
	)
	var turn_choice := turn_response as ChoiceResponse
	_check(
		turn_choice != null
		and turn_choice.option_ids == ["turn:first"],
		"Trusted simulated Choice bridge skipped NativeChallengeAI special rules",
	)


func _check_mandatory_knockout(
	registry: AIStrategyRegistry,
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	if not registry.is_valid():
		return
	var source := _planner_state()
	source.set_type_matchups_enabled(false)
	source.players[0].active.energy_card_ids = [
		"sv1-ener-2", "sv1-ener-2", "sv1-ener-2",
	]
	source.players[1].bench[0] = PokemonState.new("sv2-staryu")
	var information := AIInformationSet.capture(
		source, 0, catalog, [], [], TEST_SEED)
	var sampled := information.sample_state(TEST_SEED)
	var query := engine.query_legal_action_groups(sampled, 0)
	_check(query.success, "Mandatory-KO fixture legal query failed")
	if not query.success:
		return
	var legal: Array[GameAction] = []
	legal.assign(query.concrete_actions())
	var result := AIMandatoryTactics.new().resolve(
		information,
		sampled,
		0,
		legal,
		engine,
		registry.strategy_for("fire"),
		TEST_SEED,
		func() -> bool: return false,
		Time.get_ticks_usec() + 500000,
		192,
	)
	var selected: GameAction = result.get("action")
	_check(
		bool(result.get("resolved", false))
		and str(result.get("reason", "")) == "immediate_knockout"
		and selected != null
		and selected.kind == "DECLARE_ATTACK",
		"Mandatory tactics did not force an available deterministic active knockout",
	)

	var colorless_safe_state := _colorless_pre_knockout_state(6, "svi-tand", 6)
	var colorless_safe_query := engine.query_legal_action_groups(
		colorless_safe_state, 0)
	var colorless_safe_actions: Array[GameAction] = []
	if colorless_safe_query.success:
		colorless_safe_actions.assign(colorless_safe_query.concrete_actions())
	var colorless_safe_info := AIInformationSet.capture(
		colorless_safe_state, 0, catalog, colorless_safe_actions, [], TEST_SEED)
	var colorless_safe_result := AIMandatoryTactics.new().resolve(
		colorless_safe_info,
		colorless_safe_state,
		0,
		colorless_safe_actions,
		engine,
		registry.strategy_for("colorless"),
		TEST_SEED,
		func() -> bool: return false,
		Time.get_ticks_usec() + 500000,
		192,
	)
	var safe_evolution: GameAction = colorless_safe_result.get("action")
	var colorless_worker := NativeChallengeAI.new()
	var safe_diagnostics := colorless_worker.diagnose_decision(
		colorless_safe_state,
		0,
		safe_evolution,
		colorless_safe_actions,
		"colorless",
		catalog,
		engine,
		TEST_SEED,
	)
	_check(
		colorless_safe_query.success
		and bool(colorless_safe_result.get("resolved", false))
		and str(colorless_safe_result.get("reason", ""))
		== "safe_development_before_knockout"
		and safe_evolution != null
		and safe_evolution.kind == "EVOLVE"
		and safe_evolution.source != null
		and safe_evolution.source.card_id == "svi-maus"
		and safe_evolution.target != null
		and safe_evolution.target.slot == "bench_0"
		and int(safe_diagnostics.get("missed_immediate_ko", 1)) == 0,
		"Mandatory tactics skipped a safe Maushold evolution before Greedent's KO: %s"
		% JSON.stringify(colorless_safe_result),
	)

	var self_loss_state := _colorless_reactive_self_loss_state()
	var self_loss_query := engine.query_legal_action_groups(self_loss_state, 0)
	var self_loss_actions: Array[GameAction] = []
	if self_loss_query.success:
		self_loss_actions.assign(self_loss_query.concrete_actions())
	var self_loss_attack: GameAction = null
	for self_loss_candidate in self_loss_actions:
		if (
			self_loss_candidate.kind == "DECLARE_ATTACK"
			and int(self_loss_candidate.payload.get("attack_index", -1)) == 0
		):
			self_loss_attack = self_loss_candidate
			break
	var self_loss_worker := NativeChallengeAI.new()
	var self_loss_selection := self_loss_worker._validated_or_fallback_action(
		self_loss_state,
		0,
		self_loss_attack,
		self_loss_actions,
		"colorless",
		catalog,
		engine,
		TEST_SEED,
	)
	_check(
		self_loss_query.success
		and self_loss_attack != null
		and self_loss_worker._action_immediately_loses_match(
			self_loss_state,
			0,
			self_loss_attack,
			"colorless",
			catalog,
			engine,
			TEST_SEED,
		)
		and self_loss_selection != null
		and self_loss_selection.kind == "EVOLVE"
		and self_loss_selection.source != null
		and self_loss_selection.source.card_id == "svi-maus",
		"Tactical guard accepted a reactive-thorns attack that immediately loses: %s"
		% JSON.stringify(
			self_loss_selection.to_dict() if self_loss_selection != null else {}),
	)
	var self_loss_end: GameAction = null
	for self_loss_candidate in self_loss_actions:
		if self_loss_candidate.kind == "END_TURN":
			self_loss_end = self_loss_candidate
			break
	var self_loss_end_diagnostics := self_loss_worker.diagnose_decision(
		self_loss_state,
		0,
		self_loss_end,
		self_loss_actions,
		"colorless",
		catalog,
		engine,
		TEST_SEED,
	)
	_check(
		self_loss_end != null
		and int(self_loss_end_diagnostics.get(
			"ended_with_productive_attack", 1)) == 0,
		"Diagnostics treated an immediately losing attack as productive",
	)

	var self_damage_state := _lightning_self_damage_escape_state()
	var self_damage_query := engine.query_legal_action_groups(self_damage_state, 0)
	var self_damage_actions: Array[GameAction] = []
	if self_damage_query.success:
		self_damage_actions.assign(self_damage_query.concrete_actions())
	var safe_attack: GameAction = null
	var losing_attack: GameAction = null
	for candidate in self_damage_actions:
		if candidate.kind != "DECLARE_ATTACK":
			continue
		var attack_index := int(candidate.payload.get("attack_index", -1))
		if attack_index == 0:
			safe_attack = candidate
		elif attack_index == 1:
			losing_attack = candidate
	var self_damage_selection := self_loss_worker._validated_or_fallback_action(
		self_damage_state,
		0,
		losing_attack,
		self_damage_actions,
		"lightning",
		catalog,
		engine,
		TEST_SEED,
	)
	_check(
		self_damage_query.success
		and safe_attack != null
		and losing_attack != null
		and self_loss_worker._action_immediately_loses_match(
			self_damage_state,
			0,
			losing_attack,
			"lightning",
			catalog,
			engine,
			TEST_SEED,
		)
		and self_damage_selection != null
		and self_damage_selection.kind == "DECLARE_ATTACK"
		and int(self_damage_selection.payload.get("attack_index", -1)) == 0,
		"Self-KO guard skipped Thundurus's safe attack: %s"
		% JSON.stringify(
			self_damage_selection.to_dict() if self_damage_selection != null else {}),
	)
	if safe_evolution != null:
		var evolved_state := colorless_safe_state.clone_state()
		var evolved_step := engine.apply_action(
			evolved_state, safe_evolution, PortableRandomSource.new(TEST_SEED))
		var evolved_query := engine.query_legal_action_groups(evolved_state, 0)
		var evolved_actions: Array[GameAction] = []
		if evolved_query.success:
			evolved_actions.assign(evolved_query.concrete_actions())
		var evolved_info := AIInformationSet.capture(
			evolved_state, 0, catalog, evolved_actions, [], TEST_SEED)
		var evolved_result := AIMandatoryTactics.new().resolve(
			evolved_info,
			evolved_state,
			0,
			evolved_actions,
			engine,
			registry.strategy_for("colorless"),
			TEST_SEED,
		)
		var evolved_attack: GameAction = evolved_result.get("action")
		_check(
			evolved_step.success
			and bool(evolved_result.get("resolved", false))
			and str(evolved_result.get("reason", "")) == "immediate_knockout"
			and evolved_attack != null
			and evolved_attack.kind == "DECLARE_ATTACK"
			and int(evolved_attack.payload.get("attack_index", -1)) == 1,
			"Mandatory tactics did not revalidate and take the Greedent KO after evolution: %s"
			% JSON.stringify(evolved_result),
		)

	var colorless_win_state := _colorless_pre_knockout_state(6, "svi-tand", 1)
	var colorless_win_query := engine.query_legal_action_groups(colorless_win_state, 0)
	var colorless_win_actions: Array[GameAction] = []
	if colorless_win_query.success:
		colorless_win_actions.assign(colorless_win_query.concrete_actions())
	var colorless_win_info := AIInformationSet.capture(
		colorless_win_state, 0, catalog, colorless_win_actions, [], TEST_SEED)
	var colorless_win_result := AIMandatoryTactics.new().resolve(
		colorless_win_info, colorless_win_state, 0, colorless_win_actions,
		engine, registry.strategy_for("colorless"), TEST_SEED)
	var winning_attack: GameAction = colorless_win_result.get("action")
	_check(
		bool(colorless_win_result.get("resolved", false))
		and str(colorless_win_result.get("reason", "")) == "immediate_match_win"
		and winning_attack != null
		and winning_attack.kind == "DECLARE_ATTACK",
		"Safe pre-KO development delayed an immediate match win: %s"
		% JSON.stringify(colorless_win_result),
	)

	var colorless_threshold_state := _colorless_pre_knockout_state(
		5, "svi-gree", 6)
	var threshold_query := engine.query_legal_action_groups(
		colorless_threshold_state, 0)
	var threshold_actions: Array[GameAction] = []
	if threshold_query.success:
		threshold_actions.assign(threshold_query.concrete_actions())
	var threshold_info := AIInformationSet.capture(
		colorless_threshold_state, 0, catalog, threshold_actions, [], TEST_SEED)
	var threshold_result := AIMandatoryTactics.new().resolve(
		threshold_info, colorless_threshold_state, 0, threshold_actions,
		engine, registry.strategy_for("colorless"), TEST_SEED)
	var threshold_attack: GameAction = threshold_result.get("action")
	_check(
		bool(threshold_result.get("resolved", false))
		and str(threshold_result.get("reason", "")) == "immediate_knockout"
		and threshold_attack != null
		and threshold_attack.kind == "DECLARE_ATTACK",
		"Pre-KO evolution destroyed Greedent's five-card damage threshold: %s"
		% JSON.stringify(threshold_result),
	)

	var survival_draw_state := _fire_lone_active_draw_state(catalog)
	var survival_draw_query := engine.query_legal_action_groups(
		survival_draw_state, 0)
	var survival_draw_actions: Array[GameAction] = []
	if survival_draw_query.success:
		survival_draw_actions.assign(survival_draw_query.concrete_actions())
	var survival_draw_info := AIInformationSet.capture(
		survival_draw_state, 0, catalog, survival_draw_actions, [], TEST_SEED)
	var inferred_pool := survival_draw_info.inferred_hidden_pool_for_perspective()
	var inferred_basic_count := 0
	for inferred_card_id in inferred_pool:
		if catalog.is_basic_pokemon(inferred_card_id):
			inferred_basic_count += 1
	var survival_draw_result := AIMandatoryTactics.new().resolve(
		survival_draw_info,
		survival_draw_state,
		0,
		survival_draw_actions,
		engine,
		registry.strategy_for("fire"),
		TEST_SEED,
	)
	var survival_draw_action: GameAction = survival_draw_result.get("action")
	_check(
		survival_draw_query.success
		and inferred_pool.is_read_only()
		and inferred_pool.size()
		== survival_draw_state.players[0].deck.size()
		+ survival_draw_state.players[0].prizes.size()
		and inferred_basic_count == 7
		and bool(survival_draw_result.get("resolved", false))
		and str(survival_draw_result.get("reason", "")) == "seek_only_backup_out"
		and survival_draw_action != null
		and survival_draw_action.kind == "PLAY_TRAINER"
		and survival_draw_action.source != null
		and survival_draw_action.source.card_id == "sv1-189",
		"Lone Active did not choose Professor's Research as the strongest public Basic out: %s"
		% JSON.stringify(survival_draw_result),
	)

	var imminent_draw_state := survival_draw_state.clone_state()
	var imminent_energy: String = str(
		imminent_draw_state.players[1].active.energy_card_ids.pop_back())
	imminent_draw_state.players[1].deck.append(imminent_energy)
	while imminent_draw_state.players[1].hand.size() < 5:
		imminent_draw_state.players[1].hand.append(
			imminent_draw_state.players[1].deck.pop_back())
	var imminent_draw_query := engine.query_legal_action_groups(
		imminent_draw_state, 0)
	var imminent_draw_actions: Array[GameAction] = []
	if imminent_draw_query.success:
		imminent_draw_actions.assign(imminent_draw_query.concrete_actions())
	var imminent_draw_info := AIInformationSet.capture(
		imminent_draw_state, 0, catalog, imminent_draw_actions, [], TEST_SEED)
	var opponent_public_pool := imminent_draw_info.inferred_hidden_pool_for_player(1)
	var imminent_lethal_probability := (
		AIMandatoryTactics._public_imminent_lethal_attack_probability(
			imminent_draw_info,
			imminent_draw_state,
			0,
			engine,
			CardSemanticCatalog.new(catalog),
		)
	)
	var imminent_draw_result := AIMandatoryTactics.new().resolve(
		imminent_draw_info,
		imminent_draw_state,
		0,
		imminent_draw_actions,
		engine,
		registry.strategy_for("fire"),
		TEST_SEED,
	)
	var imminent_draw_action: GameAction = imminent_draw_result.get("action")
	_check(
		imminent_draw_query.success
		and opponent_public_pool.is_read_only()
		and imminent_lethal_probability
		>= AIMandatoryTactics.IMMINENT_LETHAL_MIN_PROBABILITY
		and opponent_public_pool.size()
		== imminent_draw_state.players[1].hand.size()
		+ imminent_draw_state.players[1].deck.size()
		+ imminent_draw_state.players[1].prizes.size()
		and str(imminent_draw_result.get("reason", ""))
		== "seek_only_backup_out"
		and imminent_draw_action != null
		and imminent_draw_action.kind == "PLAY_TRAINER"
		and imminent_draw_action.source != null
		and imminent_draw_action.source.card_id == "sv1-189",
		"Lone Active ignored a public one-attachment lethal (p=%.4f): %s"
		% [imminent_lethal_probability, JSON.stringify(imminent_draw_result)],
	)
	var opponent_hidden_variant := imminent_draw_state.clone_state()
	if (
		not opponent_hidden_variant.players[1].hand.is_empty()
		and not opponent_hidden_variant.players[1].deck.is_empty()
	):
		var opponent_hidden_swap := opponent_hidden_variant.players[1].hand[0]
		opponent_hidden_variant.players[1].hand[0] = (
			opponent_hidden_variant.players[1].deck[0])
		opponent_hidden_variant.players[1].deck[0] = opponent_hidden_swap
	var opponent_hidden_query := engine.query_legal_action_groups(
		opponent_hidden_variant, 0)
	var opponent_hidden_actions: Array[GameAction] = []
	if opponent_hidden_query.success:
		opponent_hidden_actions.assign(opponent_hidden_query.concrete_actions())
	var opponent_hidden_info := AIInformationSet.capture(
		opponent_hidden_variant, 0, catalog, opponent_hidden_actions, [], TEST_SEED)
	var opponent_hidden_result := AIMandatoryTactics.new().resolve(
		opponent_hidden_info,
		opponent_hidden_variant,
		0,
		opponent_hidden_actions,
		engine,
		registry.strategy_for("fire"),
		TEST_SEED,
	)
	var opponent_hidden_action: GameAction = opponent_hidden_result.get("action")
	_check(
		opponent_hidden_query.success
		and opponent_hidden_info.inferred_hidden_pool_for_player(1)
		== opponent_public_pool
		and opponent_hidden_action != null
		and imminent_draw_action != null
		and _intent_signature(opponent_hidden_action)
		== _intent_signature(imminent_draw_action),
		"Imminent-lethal survival depended on the real opponent hand/top card",
	)

	var two_attachment_state := imminent_draw_state.clone_state()
	two_attachment_state.players[1].active = PokemonState.new("svi-hrot")
	two_attachment_state.players[1].active.placed_this_turn = false
	var two_attachment_query := engine.query_legal_action_groups(
		two_attachment_state, 0)
	var two_attachment_actions: Array[GameAction] = []
	if two_attachment_query.success:
		two_attachment_actions.assign(two_attachment_query.concrete_actions())
	var two_attachment_info := AIInformationSet.capture(
		two_attachment_state, 0, catalog, two_attachment_actions, [], TEST_SEED)
	var two_attachment_result := AIMandatoryTactics.new().resolve(
		two_attachment_info,
		two_attachment_state,
		0,
		two_attachment_actions,
		engine,
		registry.strategy_for("fire"),
		TEST_SEED,
	)
	_check(
		str(two_attachment_result.get("reason", ""))
		!= "seek_only_backup_out",
		"Lone-Active survival treated a two-attachment attack as imminent",
	)

	var hidden_order_variant := survival_draw_state.clone_state()
	hidden_order_variant.players[0].deck.reverse()
	hidden_order_variant.players[0].prizes.reverse()
	if (
		not hidden_order_variant.players[0].deck.is_empty()
		and not hidden_order_variant.players[0].prizes.is_empty()
	):
		var hidden_swap := hidden_order_variant.players[0].deck[0]
		hidden_order_variant.players[0].deck[0] = (
			hidden_order_variant.players[0].prizes[0])
		hidden_order_variant.players[0].prizes[0] = hidden_swap
	var hidden_order_query := engine.query_legal_action_groups(
		hidden_order_variant, 0)
	var hidden_order_actions: Array[GameAction] = []
	if hidden_order_query.success:
		hidden_order_actions.assign(hidden_order_query.concrete_actions())
	var hidden_order_info := AIInformationSet.capture(
		hidden_order_variant, 0, catalog, hidden_order_actions, [], TEST_SEED)
	var hidden_order_result := AIMandatoryTactics.new().resolve(
		hidden_order_info,
		hidden_order_variant,
		0,
		hidden_order_actions,
		engine,
		registry.strategy_for("fire"),
		TEST_SEED,
	)
	var hidden_order_action: GameAction = hidden_order_result.get("action")
	_check(
		hidden_order_action != null
		and survival_draw_action != null
		and _intent_signature(hidden_order_action)
		== _intent_signature(survival_draw_action)
		and hidden_order_info.inferred_hidden_pool_for_perspective()
		== inferred_pool,
		"Lone-Active survival choice depended on real deck/Prize ordering",
	)

	var direct_basic_state := survival_draw_state.clone_state()
	var moved_direct_basic := false
	for hidden_zone in [
		direct_basic_state.players[0].deck,
		direct_basic_state.players[0].prizes,
	]:
		for hidden_index in range(hidden_zone.size()):
			var hidden_card_id := str(hidden_zone[hidden_index])
			if not catalog.is_basic_pokemon(hidden_card_id):
				continue
			hidden_zone.remove_at(hidden_index)
			direct_basic_state.players[0].hand.append(hidden_card_id)
			moved_direct_basic = true
			break
		if moved_direct_basic:
			break
	var direct_basic_query := engine.query_legal_action_groups(direct_basic_state, 0)
	var direct_basic_actions: Array[GameAction] = []
	if direct_basic_query.success:
		direct_basic_actions.assign(direct_basic_query.concrete_actions())
	var direct_basic_info := AIInformationSet.capture(
		direct_basic_state, 0, catalog, direct_basic_actions, [], TEST_SEED)
	var direct_basic_result := AIMandatoryTactics.new().resolve(
		direct_basic_info, direct_basic_state, 0, direct_basic_actions,
		engine, registry.strategy_for("fire"), TEST_SEED)
	var direct_basic_action: GameAction = direct_basic_result.get("action")
	_check(
		moved_direct_basic
		and str(direct_basic_result.get("reason", "")) == "establish_only_backup"
		and direct_basic_action != null
		and direct_basic_action.kind == "PLAY_BASIC",
		"Lone-Active survival drew cards instead of playing a certain Basic backup: %s"
		% JSON.stringify(direct_basic_result),
	)

	var prefer_mareep := func(
		_state: GameState,
		_actor: int,
		action: GameAction,
	) -> float:
		return (
			500.0
			if action.source != null and action.source.card_id == "svl-mare2"
			else 0.0
		)
	var ranked_backup_state := _lightning_ranked_backup_state(6)
	var ranked_backup_query := engine.query_legal_action_groups(
		ranked_backup_state, 0)
	var ranked_backup_actions: Array[GameAction] = []
	if ranked_backup_query.success:
		ranked_backup_actions.assign(ranked_backup_query.concrete_actions())
	var ranked_backup_info := AIInformationSet.capture(
		ranked_backup_state, 0, catalog, ranked_backup_actions, [], TEST_SEED)
	var ranked_backup_result := AIMandatoryTactics.new().resolve(
		ranked_backup_info,
		ranked_backup_state,
		0,
		ranked_backup_actions,
		engine,
		registry.strategy_for("lightning"),
		TEST_SEED,
		Callable(),
		0,
		192,
		Callable(),
		prefer_mareep,
	)
	var ranked_backup_action: GameAction = ranked_backup_result.get("action")

	var reordered_backup_state := ranked_backup_state.clone_state()
	reordered_backup_state.players[0].hand.reverse()
	var reordered_backup_query := engine.query_legal_action_groups(
		reordered_backup_state, 0)
	var reordered_backup_actions: Array[GameAction] = []
	if reordered_backup_query.success:
		reordered_backup_actions.assign(
			reordered_backup_query.concrete_actions())
	var reordered_backup_info := AIInformationSet.capture(
		reordered_backup_state,
		0,
		catalog,
		reordered_backup_actions,
		[],
		TEST_SEED,
	)
	var reordered_backup_result := AIMandatoryTactics.new().resolve(
		reordered_backup_info,
		reordered_backup_state,
		0,
		reordered_backup_actions,
		engine,
		registry.strategy_for("lightning"),
		TEST_SEED,
		Callable(),
		0,
		192,
		Callable(),
		prefer_mareep,
	)
	var reordered_backup_action: GameAction = reordered_backup_result.get(
		"action")
	var reordered_diagnostics := NativeChallengeAI.new().diagnose_decision(
		reordered_backup_state,
		0,
		reordered_backup_action,
		reordered_backup_actions,
		"lightning",
		catalog,
		engine,
		TEST_SEED,
	)
	_check(
		ranked_backup_query.success
		and reordered_backup_query.success
		and ranked_backup_info.is_valid()
		and reordered_backup_info.is_valid()
		and str(ranked_backup_result.get("reason", ""))
		== "establish_only_backup"
		and str(reordered_backup_result.get("reason", ""))
		== "establish_only_backup"
		and ranked_backup_action != null
		and reordered_backup_action != null
		and ranked_backup_action.source != null
		and reordered_backup_action.source != null
		and ranked_backup_action.source.card_id == "svl-mare2"
		and reordered_backup_action.source.card_id == "svl-mare2"
		and int(reordered_diagnostics.get("missed_immediate_ko", 1)) == 0,
		"Ranked lone-Active backup depended on hand index or confused diagnostics: %s / %s"
		% [
			JSON.stringify(ranked_backup_result),
			JSON.stringify(reordered_backup_result),
		],
	)

	var prefer_pikachu_by_sub_epsilon := func(
		_state: GameState,
		_actor: int,
		action: GameAction,
	) -> float:
		return (
			0.0005
			if action.source != null and action.source.card_id == "svl-pikaex"
			else 0.0
		)
	var near_tie_reversed_actions: Array[GameAction] = []
	near_tie_reversed_actions.assign(ranked_backup_actions)
	near_tie_reversed_actions.reverse()
	var near_tie_forward := AIMandatoryTactics.survival_backup_action(
		ranked_backup_state,
		0,
		ranked_backup_actions,
		null,
		null,
		null,
		prefer_pikachu_by_sub_epsilon,
	)
	var near_tie_reversed := AIMandatoryTactics.survival_backup_action(
		ranked_backup_state,
		0,
		near_tie_reversed_actions,
		null,
		null,
		null,
		prefer_pikachu_by_sub_epsilon,
	)
	_check(
		near_tie_forward != null
		and near_tie_reversed != null
		and near_tie_forward.source != null
		and near_tie_reversed.source != null
		and near_tie_forward.source.card_id == "svl-mare2"
		and near_tie_reversed.source.card_id == "svl-mare2",
		"Ranked lone-Active backup near-tie depended on legal-action order: %s / %s"
		% [
			near_tie_forward.to_dict() if near_tie_forward != null else {},
			near_tie_reversed.to_dict() if near_tie_reversed != null else {},
		],
	)

	var flat_trusted_score := func(
		_state: GameState,
		_actor: int,
		_action: GameAction,
	) -> float:
		return 0.0
	var prefer_pikachu_strategy_score := func(
		_info: Dictionary,
		action_row: Dictionary,
		_semantic_catalog: Dictionary,
	) -> float:
		var source_value: Variant = action_row.get("source")
		var card_id := (
			str(Dictionary(source_value).get("card_id", ""))
			if source_value is Dictionary
			else ""
		)
		return 25.0 if card_id == "svl-pikaex" else 0.0
	var strategy_only := {"action_score": prefer_pikachu_strategy_score}
	var strategy_ranked_forward := AIMandatoryTactics.survival_backup_action(
		ranked_backup_state,
		0,
		ranked_backup_actions,
		ranked_backup_info,
		strategy_only,
		catalog,
		flat_trusted_score,
	)
	var strategy_ranked_reversed := AIMandatoryTactics.survival_backup_action(
		ranked_backup_state,
		0,
		near_tie_reversed_actions,
		ranked_backup_info,
		strategy_only,
		catalog,
		flat_trusted_score,
	)
	_check(
		strategy_ranked_forward != null
		and strategy_ranked_reversed != null
		and strategy_ranked_forward.source != null
		and strategy_ranked_reversed.source != null
		and strategy_ranked_forward.source.card_id == "svl-pikaex"
		and strategy_ranked_reversed.source.card_id == "svl-pikaex",
		"Ranked lone-Active backup ignored the deck strategy score: %s / %s"
		% [
			strategy_ranked_forward.to_dict()
			if strategy_ranked_forward != null else {},
			strategy_ranked_reversed.to_dict()
			if strategy_ranked_reversed != null else {},
		],
	)

	var ranked_win_state := _lightning_ranked_backup_state(1)
	var ranked_win_query := engine.query_legal_action_groups(ranked_win_state, 0)
	var ranked_win_actions: Array[GameAction] = []
	if ranked_win_query.success:
		ranked_win_actions.assign(ranked_win_query.concrete_actions())
	var ranked_win_info := AIInformationSet.capture(
		ranked_win_state, 0, catalog, ranked_win_actions, [], TEST_SEED)
	var ranked_win_result := AIMandatoryTactics.new().resolve(
		ranked_win_info,
		ranked_win_state,
		0,
		ranked_win_actions,
		engine,
		registry.strategy_for("lightning"),
		TEST_SEED,
		Callable(),
		0,
		192,
		Callable(),
		prefer_mareep,
	)
	var ranked_win_action: GameAction = ranked_win_result.get("action")
	_check(
		ranked_win_query.success
		and ranked_win_info.is_valid()
		and str(ranked_win_result.get("reason", "")) == "immediate_match_win"
		and ranked_win_action != null
		and ranked_win_action.kind == "DECLARE_ATTACK",
		"Ranked survival backup displaced an immediate match win: %s"
		% JSON.stringify(ranked_win_result),
	)

	var no_public_out_state := survival_draw_state.clone_state()
	no_public_out_state.public_deck_keys[0] = "custom-unknown"
	var no_public_out_query := engine.query_legal_action_groups(no_public_out_state, 0)
	var no_public_out_actions: Array[GameAction] = []
	if no_public_out_query.success:
		no_public_out_actions.assign(no_public_out_query.concrete_actions())
	var no_public_out_info := AIInformationSet.capture(
		no_public_out_state, 0, catalog, no_public_out_actions, [], TEST_SEED)
	var no_public_out_result := AIMandatoryTactics.new().resolve(
		no_public_out_info, no_public_out_state, 0, no_public_out_actions,
		engine, registry.strategy_for("fire"), TEST_SEED)
	_check(
		str(no_public_out_result.get("reason", "")) != "seek_only_backup_out",
		"Unknown deck list manufactured a hidden Basic out",
	)

	var nonlethal_threat_state := survival_draw_state.clone_state()
	nonlethal_threat_state.players[0].active.damage_counters = 0
	var nonlethal_query := engine.query_legal_action_groups(nonlethal_threat_state, 0)
	var nonlethal_actions: Array[GameAction] = []
	if nonlethal_query.success:
		nonlethal_actions.assign(nonlethal_query.concrete_actions())
	var nonlethal_info := AIInformationSet.capture(
		nonlethal_threat_state, 0, catalog, nonlethal_actions, [], TEST_SEED)
	var nonlethal_result := AIMandatoryTactics.new().resolve(
		nonlethal_info, nonlethal_threat_state, 0, nonlethal_actions,
		engine, registry.strategy_for("fire"), TEST_SEED)
	_check(
		str(nonlethal_result.get("reason", "")) != "seek_only_backup_out",
		"Lone-Active survival forced a draw without a public lethal threat",
	)

	var worker := NativeChallengeAI.new()
	var latios_state := _planner_state()
	latios_state.set_type_matchups_enabled(false)
	latios_state.public_deck_keys = ["psychic", "lightning"]
	latios_state.players[0].active = PokemonState.new("sv1-111")
	latios_state.players[0].active.placed_this_turn = false
	latios_state.players[0].active.energy_card_ids.assign([
		"sv1-ener-5", "sv1-ener-5", "sv1-ener-5"])
	latios_state.players[1].active = PokemonState.new("svl-pikaex")
	latios_state.players[1].active.damage_counters = 17
	latios_state.players[1].bench[0] = PokemonState.new("sv2-staryu")
	latios_state.players[1].bench[0].placed_this_turn = false
	var latios_low_query := engine.query_legal_action_groups(latios_state, 0)
	var latios_low_actions: Array[GameAction] = []
	if latios_low_query.success:
		latios_low_actions.assign(latios_low_query.concrete_actions())
	var latios_low_ko := worker._best_immediate_ko_attack(
		latios_state, 0, latios_low_actions, "psychic", catalog,
		engine, TEST_SEED)
	_check(
		latios_low_query.success
		and latios_low_ko != null
		and latios_low_ko.attack_index() == 0,
		"Immediate-KO tactics spent three Energy on Latios overkill",
	)
	latios_state.players[1].active.damage_counters = 1
	var latios_high_query := engine.query_legal_action_groups(latios_state, 0)
	var latios_high_actions: Array[GameAction] = []
	if latios_high_query.success:
		latios_high_actions.assign(latios_high_query.concrete_actions())
	var latios_high_ko := worker._best_immediate_ko_attack(
		latios_state, 0, latios_high_actions, "psychic", catalog,
		engine, TEST_SEED + 1)
	_check(
		latios_high_query.success
		and latios_high_ko != null
		and latios_high_ko.attack_index() == 1,
		"Immediate-KO tactics refused Latios's necessary 180-damage attack",
	)
	var latios_high_info := AIInformationSet.capture(
		latios_state, 0, catalog, latios_high_actions, [], TEST_SEED + 1)
	var latios_low_budget_result := AIMandatoryTactics.new().resolve(
		latios_high_info,
		latios_state,
		0,
		latios_high_actions,
		engine,
		registry.strategy_for("psychic"),
		TEST_SEED + 1,
		func() -> bool: return false,
		Time.get_ticks_usec() + 500000,
		1,
	)
	var latios_low_budget_action: GameAction = latios_low_budget_result.get("action")
	_check(
		bool(latios_low_budget_result.get("resolved", false))
		and str(latios_low_budget_result.get("reason", "")) in [
			"immediate_knockout", "immediate_match_win"]
		and latios_low_budget_action != null
		and latios_low_budget_action.attack_index() == 1,
		"One-node tactical replan missed a deterministic KO in the second attack slot: %s"
		% JSON.stringify(latios_low_budget_result),
	)

	var clean_light_effects: Array = Dictionary(
		catalog.get_card("sv1-111").get("attacks", [])[1]).get("effects", [])
	latios_state.players[1].active.energy_card_ids.clear()
	var clean_value_no_opponent_energy := worker._semantic_effects_tactical_value(
		latios_state, 0, clean_light_effects, "active", catalog, "psychic")
	latios_state.players[1].active.energy_card_ids.assign([
		"sv1-ener-4", "sv1-ener-4", "sv1-ener-4"])
	var clean_value_with_opponent_energy := worker._semantic_effects_tactical_value(
		latios_state, 0, clean_light_effects, "active", catalog, "psychic")
	_check(
		clean_value_no_opponent_energy < 0.0
		and is_equal_approx(
			clean_value_no_opponent_energy, clean_value_with_opponent_energy),
		"Self Energy discard was still valued as opponent Energy disruption",
	)

	var glastrier_state := _planner_state()
	glastrier_state.set_type_matchups_enabled(false)
	glastrier_state.public_deck_keys = ["water", "psychic"]
	glastrier_state.players[0].active = PokemonState.new("sv2-glast")
	glastrier_state.players[0].active.placed_this_turn = false
	glastrier_state.players[0].active.energy_card_ids.assign([
		"sv1-ener-3", "sv1-ener-3", "sv1-ener-3"])
	glastrier_state.players[1].active = PokemonState.new("sv1-110")
	glastrier_state.players[1].active.damage_counters = 8
	var glastrier_query := engine.query_legal_action_groups(glastrier_state, 0)
	var glastrier_actions: Array[GameAction] = []
	if glastrier_query.success:
		glastrier_actions.assign(glastrier_query.concrete_actions())
	var glastrier_ko := worker._best_immediate_ko_attack(
		glastrier_state, 0, glastrier_actions, "water", catalog,
		engine, TEST_SEED + 2)
	_check(
		glastrier_query.success
		and glastrier_ko != null
		and glastrier_ko.attack_index() == 0,
		"Immediate-KO tactics chose Glastrier self-damage over an exact knockout",
	)

	var pikachu_state := _planner_state()
	pikachu_state.set_type_matchups_enabled(false)
	pikachu_state.public_deck_keys = ["lightning", "water"]
	pikachu_state.players[0].active = PokemonState.new("svl-pikaex")
	pikachu_state.players[0].active.energy_card_ids.assign([
		"sv1-ener-4", "sv1-ener-4", "sv1-ener-4"])
	var pikachu_effects: Array = Dictionary(
		catalog.get_card("svl-pikaex").get("attacks", [])[1]).get("effects", [])
	var expected_tails_cost := worker._expected_self_energy_discard_cost(
		pikachu_state, 0, pikachu_effects, "active", catalog)
	var full_discard_cost := worker._self_energy_discard_cost(
		pikachu_state, 0, "active", 99, catalog)
	_check(
		is_equal_approx(expected_tails_cost, full_discard_cost * 0.5),
		"Pikachu's tails-only Energy loss was not probability weighted",
	)

	var lucario_state := _planner_state()
	lucario_state.set_type_matchups_enabled(false)
	lucario_state.public_deck_keys = ["fighting", "water"]
	lucario_state.players[0].active = PokemonState.new("svf-luca")
	lucario_state.players[0].active.energy_card_ids.assign([
		"sv1-ener-6", "svg2-lume"])
	var lucario_snapshot := lucario_state.snapshot()
	var lucario_effects: Array = Dictionary(
		catalog.get_card("svf-luca").get("attacks", [])[0]).get("effects", [])
	_check(
		worker._estimated_attack_damage(lucario_state, 0, 0, catalog) == 130
		and worker._expected_self_energy_discard_cost(
			lucario_state, 0, lucario_effects, "active", catalog) > 0.0
		and lucario_state.snapshot() == lucario_snapshot,
		"Lucario did not count a standalone Luminous Energy as Fighting material",
	)
	lucario_state.players[0].active.energy_card_ids.assign([
		"sv1-ener-6", "sv1-ener-6", "sv1-ener-6"])
	lucario_snapshot = lucario_state.snapshot()
	var lucario_productive := worker._best_productive_attack_candidate(
		lucario_state,
		0,
		[GameAction.create(
			"DECLARE_ATTACK", {"attack_index": 0}, 0,
			EntityRef.new(
				"pokemon", 0, "", "active", -1, "", "svf-luca"))],
		"fighting",
		catalog,
	)
	_check(
		worker._best_pokemon_damage(
			lucario_state.players[0].active, catalog) == 190
		and lucario_productive != null
		and worker._expected_self_energy_discard_cost(
			lucario_state, 0, lucario_effects, "active", catalog) > 0.0
		and lucario_state.snapshot() == lucario_snapshot,
		"Lucario's three-Energy 190 attack was mispriced as unproductive",
	)
	lucario_state.players[0].active.energy_card_ids.assign([
		"sv1-ener-6", "svg2-lume", "svi-jete"])
	lucario_snapshot = lucario_state.snapshot()
	_check(
		worker._estimated_attack_damage(lucario_state, 0, 0, catalog) == 70
		and worker._expected_self_energy_discard_cost(
			lucario_state, 0, lucario_effects, "active", catalog) > 0.0
		and lucario_state.snapshot() == lucario_snapshot,
		"Lucario ignored Luminous downgrade in its damage/resource estimate",
	)
	lucario_state.players[0].active.energy_card_ids.assign([
		"sv1-ener-5", "sv1-ener-5"])
	_check(
		worker._estimated_attack_damage(lucario_state, 0, 0, catalog) == 10
		and is_zero_approx(worker._expected_self_energy_discard_cost(
			lucario_state, 0, lucario_effects, "active", catalog)),
		"Lucario charged a Fighting discard cost for non-Fighting attachments",
	)


func _check_repeatable_ability_turn_guard(catalog: CardCatalog) -> void:
	var state := GameState.new()
	state.phase = "MAIN"
	state.setup_stage = GameState.SETUP_COMPLETE
	state.setup_ready = [true, true]
	state.turn_number = 9
	state.active_player_idx = 0
	state.public_deck_keys = ["steel", "fire"]
	state.players[0].active = PokemonState.new("svm-bronzong")
	state.players[0].active.placed_this_turn = false
	state.action_log = [
		"玩家1 使用了特性「金属转移」。",
		"—— 玩家1的第9回合 ——",
	]
	for index in range(NativeChallengeAI.MAX_REPEATABLE_ABILITY_USES_PER_TURN):
		state.action_log.append(
			"玩家1 使用了特性「金属转移」。"
			if index % 2 == 0
			else "青铜钟使用特性金属转移。"
		)
	var ability := GameAction.create(
		"USE_ABILITY",
		{"ability_name": "金属转移"},
		0,
		EntityRef.new("pokemon", 0, "", "active", -1, "", "svm-bronzong"),
	)
	var end_turn := GameAction.create("END_TURN", {}, 0)
	var supplied: Array[GameAction] = [ability, end_turn]
	var worker := NativeChallengeAI.new()
	var filtered := worker._filter_exhausted_repeatable_abilities(
		state, 0, supplied, catalog)
	_check(
		filtered.size() == 1 and filtered[0].kind == "END_TURN",
		"Traditional AI did not cap a repeatable ability across local replans",
	)
	state.action_log.pop_back()
	var reproducible_a := worker._filter_exhausted_repeatable_abilities(
		state, 0, supplied, catalog)
	var reproducible_b := worker._filter_exhausted_repeatable_abilities(
		state, 0, supplied, catalog)
	_check(
		reproducible_a.size() == 2
		and reproducible_a == reproducible_b,
		"Repeatable-ability guard is stateful or counted a previous turn",
	)


func _check_planner_contract(
	state: GameState,
	information_set: AIInformationSet,
	registry: AIStrategyRegistry,
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	if information_set == null or not information_set.is_valid() or not registry.is_valid():
		return
	var query := engine.query_legal_action_groups(state, 0)
	_check(query.success, "Planner fixture legal-action query failed: %s" % query.message)
	if not query.success:
		return
	var legal: Array[GameAction] = []
	legal.assign(query.concrete_actions())
	_check(legal.size() >= 2,
		"Planner fixture must expose at least two legal actions")
	if legal.is_empty():
		return
	var request := {
		"mode": "challenge",
		"seed": TEST_SEED,
		"belief_samples": 1,
		"state": {
			"sentinel": "request.state must never be read",
			"apply_type_matchups": true,
		},
	}
	var strategy := registry.strategy_for("fire")
	_check_sample_zero_reuse_equivalence(
		information_set, legal, strategy, catalog)
	var plan_a := TraditionalTurnPlanner.plan_action(
		request,
		information_set,
		legal,
		strategy,
		catalog,
		engine,
		func() -> bool: return false,
	)
	var bait_request := request.duplicate(true)
	bait_request["state"] = {
		"players": [{"hand": ["private-bait-a"]}, {"deck": ["private-bait-b"]}],
		"rules_options": {"apply_type_matchups": true},
		"revision": 999999,
	}
	var plan_b := TraditionalTurnPlanner.plan_action(
		bait_request,
		information_set,
		legal,
		strategy,
		catalog,
		engine,
		func() -> bool: return false,
	)
	var paced_plan := TraditionalTurnPlanner.plan_action(
		request,
		information_set,
		legal,
		strategy,
		catalog,
		engine,
		func() -> bool:
			OS.delay_usec(50)
			return false,
	)
	_check(
		bool(plan_a.get("success", false))
		and bool(plan_b.get("success", false)),
		"TraditionalTurnPlanner failed its fixed-seed planner fixture: %s / %s" % [
			plan_a.get("error", ""), plan_b.get("error", "")],
	)
	if not bool(plan_a.get("success", false)) or not bool(plan_b.get("success", false)):
		return
	var selected_a: GameAction = plan_a.get("action")
	var selected_b: GameAction = plan_b.get("action")
	_check(_is_supplied_legal_action(selected_a, legal),
		"TraditionalTurnPlanner returned an action outside the legal root set")
	_check(
		int(plan_a.get("nodes_expanded", 0)) > 0
		and int(plan_a.get("nodes_expanded", 0))
			== int(plan_b.get("nodes_expanded", -1)),
		"TraditionalTurnPlanner fixed work was missing or not reproducible")
	var cached_steps: Array = plan_a.get("turn_plan", [])
	var steps_have_preconditions := not cached_steps.is_empty()
	for step_value in cached_steps:
		if not step_value is Dictionary:
			steps_have_preconditions = false
			break
		var step_row: Dictionary = step_value
		if (
			str(step_row.get("expected_public_fingerprint", "")).is_empty()
			or not step_row.has("expected_actor")
			or str(step_row.get("expected_phase", "")).is_empty()
		):
			steps_have_preconditions = false
			break
	_check(steps_have_preconditions,
		"TraditionalTurnPlanner emitted a cache step without a public-state precondition")
	_check(
		_intent_signature(selected_a) == _intent_signature(selected_b)
		and plan_a.get("turn_plan", []) == plan_b.get("turn_plan", []),
		"TraditionalTurnPlanner read or was influenced by bait request.state",
	)
	_check(
		bool(paced_plan.get("success", false))
		and _intent_signature(selected_a)
			== _intent_signature(paced_plan.get("action"))
		and int(plan_a.get("nodes_expanded", -1))
			== int(paced_plan.get("nodes_expanded", -2))
		and int(plan_a.get("completed_depth", -1))
			== int(paced_plan.get("completed_depth", -2))
		and str(plan_a.get("completion_reason", ""))
			== str(paced_plan.get("completion_reason", ""))
		and str(plan_a.get("trajectory_hash", "")).length() == 64
		and str(plan_a.get("trajectory_hash", ""))
			== str(paced_plan.get("trajectory_hash", "")),
		"Injected execution pacing changed fixed-work search quality or result",
	)
	_check(
		int(plan_a.get("belief_samples", 0)) in [1, 2, 3]
		and int(plan_a.get("belief_consensus", 0)) >= 1,
		"TraditionalTurnPlanner did not report bounded seeded belief sampling",
	)
	var fair_request := request.duplicate(true)
	fair_request["belief_samples"] = 3
	fair_request["internal_evaluation_smoke"] = true
	fair_request["skip_mandatory"] = true
	var fair_plan := TraditionalTurnPlanner.plan_action(
		fair_request,
		information_set,
		legal,
		strategy,
		catalog,
		engine,
		func() -> bool: return false,
	)
	var fair_counts: Dictionary = fair_plan.get("root_sample_counts", {})
	var every_root_saw_every_seed := not fair_counts.is_empty()
	for count_value in fair_counts.values():
		if int(count_value) != 3:
			every_root_saw_every_seed = false
			break
	_check(
		bool(fair_plan.get("success", false))
		and int(fair_plan.get("belief_samples", 0)) == 3
		and every_root_saw_every_seed
		and str(fair_plan.get("belief_seed_hash", "")).length() == 64,
		"TraditionalTurnPlanner did not compare every root on the same three belief seeds",
	)
	var shallow_high := {"depth": 2, "score_milli": 999999, "sequence": []}
	var deep_low := {"depth": 3, "score_milli": -999999, "sequence": []}
	_check(
		AITurnBeamPlanner._better_partial_node(
			shallow_high, deep_low) == deep_low,
		"TraditionalTurnPlanner selected an earlier partial layer over the last complete layer",
	)
	_check(
		TraditionalTurnPlanner._belief_row_descending(
			{
				"count": 3,
				"score_total_milli": 300,
				"worst_score_milli": 50,
				"signature": "b",
			},
			{
				"count": 3,
				"score_total_milli": 300,
				"worst_score_milli": 40,
				"signature": "a",
			},
		),
		"Belief aggregation did not use worst-sample score after an integer mean tie",
	)
	_check(
		bool(plan_a.get("search_depth_applicable", false))
		and int(plan_a.get("requested_depth", 0)) == 8
		and int(plan_a.get("completed_depth", 0)) >= 1
		and str(plan_a.get("completion_reason", ""))
			in ["depth_complete", "frontier_exhausted"],
		"TraditionalTurnPlanner did not expose completed fixed search layers",
	)
	_check(
		not bool(plan_a.get("reply_depth_applicable", false))
		or (
			str(plan_a.get("opponent_strategy_id", ""))
				== str(registry.strategy_for("water").strategy_id())
			and int(plan_a.get("reply_requested_depth", 0)) == 3
			and str(plan_a.get("reply_completion_reason", ""))
				in ["depth_complete", "frontier_exhausted"]
			and (
				str(plan_a.get("reply_completion_reason", ""))
					== "frontier_exhausted"
				or int(plan_a.get("reply_completed_depth", 0)) == 3
			)
		),
		"Opponent reply search did not use the opponent deck's actual strategy",
	)
	var failed_search_fallback := TraditionalTurnPlanner._fallback_result(
		state,
		0,
		legal,
		information_set,
		strategy,
		catalog,
		Callable(),
		7,
		"injected_planner_failure",
		information_set.cache_precondition(),
	)
	_check(
		bool(failed_search_fallback.get("success", false))
		and bool(failed_search_fallback.get("search_depth_applicable", false))
		and int(failed_search_fallback.get("search_depth_completed", -1)) == 0
		and str(failed_search_fallback.get("completion_reason", "")) == "error"
		and str(failed_search_fallback.get("error", ""))
			== "injected_planner_failure",
		"A legal planner-error fallback could bypass fixed-depth evidence",
	)
	var invalid_supplied: Array[GameAction] = [
		GameAction.create("END_TURN", {}, 1),
	]
	var rejected := TraditionalTurnPlanner.plan_action(
		request,
		information_set,
		invalid_supplied,
		strategy,
		catalog,
		engine,
		func() -> bool: return false,
	)
	_check(
		not bool(rejected.get("success", true))
		and str(rejected.get("error", "")) == "no_authoritative_legal_action",
		"TraditionalTurnPlanner trusted a caller-supplied action outside the authoritative legal set",
	)
	var legacy_time_bait := request.duplicate(true)
	legacy_time_bait["time_budget_ms"] = 1
	legacy_time_bait["seconds"] = 0.000001
	legacy_time_bait["node_budget"] = 1
	var time_independent_plan := TraditionalTurnPlanner.plan_action(
		legacy_time_bait,
		information_set,
		legal,
		strategy,
		catalog,
		engine,
		func() -> bool: return false,
	)
	_check(
		bool(time_independent_plan.get("success", false))
		and _intent_signature(time_independent_plan.get("action"))
			== _intent_signature(plan_a.get("action"))
		and int(time_independent_plan.get("nodes_expanded", -1))
			== int(plan_a.get("nodes_expanded", 0))
		and int(time_independent_plan.get("completed_depth", -1))
			== int(plan_a.get("completed_depth", 0))
		and str(time_independent_plan.get("completion_reason", ""))
			== str(plan_a.get("completion_reason", ""))
		and str(time_independent_plan.get("trajectory_hash", ""))
			== str(plan_a.get("trajectory_hash", "")),
		"Legacy time/node bait changed the fixed-work planner result",
	)
	var action_rows: Array = []
	for action in legal:
		action_rows.append(action.to_dict())
	var native_request := {
		"kind": "action",
		"engine": "turn_beam_v2",
		"state": state.snapshot(),
		"actor": 0,
		"revision": state.revision,
		"request_id": "native-determinism",
		"mode": "challenge",
		"deck_key": "fire",
		"match_seed": TEST_SEED,
		"seed": TEST_SEED,
		"actions": action_rows,
	}
	var native_decision := NativeChallengeAI.new().decide(
		native_request, func() -> bool: return false)
	var script_request := native_request.duplicate(true)
	script_request["disable_native_math"] = true
	var script_decision := NativeChallengeAI.new().decide(
		script_request, func() -> bool: return false)
	_check(
		bool(native_decision.get("success", false))
		and bool(script_decision.get("success", false))
		and _intent_signature(GameAction.from_dict(native_decision["action"]))
			== _intent_signature(GameAction.from_dict(script_decision["action"]))
		and int(native_decision.get("nodes_expanded", -1))
			== int(script_decision.get("nodes_expanded", -2))
		and int(native_decision.get("completed_depth", -1))
			== int(script_decision.get("completed_depth", -2))
		and str(native_decision.get("trajectory_hash", "")).length() == 64
		and str(native_decision.get("trajectory_hash", ""))
			== str(script_decision.get("trajectory_hash", "")),
		"Native-math availability changed the fixed-work search trace",
	)

	var hidden_state := state.clone_state()
	hidden_state.players[0].deck = ["sv2-38", "sv2-39", "sv2-grex"]
	hidden_state.players[0].prizes = ["sv2-staryu", "sv2-starm"]
	hidden_state.players[1].hand = ["svi-chim", "svi-monf"]
	hidden_state.players[1].deck = ["svi-infr", "svi-ente", "svi-hrot", "svi-chiy"]
	hidden_state.players[1].prizes = ["svi-sqwk", "sv1-ener-2"]
	var hidden_information := AIInformationSet.capture(hidden_state, 0, catalog)
	var hidden_plan := TraditionalTurnPlanner.plan_action(
		request,
		hidden_information,
		legal,
		strategy,
		catalog,
		engine,
		func() -> bool: return false,
	)
	_check(
		bool(hidden_plan.get("success", false))
		and _intent_signature(selected_a) == _intent_signature(hidden_plan.get("action"))
		and plan_a.get("turn_plan", []) == hidden_plan.get("turn_plan", [])
		and is_equal_approx(
			float(plan_a.get("score", 0.0)), float(hidden_plan.get("score", 1.0))),
		"TraditionalTurnPlanner changed after only hidden card identities changed",
	)

	var matchup_catalog := CardCatalog.new(true)
	for card_id in ["svi-ente", "sv2-38"]:
		var altered_card := matchup_catalog.get_card(card_id).duplicate(true)
		altered_card["weaknesses"] = [{"energy_type": "Any", "value": "x99"}]
		altered_card["resistances"] = [{"energy_type": "Any", "value": "-999"}]
		matchup_catalog.cards[card_id] = altered_card
	var matchup_engine := GameEngine.new(matchup_catalog)
	var matchup_information := AIInformationSet.capture(state, 0, matchup_catalog)
	var matchup_query := matchup_engine.query_legal_action_groups(state, 0)
	var matchup_legal: Array[GameAction] = []
	if matchup_query.success:
		matchup_legal.assign(matchup_query.concrete_actions())
	var matchup_plan := TraditionalTurnPlanner.plan_action(
		request,
		matchup_information,
		matchup_legal,
		strategy,
		matchup_catalog,
		matchup_engine,
		func() -> bool: return false,
	)
	_check(
		matchup_query.success
		and bool(matchup_plan.get("success", false))
		and _intent_signature(selected_a) == _intent_signature(matchup_plan.get("action"))
		and is_equal_approx(
			float(plan_a.get("score", 0.0)), float(matchup_plan.get("score", 1.0))),
		"Weakness/resistance metadata influenced Challenge AI candidates or result",
	)

	var attachment: GameAction
	for action in legal:
		if action.kind == "ATTACH_ENERGY":
			attachment = action
			break
	_check(attachment != null,
		"Planner fixture did not expose an attachment for turn-intent matching")
	if attachment == null:
		return
	var intent := TraditionalTurnPlanner.action_intent(attachment)
	var revised_wire := attachment.to_dict()
	revised_wire["base_revision"] = attachment.base_revision + 7
	revised_wire["action_id"] = "revised-action-id"
	if revised_wire.get("source") is Dictionary:
		var revised_source: Dictionary = revised_wire["source"]
		revised_source["index"] = int(revised_source.get("index", 0)) + 3
	var revised_attachment := GameAction.from_dict(revised_wire)
	var revised_actions: Array[GameAction] = [revised_attachment]
	var matched := TraditionalTurnPlanner.find_matching_action(
		intent, revised_actions, information_set)
	_check(
		matched == revised_attachment
		and _intent_signature(attachment) == _intent_signature(revised_attachment),
		"TraditionalTurnPlanner turn intent did not survive revision/reindexing",
	)


func _check_sample_zero_reuse_equivalence(
	information_set: AIInformationSet,
	supplied_actions: Array[GameAction],
	strategy: Variant,
	catalog: CardCatalog,
) -> void:
	var actor := information_set.perspective_player()
	var seed := TEST_SEED + 509
	var root_state := information_set.sample_state(seed)
	if root_state == null:
		_check(false, "Sample-0 reuse fixture could not determinize its root")
		return
	root_state.set_type_matchups_enabled(false)
	var legal_actions := TraditionalTurnPlanner._validated_legal_actions(
		root_state,
		actor,
		supplied_actions,
		GameEngine.new(catalog),
		information_set,
	)
	if legal_actions.is_empty():
		_check(false, "Sample-0 reuse fixture had no validated roots")
		return
	var config := TraditionalTurnPlanner._planner_config_from_request({
		"seed": seed,
		"belief_samples": 1,
		"skip_mandatory": true,
	})
	var ranked_roots := AIPositionEvaluator.ranked_actions(
		root_state,
		actor,
		legal_actions,
		strategy,
		CardSemanticCatalog.new(catalog),
		catalog,
		information_set.match_seed(),
	)
	var fixed_roots := AIPositionEvaluator.diverse_top_actions(
		ranked_roots,
		int(config.get(
			"root_actions", AITurnBeamPlanner.DEFAULT_ROOT_ACTIONS)),
	)
	var fixed_root_signatures: Array[String] = []
	for root_value in fixed_roots:
		var root: Dictionary = root_value
		var signature := str(root.get("signature", ""))
		if not signature.is_empty():
			fixed_root_signatures.append(signature)
	config["fixed_root_signatures"] = fixed_root_signatures
	var rank_calls := {"cold": 0, "reused": 0}
	var cold_evaluator := func(
		_state: GameState,
		_actor: int,
		_action: GameAction,
	) -> Variant:
		rank_calls["cold"] = int(rank_calls["cold"]) + 1
		return null
	var reused_evaluator := func(
		_state: GameState,
		_actor: int,
		_action: GameAction,
	) -> Variant:
		rank_calls["reused"] = int(rank_calls["reused"]) + 1
		return null
	var reuse_context := {
		"seed": seed,
		"actor": actor,
		"state_revision": root_state.revision,
		"catalog_source_id": int(catalog.get_instance_id()),
		"information_binding": AITurnBeamPlanner._information_binding(
			information_set.cache_precondition()),
		"match_seed": information_set.match_seed(),
		"root_actions_binding": AITurnBeamPlanner._root_actions_binding(
			legal_actions),
		"strategy_binding": AITurnBeamPlanner._variant_binding(strategy),
		"trusted_action_evaluator_binding":
			AITurnBeamPlanner._variant_binding(reused_evaluator),
		"ranked_roots_binding":
			AITurnBeamPlanner._ranked_roots_binding(ranked_roots),
		"root_state": root_state,
		"ranked_roots": ranked_roots,
	}
	var cold_beam := AITurnBeamPlanner.new().plan(
		information_set,
		actor,
		legal_actions,
		GameEngine.new(catalog),
		strategy,
		config,
		Callable(),
		Callable(),
		Callable(),
		cold_evaluator,
		{},
	)
	var reused_beam := AITurnBeamPlanner.new().plan(
		information_set,
		actor,
		legal_actions,
		GameEngine.new(catalog),
		strategy,
		config,
		Callable(),
		Callable(),
		Callable(),
		reused_evaluator,
		reuse_context,
	)
	_check(
		bool(cold_beam.get("success", false))
		and bool(reused_beam.get("success", false))
		and int(rank_calls["cold"])
			== int(rank_calls["reused"]) + legal_actions.size()
		and _search_result_wire(cold_beam) == _search_result_wire(reused_beam),
		(
			(
				"Sample-0 reused beam changed action, full root plans/order, "
				+ "depth/layers/nodes, completion reasons or trajectory hash "
				+ "(rank calls cold=%d reused=%d roots=%d, result_equal=%s)"
			) % [
				int(rank_calls["cold"]),
				int(rank_calls["reused"]),
				legal_actions.size(),
				str(_search_result_wire(cold_beam)
					== _search_result_wire(reused_beam)),
			]
		),
	)
	var stale_evaluator := func(
		_state: GameState,
		_actor: int,
		_action: GameAction,
	) -> Variant:
		rank_calls["stale"] = int(rank_calls.get("stale", 0)) + 1
		return null
	var stale_context := reuse_context.duplicate(true)
	stale_context["match_seed"] = information_set.match_seed() + 1
	stale_context["trusted_action_evaluator_binding"] = (
		AITurnBeamPlanner._variant_binding(stale_evaluator))
	var stale_beam := AITurnBeamPlanner.new().plan(
		information_set,
		actor,
		legal_actions,
		GameEngine.new(catalog),
		strategy,
		config,
		Callable(),
		Callable(),
		Callable(),
		stale_evaluator,
		stale_context,
	)
	_check(
		_search_result_wire(stale_beam) == _search_result_wire(cold_beam)
		and int(rank_calls.get("stale", 0)) == int(rank_calls["cold"]),
		"Stale sample-0 handoff did not automatically use the cold path",
	)
	_check(
		AITurnBeamPlanner._variant_binding({
			"action_score": cold_evaluator,
		}) != AITurnBeamPlanner._variant_binding({
			"action_score": reused_evaluator,
		}),
		"Dictionary strategies with different hooks shared a handoff binding",
	)

	# Exercise the facade as well so belief aggregation and its seed hash are
	# covered in addition to the beam's complete per-root result.
	var facade_request := {
		"seed": seed,
		"belief_samples": 3,
		"internal_evaluation_smoke": true,
	}
	var reused_facade := TraditionalTurnPlanner.plan_action(
		facade_request,
		information_set,
		supplied_actions,
		strategy,
		catalog,
		GameEngine.new(catalog),
	)
	var cold_facade := TraditionalTurnPlanner.plan_action(
		facade_request,
		information_set,
		supplied_actions,
		strategy,
		catalog,
		GameEngine.new(catalog),
		Callable(),
		Callable(),
		Callable(),
		Callable(),
		false,
	)
	_check(
		bool(cold_facade.get("success", false))
		and bool(reused_facade.get("success", false))
		and bool(cold_facade.get("search_depth_applicable", false))
		and bool(reused_facade.get("search_depth_applicable", false))
		and _search_result_wire(cold_facade)
			== _search_result_wire(reused_facade),
		(
			"Sample-0 reuse changed the complete facade result, including "
			+ "belief counts/seed hash or trajectory hash"
		),
	)


func _search_result_wire(value: Variant) -> Variant:
	if value is GameAction:
		return value.to_dict()
	if value is Dictionary:
		var result := {}
		for key in Dictionary(value).keys():
			result[key] = _search_result_wire(Dictionary(value)[key])
		return result
	if value is Array:
		var result: Array = []
		for item in Array(value):
			result.append(_search_result_wire(item))
		return result
	return value


func _planner_state() -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.setup_stage = GameState.SETUP_COMPLETE
	state.setup_ready = [true, true]
	state.setup_actor_idx = -1
	state.turn_number = 3
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.revision = 17
	state.public_deck_keys = ["fire", "water"]
	state.set_type_matchups_enabled(true)
	state.players[0].active = PokemonState.new("svi-ente")
	state.players[0].active.placed_this_turn = false
	state.players[0].hand = ["sv1-ener-2"]
	state.players[0].deck = ["svi-chim", "svi-monf", "svi-infr"]
	state.players[0].prizes = ["svi-hrot", "svi-chiy"]
	state.players[0].discard = ["sv1-176"]
	state.players[1].active = PokemonState.new("sv2-38")
	state.players[1].active.placed_this_turn = false
	state.players[1].hand = ["sv1-ener-3", "sv2-cand"]
	state.players[1].deck = ["sv2-39", "sv2-grex", "sv2-staryu", "sv2-starm"]
	state.players[1].prizes = ["sv2-keldeo", "sv2-tatsu"]
	state.players[1].discard = ["sv1-180"]
	return state


func _colorless_pre_knockout_state(
	hand_size: int,
	opponent_active_card_id: String,
	own_prize_count: int,
) -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.setup_stage = GameState.SETUP_COMPLETE
	state.setup_ready = [true, true]
	state.setup_actor_idx = -1
	state.turn_number = 7
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.public_deck_keys = ["colorless", "colorless"]
	state.set_type_matchups_enabled(false)
	state.players[0].active = PokemonState.new("svi-gree")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.energy_card_ids.assign(["svi-dtur"])
	state.players[0].bench[0] = PokemonState.new("svi-tand")
	state.players[0].bench[0].placed_this_turn = false
	state.players[0].hand = ["svi-maus"]
	while state.players[0].hand.size() < hand_size:
		state.players[0].hand.append("sv1-180")
	for _index in range(20):
		state.players[0].deck.append("svi-trea")
	state.players[0].prizes.clear()
	for _index in range(own_prize_count):
		state.players[0].prizes.append("svi-tand")
	state.players[1].active = PokemonState.new(opponent_active_card_id)
	state.players[1].active.placed_this_turn = false
	state.players[1].bench[0] = PokemonState.new("svi-aipo")
	state.players[1].bench[0].placed_this_turn = false
	for _index in range(20):
		state.players[1].deck.append("svi-trea")
	state.players[1].prizes.assign([
		"svi-tand", "svi-tand", "svi-tand", "svi-tand", "svi-tand", "svi-tand",
	])
	return state


func _colorless_reactive_self_loss_state() -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.setup_stage = GameState.SETUP_COMPLETE
	state.setup_ready = [true, true]
	state.setup_actor_idx = -1
	state.turn_number = 17
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.public_deck_keys = ["colorless", "colorless"]
	state.set_type_matchups_enabled(false)
	state.players[0].active = PokemonState.new("svi-stan")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.damage_counters = 10
	state.players[0].active.energy_card_ids.assign(["svi-jete"])
	state.players[0].bench[0] = PokemonState.new("svi-tand")
	state.players[0].bench[0].placed_this_turn = false
	state.players[0].hand = ["svi-maus"]
	state.players[0].deck = ["svi-trea", "svi-trea"]
	state.players[0].prizes = ["svi-tand", "svi-tand", "svi-tand"]
	state.players[1].active = PokemonState.new("svi-maus")
	state.players[1].active.placed_this_turn = false
	state.players[1].active.damage_counters = 21
	state.players[1].bench[0] = PokemonState.new("svi-maus")
	state.players[1].bench[0].placed_this_turn = false
	state.players[1].bench[1] = PokemonState.new("svi-tand")
	state.players[1].bench[1].placed_this_turn = false
	state.players[1].deck = ["svi-trea", "svi-trea"]
	state.players[1].prizes = ["svi-tand"]
	return state


func _lightning_self_damage_escape_state() -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.setup_stage = GameState.SETUP_COMPLETE
	state.setup_ready = [true, true]
	state.setup_actor_idx = -1
	state.turn_number = 9
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.public_deck_keys = ["lightning", "colorless"]
	state.set_type_matchups_enabled(false)
	state.players[0].active = PokemonState.new("svl-thun")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.damage_counters = 9
	state.players[0].active.energy_card_ids.assign([
		"sv1-ener-4", "sv1-ener-4", "sv1-ener-4",
	])
	state.players[0].bench[0] = PokemonState.new("svl-mare2")
	state.players[0].bench[0].placed_this_turn = false
	state.players[0].deck = ["svl-trks", "svl-trks"]
	state.players[0].prizes.assign([
		"svl-mare2", "svl-mare2", "svl-mare2",
	])
	state.players[1].active = PokemonState.new("svi-ente")
	state.players[1].active.placed_this_turn = false
	state.players[1].bench[0] = PokemonState.new("svi-tand")
	state.players[1].bench[0].placed_this_turn = false
	state.players[1].deck = ["svi-trea", "svi-trea"]
	state.players[1].prizes = ["svi-tand"]
	return state


func _lightning_ranked_backup_state(own_prize_count: int) -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.setup_stage = GameState.SETUP_COMPLETE
	state.setup_ready = [true, true]
	state.setup_actor_idx = -1
	state.turn_number = 5
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.public_deck_keys = ["lightning", "water"]
	state.set_type_matchups_enabled(false)
	state.players[0].active = PokemonState.new("svl-zera")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.energy_card_ids.assign([
		"sv1-ener-4", "sv1-ener-4",
	])
	state.players[0].hand.assign(["svl-pikaex", "svl-mare2"])
	state.players[0].deck.assign(["sv1-ener-4", "sv1-ener-4"])
	state.players[0].prizes.clear()
	for _index in range(own_prize_count):
		state.players[0].prizes.append("sv1-ener-4")
	state.players[1].active = PokemonState.new("sv2-delib")
	state.players[1].active.placed_this_turn = false
	state.players[1].bench[0] = PokemonState.new("sv2-staryu")
	state.players[1].bench[0].placed_this_turn = false
	state.players[1].deck.assign(["sv1-ener-3", "sv1-ener-3"])
	state.players[1].prizes.assign([
		"sv1-ener-3", "sv1-ener-3", "sv1-ener-3",
		"sv1-ener-3", "sv1-ener-3", "sv1-ener-3",
	])
	return state


func _fire_lone_active_draw_state(catalog: CardCatalog) -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.setup_stage = GameState.SETUP_COMPLETE
	state.setup_ready = [true, true]
	state.setup_actor_idx = -1
	state.turn_number = 3
	state.first_player_idx = 0
	state.active_player_idx = 0
	state.public_deck_keys = ["fire", "fire"]
	state.set_type_matchups_enabled(false)
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.damage_counters = 3
	state.players[0].active.energy_card_ids.assign(["sv1-ener-2"])
	state.players[0].hand.assign([
		"sv1-189", "sv1-180", "sv1-152", "sv3-134", "sv2-catch", "sv1-ener-2",
	])
	state.players[1].active = PokemonState.new("svi-chim")
	state.players[1].active.placed_this_turn = false
	state.players[1].active.energy_card_ids.assign(["sv1-ener-2"])
	state.players[1].hand.assign(["sv1-180"])
	_fill_hidden_zones_from_release_deck(state, 0, "fire", catalog)
	_fill_hidden_zones_from_release_deck(state, 1, "fire", catalog)
	return state


func _fill_hidden_zones_from_release_deck(
	state: GameState,
	player_idx: int,
	deck_key: String,
	catalog: CardCatalog,
) -> void:
	var player := state.players[player_idx]
	var remaining: Array[String] = catalog.expand_deck(deck_key)
	var visible: Array[String] = []
	visible.append_array(player.hand)
	visible.append_array(player.discard)
	if player.active != null:
		visible.append(player.active.card_id)
		visible.append_array(player.active.evolution_stack_ids)
		visible.append_array(player.active.energy_card_ids)
		if not player.active.attached_tool_id.is_empty():
			visible.append(player.active.attached_tool_id)
	for bench_pokemon in player.bench:
		if bench_pokemon == null:
			continue
		visible.append(bench_pokemon.card_id)
		visible.append_array(bench_pokemon.evolution_stack_ids)
		visible.append_array(bench_pokemon.energy_card_ids)
		if not bench_pokemon.attached_tool_id.is_empty():
			visible.append(bench_pokemon.attached_tool_id)
	for card_id in visible:
		var index := remaining.find(card_id)
		if index >= 0:
			remaining.remove_at(index)
	player.prizes.assign(remaining.slice(0, mini(6, remaining.size())))
	player.deck.assign(remaining.slice(player.prizes.size()))


func _is_supplied_legal_action(
	selected: GameAction,
	legal: Array[GameAction],
) -> bool:
	if selected == null:
		return false
	for candidate in legal:
		if candidate == selected or _intent_signature(candidate) == _intent_signature(selected):
			return true
	return false


func _intent_signature(action: GameAction) -> String:
	if action == null:
		return ""
	return str(TraditionalTurnPlanner.action_intent(action).get("signature", ""))


func _all_values_equal(values: Array, expected: String) -> bool:
	for value in values:
		if str(value) != expected:
			return false
	return true


func _contains_hidden_marker(value: Variant) -> bool:
	if value is Dictionary:
		for nested in Dictionary(value).values():
			if _contains_hidden_marker(nested):
				return true
	elif value is Array:
		for nested in Array(value):
			if _contains_hidden_marker(nested):
				return true
	elif value is String:
		return str(value) in [
			AIInformationSet.HIDDEN_CARD,
			AIInformationSet.HIDDEN_PRIZE,
			"__hidden_card__",
			"__hidden_prize__",
		]
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
