@tool
class_name SteamRoller extends Control

const VERSION_SETTING_PATH = "application/config/version"
const APP_NAME_SETTING_PATH = "application/config/name"

# File paths - these are constants because external tools rely on them.
const BUILD_FOLDER_PATH = "res://../builds"
const LATEST_BUILD_BASE_PATH = "res://../builds/latest"
const GAME_DEPOT_PATH = "res://../builds/latest/game_depot"
const DEMO_DEPOT_PATH = "res://../builds/latest/demo_depot"
const WEB_BUILD_PATH = "res://../builds/latest/web"
# Constants for SDK paths
const STEAMWORKS_SDK_PATH = "res://../steamworks_sdk"
const STEAM_CMD_PATH = "/tools/ContentBuilder/builder/steamcmd.exe"

## A reference to the build tab. I should go through the automated build process for each commit.
@onready var build_tab: ScrollContainer = $TabContainer/Build
@onready var build: VBoxContainer = $"TabContainer/Build/Build"
## A reference to the release tab. I should run this before merging a branch to to Main in git.
@onready var release_tab: ScrollContainer = $TabContainer/Release
@onready var release: VBoxContainer = $TabContainer/Release/Release


func _on_build_to_release() -> void:
	release_tab.visible = true
	release_tab.scroll_vertical = 0


func _on_release_reset_build() -> void:
	build.reset()
	build_tab.visible = true
	build_tab.scroll_vertical = 0


func _on_build_description_modified(description: String) -> void:
	release.update_build_description(description)
