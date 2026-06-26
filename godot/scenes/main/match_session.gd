class_name MatchSession
extends Node

var catalog := CardCatalog.new()
var engine := GameEngine.new(catalog)
var state: GameState
var rng := PortableRandomSource.new(1)


func configure(
	p_catalog: CardCatalog,
	p_engine: GameEngine,
	p_state: GameState,
	p_rng: PortableRandomSource,
) -> void:
	catalog = p_catalog
	engine = p_engine
	state = p_state
	rng = p_rng


func legal_actions(actor: int, include_setup: bool = true) -> Array[GameAction]:
	if state == null:
		return []
	return engine.legal_actions(state, actor, include_setup)
