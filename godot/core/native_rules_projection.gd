class_name NativeRulesProjection
extends RefCounted

## Read-only DTO projections backed by ptcg_core.  These helpers never own or
## mutate match state; they prevent presentation and AI code from reimplementing
## derived rule values such as modified HP.

static var _catalog_sessions: Dictionary = {}


static func pokemon_current_hp(
	pokemon: PokemonState,
	catalog: CardCatalog,
) -> int:
	if pokemon == null or catalog == null:
		return 0
	var session: Variant = _session_for(catalog)
	if session == null:
		return 0
	return int(session.pokemon_current_hp(pokemon.to_dict()))


static func pokemon_max_hp(
	pokemon: PokemonState,
	catalog: CardCatalog,
) -> int:
	if pokemon == null or catalog == null:
		return 0
	var session: Variant = _session_for(catalog)
	if session == null:
		return 0
	return int(session.pokemon_max_hp(pokemon.to_dict()))


static func _session_for(catalog: CardCatalog) -> Variant:
	if not ClassDB.class_exists("NativeRulesSession"):
		return null
	var key := catalog.get_instance_id()
	if _catalog_sessions.has(key):
		return _catalog_sessions[key]
	var session: Variant = ClassDB.instantiate("NativeRulesSession")
	if session == null or not session.set_catalog(catalog.native_rules_catalog()):
		return null
	_catalog_sessions[key] = session
	return session
