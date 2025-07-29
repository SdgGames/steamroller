@tool
extends VBoxContainer

signal reset_build

# TODO: Move these to project settings and set them up in the Start Guide.
const BUTLER_PATH = "res://addons/steamroller/butler-windows-amd64/butler.exe"
# TODO: Generalize (maybe make relative to res:// ?)
const STEAM_CMD_PATH = "C:/Users/Administrator/Desktop/SDG/Black_Hole_Fishing/steamworks_sdk/tools/ContentBuilder/builder/steamcmd.exe"
const STEAM_USER = "Matt_SDG_Games"
const DEPOT_ID_DEMO = "3690070"
const DEPOT_ID_FULL = "3667390"
const VDF_FILE = "C:/Users/Administrator/Desktop/SDG/Black_Hole_Fishing/steamworks_sdk/tools/ContentBuilder/scripts/app_%s.vdf"

const ITCH_USER = "sdggames"
const ITCH_PROJECT = "black-hole-fishing"


@onready var build_desc: LineEdit = $BuildDesc
@onready var version: LineEdit = $Version

@onready var build_complete_check_box: CheckBox = $BuildCompleteCheckBox
@onready var console_output: RichTextLabel = $ConsoleOutput
@onready var push_buttons = [
		$Push/PushDemoSteam,
		$Push/PushGameSteam,
		$Itch/PushDemoItch,
		$Itch/PushWebItch,
		$Itch/PushGameItch,
		$PushAll,
	]


func _ready() -> void:
	# Set the initial state.
	toggle_buttons_disabled()


func update_build_description(base_message: String):
	build_desc.text = "(%s) %s" % [version.text, base_message]


func build_complete():
	build_complete_check_box.button_pressed = true
	toggle_buttons_disabled()


func push_to_steam(app_id: String) -> void:
	print("Pushing app %s to Steam." % app_id)
	
	# Prepare the command arguments
	var args = [
		"/c", 
		'"%s" +login %s +run_app_build "%s" +quit' % [STEAM_CMD_PATH, STEAM_USER, VDF_FILE % app_id]
	]
	
	print("Running command: %s %s" % ["cmd.exe", " ".join(args)])

	# Start the process non-blocking
	var pid = OS.create_process("cmd.exe", args, true)
	
	if pid <= 0:
		printerr("Failed to start Steam upload process for app %s" % app_id)
		return
	
	print("Steam upload process started with PID: " + str(pid) + " for app " + app_id)
	
	# Wait while the process is running
	while OS.is_process_running(pid):
		await get_tree().process_frame
	
	# Check exit code after process finished
	var exit_code = OS.get_process_exit_code(pid)
	
	if exit_code == OK:
		print("Successfully pushed app %s to Steam" % app_id)
	else:
		print("Failed to push app %s to Steam. Exit code: %s" % [app_id, error_string(exit_code)])


func toggle_buttons_disabled():
	for button in push_buttons:
		button.disabled = !build_complete_check_box.button_pressed


func _on_push_demo_steam_pressed() -> void:
	await push_to_steam(DEPOT_ID_DEMO)

func _on_push_game_steam_pressed() -> void:
	await push_to_steam(DEPOT_ID_FULL)


func _on_push_demo_itch_pressed() -> void:
	print("Pushing demo to Itch...")
	
	# Push demo depot (Windows + Linux) to demo channel
	var success = await push_to_itch(SteamRoller.DEMO_DEPOT_PATH, "demo")
	
	if success:
		print("Demo successfully pushed to Itch")
	else:
		print("Failed to push demo to Itch")


func _on_push_web_itch_pressed() -> void:
	print("Pushing web build to Itch...")
	
	# Push web build to web channel
	var success = await push_to_itch(SteamRoller.WEB_BUILD_PATH, "web")
	
	if success:
		print("Web build successfully pushed to Itch")
	else:
		print("Failed to push Web build to Itch")


func _on_push_game_itch_pressed() -> void:
	print("Pushing full game to Itch...")
	
	# Push game depot (Windows + Linux) to main channel
	var success = await push_to_itch(SteamRoller.GAME_DEPOT_PATH, "full")
	
	if success:
		print("Full game successfully pushed to Itch")
	else:
		print("Failed to push full game to Itch")


func push_to_itch(build_path: String, channel: String) -> bool:
	print("Pushing %s to Itch channel: %s" % [build_path, channel])
	
	# Convert res:// path to absolute path
	var absolute_build_path = ProjectSettings.globalize_path(build_path)
	var butler_exe_path = ProjectSettings.globalize_path(BUTLER_PATH)
	
	# Get version for the upload
	var version = GameVersion.get_version_number()
	
	# Prepare Butler arguments
	var target = "%s/%s:%s" % [ITCH_USER, ITCH_PROJECT, channel]
	var args = [
		"push",
		absolute_build_path,
		target,
		"--userversion", version
	]
	
	print("Running Butler command: %s %s" % [butler_exe_path, " ".join(args)])
	
	# Start the Butler process non-blocking
	var pid = OS.create_process(butler_exe_path, args, true)
	
	if pid <= 0:
		printerr("Failed to start Butler process for channel: " + channel)
		return false
	
	print("Butler process started with PID: " + str(pid) + " for channel: " + channel)
	
	# Wait while the process is running
	while OS.is_process_running(pid):
		await get_tree().process_frame
	
	# Check exit code after process finished
	var exit_code = OS.get_process_exit_code(pid)
	
	if exit_code == OK:
		print("Successfully pushed to Itch channel: " + channel)
		return true
	else:
		print("Failed to push to Itch channel: %s. Exit code: %s" % [channel, str(exit_code)])
		return false


func _on_push_all_pressed() -> void:
	await _on_push_demo_steam_pressed()
	await _on_push_game_steam_pressed()
	await _on_push_demo_itch_pressed()
	await _on_push_web_itch_pressed()
	await _on_push_game_itch_pressed()


func _on_reset_button_pressed() -> void:
	build_complete_check_box.button_pressed = false
	$ReleaseList2.button_pressed = false
	$ReleaseList3.button_pressed = false
	$ReleaseList4.button_pressed = false
	$ReleaseList5.button_pressed = false
	$ReleaseList6.button_pressed = false
	toggle_buttons_disabled()
	reset_build.emit()


func _on_check_box_pressed() -> void:
	toggle_buttons_disabled()


func _on_open_scripts_pressed() -> void:
	var path = SteamRoller.STEAMWORKS_SDK_PATH.path_join("tools/ContentBuilder/scripts")
	OS.shell_show_in_file_manager(ProjectSettings.globalize_path(path))
