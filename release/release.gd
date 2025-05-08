@tool
extends VBoxContainer

signal reset_build

@onready var build_desc: LineEdit = $BuildDesc
@onready var version: LineEdit = $Version

@onready var build_complete_check_box: CheckBox = $BuildCompleteCheckBox
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


func push_to_steam(app_id: String):
	print("Pushing app %s to Steam." % app_id)
	await get_tree().process_frame
	var output = []
	var result = OS.execute("cmd.exe", ["/c", 'C:/Users/Administrator/Desktop/SDG/Black_Hole_Fishing/steamworks_sdk/tools/ContentBuilder/builder/steamcmd.exe  +login Matt_SDG_Games +run_app_build "C:/Users/Administrator/Desktop/SDG/Black_Hole_Fishing/steamworks_sdk/tools/ContentBuilder/scripts/app_%s.vdf" +quit' % app_id], output)
	if result == 0:
		print("Success!")
	else:
		print(output)


func toggle_buttons_disabled():
	for button in push_buttons:
		button.disabled = !build_complete_check_box.button_pressed


func _on_push_demo_steam_pressed() -> void:
	push_to_steam("3690070")

func _on_push_game_steam_pressed() -> void:
	push_to_steam("3667390")


func _on_push_demo_itch_pressed() -> void:
	print("TODO: Push demo to Itch")


func _on_push_game_itch_pressed() -> void:
	print("TODO: Push game to Itch")


func _on_push_all_pressed() -> void:
	_on_push_demo_steam_pressed()
	_on_push_game_steam_pressed()
	_on_push_demo_itch_pressed()
	_on_push_game_itch_pressed()


func _on_reset_button_pressed() -> void:
	build_complete_check_box.button_pressed = false
	toggle_buttons_disabled()
	reset_build.emit()


func _on_check_box_pressed() -> void:
	toggle_buttons_disabled()


func _on_open_scripts_pressed() -> void:
	var path = SteamRoller.STEAMWORKS_SDK_PATH.path_join("tools/ContentBuilder/scripts")
	OS.shell_show_in_file_manager(ProjectSettings.globalize_path(path))
