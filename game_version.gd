@tool
class_name GameVersion
## Version and demo-mode state for the host project.
##
## Lightweight static helpers for Godot's `application/config/*` settings and
## SteamRoller-specific `application/steamroller/*` settings. Settings
## registration is called from the SteamRoller plugin on activation.

const SETTINGS_PREFIX := "application/steamroller/"
const DEMO_MODE_SETTING := SETTINGS_PREFIX + "demo_mode"
const FULL_APP_ID_SETTING := SETTINGS_PREFIX + "full_app_id"
const DEMO_APP_ID_SETTING := SETTINGS_PREFIX + "demo_app_id"
const FULL_DEPOT_ID_SETTING := SETTINGS_PREFIX + "full_depot_id"
const DEMO_DEPOT_ID_SETTING := SETTINGS_PREFIX + "demo_depot_id"
const CONFIG_PATH_SETTING := SETTINGS_PREFIX + "config_path"

const VERSION_SETTING := "application/config/version"
const APP_NAME_SETTING := "application/config/name"
const COMMIT_MESSAGE_SETTING := "application/config/commit_message"

const DEFAULT_CONFIG_PATH := "res://addons/steamroller/templates/default_config.tres"
const SPACEWAR_APP_ID := "480"


## Register all SteamRoller-managed project settings. Idempotent — safe to
## call from `plugin.gd::_enter_tree()` every editor load.
static func register_settings() -> void:
	_register_default(DEMO_MODE_SETTING, false, TYPE_BOOL)
	_register_default(FULL_APP_ID_SETTING, SPACEWAR_APP_ID, TYPE_STRING)
	_register_default(DEMO_APP_ID_SETTING, SPACEWAR_APP_ID, TYPE_STRING)
	_register_default(FULL_DEPOT_ID_SETTING, "", TYPE_STRING)
	_register_default(DEMO_DEPOT_ID_SETTING, "", TYPE_STRING)
	_register_default(CONFIG_PATH_SETTING, DEFAULT_CONFIG_PATH, TYPE_STRING,
		PROPERTY_HINT_FILE, "*.tres")
	# Commit message lives next to the version setting in Godot's own config
	# section so both survive editor restarts and so external tools can read
	# them from the same place.
	_register_default(COMMIT_MESSAGE_SETTING, "", TYPE_STRING)


# --- Accessors -------------------------------------------------------------

## Returns a human-readable version string with build-type suffixes appended.
## Examples: "v0.2.0.Dev", "v1.0.0.Demo", "v1.0.0.Web"
static func get_version_string() -> String:
	var version := "v" + get_version_number()
	if OS.has_feature("editor"):
		version += ".Dev"
	if is_demo_mode():
		version += ".Demo"
	if is_web_build():
		version += ".Web"
	return version


## Returns the raw version number string from Project Settings ("0.2.0.1" or similar).
static func get_version_number() -> String:
	return str(ProjectSettings.get_setting(VERSION_SETTING, ""))


## Sets the version number string in Project Settings.
static func set_version_number(version: String) -> void:
	ProjectSettings.set_setting(VERSION_SETTING, version)
	ProjectSettings.save()


## Returns the name of the game from Project Settings.
static func get_application_name() -> String:
	return str(ProjectSettings.get_setting(APP_NAME_SETTING, ""))


## Returns the current Godot engine version string.
static func get_engine_version_string() -> String:
	return Engine.get_version_info().string


## Returns the commit message stored in Project Settings for the current release.
static func get_commit_message() -> String:
	return str(ProjectSettings.get_setting(COMMIT_MESSAGE_SETTING, ""))


## Saves a commit message to Project Settings for use in release workflows.
static func set_commit_message(value: String) -> void:
	ProjectSettings.set_setting(COMMIT_MESSAGE_SETTING, value)
	ProjectSettings.save()


## Returns true if the game is currently in demo mode.
##
## Export feature flags take precedence over the Project Settings toggle: a
## build exported with the "demo" feature is always demo, and one exported
## with "full" is never demo, regardless of the editor setting.
static func is_demo_mode() -> bool:
	if OS.has_feature("demo"):
		return true
	if OS.has_feature("full"):
		return false
	return bool(ProjectSettings.get_setting(DEMO_MODE_SETTING, false))


## Returns true if the game is running as a web export.
static func is_web_build() -> bool:
	return OS.has_feature("web")


## Changes the demo mode flag in Project Settings.
##
## Only affects editor runs. Exported builds use "demo"/"full" feature flags
## which override this setting (see is_demo_mode). Setting this at runtime
## will not affect systems that already read the flag at startup.
static func set_demo_mode(value: bool) -> void:
	ProjectSettings.set_setting(DEMO_MODE_SETTING, value)
	ProjectSettings.save()


## Returns the active Steam App ID based on current demo mode.
static func get_active_app_id() -> String:
	var setting := DEMO_APP_ID_SETTING if is_demo_mode() else FULL_APP_ID_SETTING
	return str(ProjectSettings.get_setting(setting, ""))


## Returns the active Steam Depot ID based on current demo mode.
static func get_active_depot_id() -> String:
	var setting := DEMO_DEPOT_ID_SETTING if is_demo_mode() else FULL_DEPOT_ID_SETTING
	return str(ProjectSettings.get_setting(setting, ""))


## Adds a Project Settings entry with a default value and editor metadata.
## Skips overwriting an existing value; always updates the initial value and
## property info so the setting appears in the editor.
static func _register_default(setting: String, default_value: Variant, type: int,
		hint: int = PROPERTY_HINT_NONE, hint_string: String = "") -> void:
	if not ProjectSettings.has_setting(setting):
		ProjectSettings.set_setting(setting, default_value)
	ProjectSettings.set_initial_value(setting, default_value)
	ProjectSettings.add_property_info({
		"name": setting,
		"type": type,
		"hint": hint,
		"hint_string": hint_string,
	})
