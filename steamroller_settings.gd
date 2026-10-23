@tool
class_name SteamRollerSettings
## Every project setting SteamRoller reads or writes, in one place.
##
## The plugin registers its own `application/steamroller/*` settings on load
## (register()), so they show in Project Settings with defaults. The version
## and the commit message sit beside Godot's own `application/config/*` keys,
## so the game and outside tools (bench.sh, CI) read them from the same file.
##
## Games may read two of these at runtime: the app ids (to talk to Steam), and
## `demo_mode` in editor runs only, to preview their demo when the dock's Demo
## toggle is on (exports carry a `demo` or `full` feature tag instead).

# Setting keys. Constants because they are names, not tunables: every project
# that carries the plugin stores its values under exactly these keys.
const PREFIX := "application/steamroller/"
## The SteamRollerConfig resource the dock renders.
const CONFIG_PATH := PREFIX + "config_path"
## The dock's Demo toggle.
const DEMO_MODE := PREFIX + "demo_mode"
## The Steam branch a push goes live on (the VDF `setlive` field).
const STEAM_BRANCH := PREFIX + "steam_branch"
const FULL_APP_ID := PREFIX + "full_app_id"
const DEMO_APP_ID := PREFIX + "demo_app_id"
const FULL_DEPOT_ID := PREFIX + "full_depot_id"
const DEMO_DEPOT_ID := PREFIX + "demo_depot_id"

const VERSION := "application/config/version"
const APP_NAME := "application/config/name"
const COMMIT_MESSAGE := "application/config/commit_message"
const USE_CUSTOM_USER_DIR := "application/config/use_custom_user_dir"
const CUSTOM_USER_DIR_NAME := "application/config/custom_user_dir_name"
## The demo export's own user folder: a feature override of the key above.
const CUSTOM_USER_DIR_NAME_DEMO := CUSTOM_USER_DIR_NAME + ".demo"
const MAIN_SCENE := "application/run/main_scene"
const MOVIE_FILE := "editor/movie_writer/movie_file"

const DEFAULT_CONFIG_PATH := "res://addons/steamroller/templates/default_config.tres"
## Valve's public test app, so a fresh config can dry-run a push.
const SPACEWAR_APP_ID := "480"


## Register the plugin's settings. Idempotent: called on every editor load.
static func register() -> void:
	_register(DEMO_MODE, false, TYPE_BOOL)
	_register(STEAM_BRANCH, "", TYPE_STRING)
	_register(FULL_APP_ID, SPACEWAR_APP_ID, TYPE_STRING)
	_register(DEMO_APP_ID, SPACEWAR_APP_ID, TYPE_STRING)
	_register(FULL_DEPOT_ID, "", TYPE_STRING)
	_register(DEMO_DEPOT_ID, "", TYPE_STRING)
	_register(CONFIG_PATH, DEFAULT_CONFIG_PATH, TYPE_STRING, PROPERTY_HINT_FILE, "*.tres")
	_register(COMMIT_MESSAGE, "", TYPE_STRING)


## A setting as text ("" when it is not set).
static func text(key: String) -> String:
	return str(ProjectSettings.get_setting(key, ""))


## A setting as a bool (false when it is not set).
static func flag(key: String) -> bool:
	return ProjectSettings.get_setting(key, false) == true


## Set a setting in memory. save() writes project.godot.
static func put(key: String, value: Variant) -> void:
	ProjectSettings.set_setting(key, value)


## Write every in-memory setting to project.godot.
static func save() -> bool:
	var err := ProjectSettings.save()
	if err != OK:
		push_error("[SteamRoller] Could not save project settings (error %d)." % err)
	return err == OK


static func config_path() -> String:
	return text(CONFIG_PATH)


static func demo_mode() -> bool:
	return flag(DEMO_MODE)


static func set_demo_mode(on: bool) -> void:
	put(DEMO_MODE, on)
	save()


## The demo export's user folder on this machine, or "" when the project gives
## the demo no folder of its own (custom_user_dir_name.demo).
static func demo_user_dir() -> String:
	if not flag(USE_CUSTOM_USER_DIR):
		return ""
	var dir_name := text(CUSTOM_USER_DIR_NAME_DEMO)
	if dir_name.is_empty():
		return ""
	return OS.get_data_dir().path_join(dir_name)


## Add a setting with a default and editor metadata, keeping any stored value.
static func _register(key: String, default_value: Variant, type: int,
		hint: int = PROPERTY_HINT_NONE, hint_string: String = "") -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default_value)
	ProjectSettings.set_initial_value(key, default_value)
	ProjectSettings.add_property_info({
		"name": key,
		"type": type,
		"hint": hint,
		"hint_string": hint_string,
	})
