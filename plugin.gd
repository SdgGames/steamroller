@tool
extends EditorPlugin

var dock = null
var scene_file = "res://addons/steamroller/steamroller_panel.tscn"

# Settings constants
const SETTINGS_PREFIX = "application/steamroller/"
const DEMO_MODE_SETTING = SETTINGS_PREFIX + "demo_mode"
const FULL_APP_ID_SETTING = SETTINGS_PREFIX + "full_app_id"
const DEMO_APP_ID_SETTING = SETTINGS_PREFIX + "demo_app_id"
const FULL_DEPOT_ID_SETTING = SETTINGS_PREFIX + "full_depot_id"
const DEMO_DEPOT_ID_SETTING = SETTINGS_PREFIX + "demo_depot_id"


func _enter_tree():
	# Register the settings
	GameVersion.register_settings()
	
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
