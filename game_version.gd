@tool
## Provides configuration and version management for the game
## Handles Steam app/depot IDs and demo mode switching
class_name GameVersion

# Settings constants
const APP_NAME_SETTING_PATH = "application/config/name"
const VERSION_SETTING_PATH = "application/config/version"
const SETTINGS_PREFIX = "application/steamroller/"
const DEMO_MODE_SETTING = SETTINGS_PREFIX + "demo_mode"
const FULL_APP_ID_SETTING = SETTINGS_PREFIX + "full_app_id"
const FULL_DEPOT_ID_SETTING = SETTINGS_PREFIX + "full_depot_id"
const DEMO_APP_ID_SETTING = SETTINGS_PREFIX + "demo_app_id" 
const DEMO_DEPOT_ID_SETTING = SETTINGS_PREFIX + "demo_depot_id"


## Returns a human-readable string containing the version number and demo or
## release status. Example strings: V_0.0.3.2.Dev.Demo, V_1.0.1.0.Final
static func get_version_string() -> String:
	var version = "v"
	version += get_version_number()
	if OS.has_feature("editor"):
		version += ".Dev"
	if is_demo_mode():
		version += ".Demo"
	return version


## Returns the name of the game from Project Settings.
static func get_application_name():
	return ProjectSettings.get_setting(APP_NAME_SETTING_PATH)


## Returns the version number string from Project Settings ("0.2.0.1" or similar).
static func get_version_number() -> String:
	return ProjectSettings.get_setting(VERSION_SETTING_PATH)


## Sets the version number string in Project Settings.
static func set_version_number(version: String):
	ProjectSettings.set_setting(VERSION_SETTING_PATH, version)


## Returns whether the game is currently in demo mode.
## This first checks for the existance of a "demo" or "full" flag,
## then checks Project Settings as a fallback.
##
## Practically, this means that the demo setting will take precidence in the editor,
## but the export flags will take over once the game is released.
static func is_demo_mode() -> bool:
	var is_demo = ProjectSettings.get_setting(DEMO_MODE_SETTING, false)
	if OS.has_feature("demo"):
		is_demo = true
	elif OS.has_feature("full"):
		is_demo = false
	return is_demo


## Changes the demo mode state and saves project settings.
## This only affects the demo mode flag in the editor. For release builds,
## the "demo" or "full" flags will override the demo setting.
## 
## Please note: setting this at runtime will have unexpected results - many game
## elements will only check the demo flag once when the game starts.
static func set_demo_mode(enabled: bool) -> void:
	ProjectSettings.set_setting(DEMO_MODE_SETTING, enabled)
	ProjectSettings.save()


## Gets the appropriate Steam App ID based on current demo mode
static func get_app_id() -> int:
	return ProjectSettings.get_setting(
		DEMO_APP_ID_SETTING if is_demo_mode() else FULL_APP_ID_SETTING, -1)


## Gets the appropriate Steam Depot ID based on current demo mode
static func get_depot_id() -> int:
	return ProjectSettings.get_setting(
		DEMO_DEPOT_ID_SETTING if is_demo_mode() else FULL_DEPOT_ID_SETTING, -1)


## Registers all required settings in Project Settings
## Called during plugin initialization
static func register_settings() -> void:
	# Demo mode toggle
	_add_setting(DEMO_MODE_SETTING, false, TYPE_BOOL, PROPERTY_HINT_NONE, "", 
		"Demo Mode", "Toggles between demo and full game mode for testing")
	
	# Steam App IDs
	_add_setting(FULL_APP_ID_SETTING, "", TYPE_INT, PROPERTY_HINT_NONE, "", 
		"Full Game App ID", "Steam App ID for the full version of the game")
	_add_setting(DEMO_APP_ID_SETTING, "", TYPE_INT, PROPERTY_HINT_NONE, "", 
		"Demo App ID", "Steam App ID for the demo version of the game")
	
	# Steam Depot IDs
	_add_setting(FULL_DEPOT_ID_SETTING, "", TYPE_INT, PROPERTY_HINT_NONE, "", 
		"Full Game Depot ID", "Steam Depot ID for the full version of the game")
	_add_setting(DEMO_DEPOT_ID_SETTING, "", TYPE_INT, PROPERTY_HINT_NONE, "", 
		"Demo Depot ID", "Steam Depot ID for the demo version of the game")
	
	# Save the settings
	ProjectSettings.save()


## Helper to add a single setting to the Project Settings with appropriate metadata
## Parameters:
## - name: Project setting key
## - default_value: Default value if not already set
## - type: Type of setting (TYPE_BOOL, TYPE_STRING, etc.)
## - hint: Property hint for editor display
## - hint_string: Additional hint information
## - custom_name: Display name in the editor
## - description: Optional tooltip description for the setting
static func _add_setting(name: String, default_value, type: int, hint: int = PROPERTY_HINT_NONE, 
			hint_string: String = "", custom_name: String = "", description: String = "") -> void:
	if !ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default_value)
		ProjectSettings.set_initial_value(name, default_value)
		
	# Set properties to make it show up in the project settings
	var info = {
		"name": name,
		"type": type,
		"hint": hint,
		"hint_string": hint_string
	}
	
	# Use a custom name if provided (for better organization in the UI)
	if custom_name != "":
		info["class_name"] = custom_name
	
	# Add description if provided
	if description != "":
		info["description"] = description
		
	ProjectSettings.add_property_info(info)
