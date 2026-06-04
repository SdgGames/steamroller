@tool
extends EditorPlugin
## SteamRoller plugin entry point.

const PANEL_SCENE := "res://addons/steamroller/steamroller_panel.tscn"

var dock: Control = null


func _enter_tree() -> void:
	GameVersion.register_settings()

	var scene: PackedScene = load(PANEL_SCENE)
	if scene == null:
		push_error("[SteamRoller] Could not load panel scene at %s" % PANEL_SCENE)
		return
	dock = scene.instantiate()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BR, dock)


func _exit_tree() -> void:
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()
		dock = null
