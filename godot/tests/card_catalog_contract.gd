extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	_run_contract()
	if failures.is_empty():
		print("CARD_CATALOG_CONTRACT_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_contract() -> void:
	var load_count_before := CardCatalog.shared_load_count()
	var repository := CardCatalog.shared()
	var same_repository := CardCatalog.shared()
	_check(repository == same_repository, "shared() must preserve repository identity")
	var database_script: Script = load("res://autoload/card_database.gd")
	var database: Node = database_script.new()
	_check(
		repository == database.catalog,
		"CardDatabase must publish the canonical catalog repository",
	)
	_check(repository.is_read_only_repository(), "runtime repository must be marked read-only")
	_check(repository.cards.is_read_only(), "runtime cards dictionary must be read-only")
	_check(repository.decks.is_read_only(), "runtime decks dictionary must be read-only")

	var sample_card := repository.get_card("svi-chim")
	var sample_attacks: Array = sample_card.get("attacks", [])
	_check(sample_card.is_read_only(), "nested card dictionaries must be read-only")
	_check(sample_attacks.is_read_only(), "nested card arrays must be read-only")
	_check(
		repository._expanded_deck_cache.size() == repository.decks.size(),
		"all release decks must be expanded before sharing the repository",
	)
	for cache in [
		repository._expanded_deck_cache,
		repository._card_supertype_cache,
		repository._card_subtypes_cache,
		repository._provides_energy_cache,
		repository._prize_value_cache,
	]:
		_check(cache.is_read_only(), "derived runtime caches must be read-only")
	var first_deck_key := str(repository.decks.keys()[0])
	var first_card_id := str(repository.cards.keys()[0])
	var cached_deck: Array = repository._expanded_deck_cache[first_deck_key]
	var cached_subtypes: Array = repository._card_subtypes_cache[first_card_id]
	var cached_energy: Array = repository._provides_energy_cache[first_card_id]
	_check(cached_deck.is_read_only(), "cached expanded decks must be read-only")
	_check(cached_subtypes.is_read_only(), "cached subtype arrays must be read-only")
	_check(cached_energy.is_read_only(), "cached energy arrays must be read-only")
	var cache_sizes_before := _cache_sizes(repository)
	var first_expansion := repository.expand_deck(first_deck_key)
	first_expansion.append("__local_copy_only")
	_check(
		not "__local_copy_only" in repository.expand_deck(first_deck_key),
		"expanded deck callers must receive independent copies",
	)
	repository.is_pokemon(first_card_id)
	repository.is_basic_pokemon(first_card_id)
	repository.provides_energy(first_card_id)
	repository.prize_value(first_card_id)
	repository.expand_deck("__unknown_deck")
	repository.is_pokemon("__unknown_card")
	repository.is_basic_pokemon("__unknown_card")
	repository.provides_energy("__unknown_card")
	repository.prize_value("__unknown_card")
	var reader_threads: Array[Thread] = []
	for _index in range(6):
		var reader := Thread.new()
		var start_error := reader.start(
			_read_catalog_repeatedly.bind(repository, first_deck_key, first_card_id),
		)
		_check(start_error == OK, "catalog read worker failed to start")
		if start_error == OK:
			reader_threads.append(reader)
	for reader in reader_threads:
		_check(bool(reader.wait_to_finish()), "concurrent catalog reads changed results")
	_check(
		_cache_sizes(repository) == cache_sizes_before,
		"known, repeated, unknown, and concurrent reads must not mutate runtime caches",
	)

	var zones: Array[ZoneView] = []
	for _index in range(12):
		var zone := ZoneView.new()
		zones.append(zone)
		_check(zone.catalog == repository, "ZoneView must reuse the canonical catalog")
	_check(
		CardCatalog.shared_load_count() == load_count_before,
		"creating ZoneView controls must not reload catalog JSON",
	)

	var isolated := CardCatalog.new(true)
	var synthetic_id := "__catalog_contract_synthetic"
	isolated.cards[synthetic_id] = {"name": "Synthetic"}
	_check(not isolated.cards.is_read_only(), "isolated test catalogs must remain mutable")
	_check(not repository.cards.has(synthetic_id), "isolated mutations must not leak into runtime data")
	zones[0].set_catalog(isolated)
	_check(zones[0].catalog == isolated, "ZoneView must accept explicit catalog injection")
	zones[0].set_catalog(null)
	_check(zones[0].catalog == repository, "null injection must restore the runtime repository")

	var default_engine := GameEngine.new()
	var injected_engine := GameEngine.new(isolated)
	_check(default_engine.catalog == repository, "GameEngine default must reuse runtime repository")
	_check(injected_engine.catalog == isolated, "GameEngine must preserve explicit injection")
	var controller := NetworkMatchController.new(repository)
	var session := AuthoritativeSession.new("catalog-contract", repository)
	_check(controller.catalog == repository, "network controller must preserve catalog injection")
	_check(session.catalog == repository, "authoritative session must preserve catalog injection")
	_check(
		session.native_rules.catalog == repository,
		"authoritative native session must share the injected catalog",
	)
	for zone in zones:
		zone.free()
	database.free()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _cache_sizes(catalog: CardCatalog) -> Array[int]:
	return [
		catalog._expanded_deck_cache.size(),
		catalog._card_supertype_cache.size(),
		catalog._card_subtypes_cache.size(),
		catalog._provides_energy_cache.size(),
		catalog._prize_value_cache.size(),
	]


func _read_catalog_repeatedly(
	catalog: CardCatalog,
	deck_key: String,
	card_id: String,
) -> bool:
	for _index in range(200):
		if catalog.expand_deck(deck_key).size() != 60:
			return false
		catalog.is_pokemon(card_id)
		catalog.is_basic_pokemon(card_id)
		catalog.provides_energy(card_id)
		catalog.prize_value(card_id)
		catalog.expand_deck("__unknown_deck")
		catalog.is_pokemon("__unknown_card")
	return true
