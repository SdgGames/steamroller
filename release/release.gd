@tool
extends VBoxContainer

signal reset_build

@onready var build_desc: LineEdit = $BuildDesc
@onready var version: LineEdit = $Version

@onready var build_complete_check_box: CheckBox = $BuildCompleteCheckBox
@onready var console_output: RichTextLabel = $ConsoleOutput
@onready var push_buttons = [
		$GridContainer/PushDemoSteam,
		$GridContainer/PushGameSteam,
		$GridContainer/PushDemoItch,
		$GridContainer/PushGameItch,
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
	var steam_cmd_path = 'C:/Users/Administrator/Desktop/SDG/Black_Hole_Fishing/steamworks_sdk/tools/ContentBuilder/builder/steamcmd.exe'
	var script_path = 'C:/Users/Administrator/Desktop/SDG/Black_Hole_Fishing/steamworks_sdk/tools/ContentBuilder/scripts/app_%s.vdf' % app_id
	var args = [
		"/c", 
		'"%s" +login Matt_SDG_Games +run_app_build "%s" +quit' % [steam_cmd_path, script_path]
	]
	
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
	await push_to_steam("3690070")

func _on_push_game_steam_pressed() -> void:
	await push_to_steam("3667390")


func _on_push_demo_itch_pressed() -> void:
	await get_tree().process_frame
	print("TODO: Push demo to Itch")


func _on_push_game_itch_pressed() -> void:
	await get_tree().process_frame
	print("TODO: Push game to Itch")


func _on_push_all_pressed() -> void:
	await _on_push_demo_steam_pressed()
	await _on_push_game_steam_pressed()
	await _on_push_demo_itch_pressed()
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
