class_name ChoicePanel
extends VBoxContainer

@onready var metadata_label: Label = %MetadataLabel
@onready var empty_label: Label = %EmptyLabel
@onready var card_grid: GridContainer = %CardGrid
@onready var option_list: VBoxContainer = %OptionList


func configure(metadata_text: String, has_options: bool) -> void:
	_resolve_nodes()
	metadata_label.text = metadata_text
	metadata_label.visible = not metadata_text.is_empty()
	empty_label.visible = not has_options


func _resolve_nodes() -> void:
	metadata_label = get_node("MetadataLabel") as Label
	empty_label = get_node("EmptyLabel") as Label
	card_grid = get_node("CardGrid") as GridContainer
	option_list = get_node("OptionList") as VBoxContainer
