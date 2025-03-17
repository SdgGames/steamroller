@tool
extends EditorPlugin

var dock = null
var scene_file = "res://addons/steamroller/steamroller_panel.tscn"


func _enter_tree():
	# Instance the scene
	var scene = load(scene_file)
	if scene:
		dock = scene.instantiate()
	
	# Add the scene as a dock
	if dock:
		add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BR, dock)
	else:
		push_error("Failed to instance SteamRoller dock scene")

func _exit_tree():
	# Clean-up of the plugin goes here
	if dock:
		remove_control_from_docks(dock)
		dock.free()
