@tool
extends VBoxContainer

signal to_release
signal description_modified(description: String)

@export var commit_file_name: String

@onready var version: LineEdit = $Version
@onready var message: LineEdit = $Message
@onready var build_info: RichTextLabel = $BuildInfo
@onready var commit_command: RichTextLabel = $CommitCommand

# Buttons to run the steps that can be automated.
@onready var test_button: Button = $TestButton
@onready var delete_build: Button = $DeleteBuild
@onready var movie_button: Button = $MovieButton
@onready var archive_button: Button = $HBoxContainer/ArchiveButton
@onready var copy_message: Button = $CopyMessage
@onready var reset_fields_button: Button = $ResetFields

# Settings toggles.
@onready var auto_increment_version: CheckButton = $AutoIncrementVersion
@onready var auto_reencode_video: CheckButton = $AutoReencodeVideo


# Check boxes for the checklist
@onready var message_check_box: CheckBox = $MessageCheckBox
@onready var test_check_box: CheckBox = $TestCheckBox
@onready var delete_check_box: CheckBox = $DeleteCheckBox
@onready var build_check_box: CheckBox = $BuildCheckBox
@onready var movie_check_box: CheckBox = $MovieCheckBox
@onready var archive_check_box: CheckBox = $ArchiveCheckBox
@onready var code_review_check_box: CheckBox = $CodeReviewCheckBox


## Run the unit tests in GdUnit4.
func run_tests() -> void:
	print("Running all GdUnit tests...")
	GdUnitCommandHandler.instance().cmd_run_overall(true)
	
	# Pause here until we are done.
	while EditorInterface.is_playing_scene():
		await get_tree().create_timer(0.5).timeout


## Enable movie maker mode, then record a gameplay sample to 
func record_gameplay() -> bool:
	# Set the movie maker file path
	var movie_path = SteamRoller.LATEST_BUILD_BASE_PATH + "/gameplay.avi"
	ProjectSettings.set_setting("editor/movie_writer/movie_file", movie_path)
	
	# Enable movie maker mode
	EditorInterface.movie_maker_enabled = true
	print("Movie maker enabled, recording to: " + movie_path)
	
	# Run the game scene
	var main_scene = ProjectSettings.get_setting("application/run/main_scene")
	if main_scene:
		EditorInterface.play_main_scene()
		print("Running main scene: " + main_scene)
	else:
		printerr("No main scene set in project settings")
		return false
	
	# Pause here until we are done.
	while EditorInterface.is_playing_scene():
		await get_tree().create_timer(0.5).timeout
	
	# Disable movie maker mode after processing
	EditorInterface.movie_maker_enabled = false
	print("Movie maker mode disabled")
	
	# Run ffmpeg to compress the video. Mark task complete if it succeeds.
	if auto_reencode_video.button_pressed:
		movie_button.text = "Re-encoding video"
		if await reencode_gameplay_video(movie_path):
			return true
	else:
		return true
	return false


## Use an external FFMPEG call to re-encode the .avi video as a much smaller .mp4
func reencode_gameplay_video(movie_path: String) -> bool:
	var output = []
	var compressed_path = movie_path.get_basename() + "_sample.mp4"
	
	print("Processing video with ffmpeg...")
	await get_tree().process_frame
	var exit_code = OS.execute("ffmpeg", [
		"-i", ProjectSettings.globalize_path(movie_path),
		"-vf", "scale=-1:1080",
		"-c:v", "libx264",
		"-crf", "23",
		"-preset", "medium",
		"-c:a", "aac",
		"-b:a", "128k",
		"-y",
		ProjectSettings.globalize_path(compressed_path)
	], output, true)
	
	if exit_code == 0:
		print("Video compression complete: " + compressed_path)
		await get_tree().process_frame
		
		# Delete the original AVI file to save space
		var avi_file = movie_path.get_file()
		var avi_dir = movie_path.get_base_dir()

		print("Attempting to delete: " + avi_file + " from directory: " + avi_dir)

		# Use absolute paths to avoid issues
		var absolute_path = ProjectSettings.globalize_path(movie_path)
		print("Absolute path: " + absolute_path)

		# Try direct OS command to delete the file
		var delete_args = []
		if OS.get_name() == "Windows":
			delete_args = ["cmd", "/c", "del", "/f", absolute_path.replace("/", "\\")]
		else:
			delete_args = ["-c", "rm -f \"" + absolute_path + "\""]

		var delete_output = []
		var delete_exit_code = OS.execute("cmd" if OS.get_name() == "Windows" else "bash", delete_args, delete_output, true)

		if delete_exit_code == 0:
			print("Original AVI file deleted successfully using OS command")
		else:
			printerr("Failed to delete using OS command: " + str(delete_exit_code))
			printerr("Command output: " + str(delete_output))
			return false
	else:
		printerr("FFMPEG failed with exit code: " + str(exit_code))
		printerr("Output: " + str(output))
		return false
	return true


## Delete the contents of "latest", and reset the folder structure.
func delete_previous_build() -> void:
	print("Deleting previous build and restoring folder structure...")
	delete_build.text = "Deleting..."
	delete_build.disabled = true
	
	# Convert res:// paths to absolute paths
	var latest_dir = ProjectSettings.globalize_path(SteamRoller.LATEST_BUILD_BASE_PATH)
	var game_dir = ProjectSettings.globalize_path(SteamRoller.GAME_DEPOT_PATH)
	var demo_dir = ProjectSettings.globalize_path(SteamRoller.DEMO_DEPOT_PATH)
	var web_dir = ProjectSettings.globalize_path(SteamRoller.WEB_BUILD_PATH)
	
	var output = []
	var exit_code = 0
	
	# Windows commands
	# First remove the directory if it exists
	OS.execute("cmd", ["/c", 
		"if exist \"" + latest_dir.replace("/", "\\") + "\" rmdir /s /q \"" + latest_dir.replace("/", "\\") + "\""
	], output, true)
	
	# Then create the directories
	exit_code = OS.execute("cmd", ["/c", 
		"mkdir \"" + latest_dir.replace("/", "\\") + "\" && " +
		"mkdir \"" + game_dir.replace("/", "\\") + "\" && " +
		"mkdir \"" + demo_dir.replace("/", "\\") + "\" && " +
		"mkdir \"" + web_dir.replace("/", "\\") + "\""
	], output, true)
	
	if exit_code == 0:
		print("Build deleted and folder structure restored")
		delete_check_box.button_pressed = true
		delete_build.text = "Build Deleted"
		delete_build.disabled = true
	else:
		printerr("Failed to delete/restore build directories: " + str(output))
		delete_build.text = "Error Deleting Previous Build"
		delete_build.disabled = false


## Copies the contents of "latest" to the appropriate archive destination.
func archive_build() -> bool:
	print("Archiving current build...")
	# Convert res:// paths to absolute paths
	var latest_dir = ProjectSettings.globalize_path(SteamRoller.LATEST_BUILD_BASE_PATH)
	var builds_dir = ProjectSettings.globalize_path(SteamRoller.BUILD_FOLDER_PATH)
	var archive_dir = builds_dir.path_join(commit_file_name)
	
	var output = []
	var exit_code = 0
	
	print("Copying from: " + latest_dir + " to: " + archive_dir)
	await get_tree().process_frame
	
	# Windows commands
	# Create directory and xcopy with /E to copy directories and subdirectories, including empty ones
	# /I to assume the destination is a directory if copying more than one file
	# /H to copy hidden and system files
	# /Y to suppress confirmation prompt
	exit_code = OS.execute("cmd", ["/c", 
		"mkdir \"" + archive_dir.replace("/", "\\") + "\" && " +
		"xcopy \"" + latest_dir.replace("/", "\\") + "\" \"" + archive_dir.replace("/", "\\") + "\" /E /I /H /Y"
	], output, true)
	
	if exit_code == 0:
		print("Build archived successfully to: " + archive_dir)
		return true
	else:
		printerr("Failed to archive build: " + str(output))
		return false


## Reset all of the buttons in the checklist.
func reset_buttons():
	# De-select all checkboxes, resetting the list.
	message_check_box.button_pressed = false
	test_check_box.button_pressed = false
	build_check_box.button_pressed = false
	movie_check_box.button_pressed = false
	archive_check_box.button_pressed = false
	code_review_check_box.button_pressed = false
	
	# Reset button text, and disable options with dependencies.
	test_button.text = "Run all unit tests"
	movie_button.text = "Record gameplay sample"
	delete_build.text = "Delete previous build"
	toggle_button_disabled()


## Disables and enables build steps based on previously completed steps.
func toggle_button_disabled() -> void:
	delete_build.disabled = delete_check_box.button_pressed
	movie_button.disabled = movie_check_box.button_pressed and delete_check_box.button_pressed
	test_button.disabled = !message_check_box.button_pressed or test_check_box.button_pressed
	archive_button.disabled = (!(build_check_box.button_pressed and movie_check_box.button_pressed) or archive_check_box.button_pressed)
	copy_message.disabled = !(build_check_box.button_pressed and movie_check_box.button_pressed and code_review_check_box.button_pressed)


## Clears the commit message, resets all button states,
## and increments the version number (if option is checked).
func reset():
	message.clear()
	reset_buttons()
	delete_check_box.button_pressed = false
	
	if auto_increment_version.button_pressed:
		# Find the position of the last dot
		var last_dot_pos = version.text.rfind(".")
		# Get everything before the last dot (including the dot)
		var prefix = version.text.substr(0, last_dot_pos + 1)
		# Get the last digit as a string
		var last_digit = version.text.substr(last_dot_pos + 1)
		# Convert to int, increment, and convert back to string
		var incremented = str(int(last_digit) + 1)
		# Combine and return the new version
		version.text = prefix + incremented
		# We don't actually call this on change? Make it explicit.
		version._on_text_changed(version.text)


func _on_message_text_changed(new_text: String) -> void:
	# Make sure that we don't include spaces on accident.
	description_modified.emit(new_text)
	commit_file_name = version.text + "_" + new_text.replace(" ", "_").to_lower()
	reset_buttons()
	message_check_box.button_pressed = true
	toggle_button_disabled()
	commit_command.text = '[center]git commit -m [color=cyan]"%s"[/color][/center]' % new_text
	build_info.text = "The game has been exported to [color=CYAN]res://../builds/latest/[/color].\n" + \
			"Press [i]Archive[/i] to copy it to [color=CYAN]%s/[/color]" % commit_file_name
	var version_id = ProjectSettings.get_setting(SteamRoller.VERSION_SETTING_PATH)


func _on_delete_build_pressed() -> void:
	delete_previous_build()


func _on_test_button_pressed() -> void:
	test_button.disabled = true
	test_button.text = "Unit tests running..."
	await run_tests()
	test_check_box.button_pressed = true
	test_button.text = "Unit testing complete"
	toggle_button_disabled()


func _on_movie_button_pressed() -> void:
	movie_button.text = "Recording Gameplay..."
	movie_check_box.button_pressed = await record_gameplay()
	movie_button.text = "Recording Complete"
	toggle_button_disabled()


func _on_archive_button_pressed() -> void:
	archive_button.text = "Archiving..."
	archive_button.disabled = true
	archive_check_box.button_pressed = await archive_build()
	archive_button.text = "Archive Complete"
	archive_button.disabled = true
	toggle_button_disabled()


func _on_copy_message_pressed() -> void:
	DisplayServer.clipboard_set('git commit -m "%s"' % message.text)
	delete_check_box.button_pressed = false


func _on_check_box_pressed() -> void:
	toggle_button_disabled()


func _on_release_button_pressed() -> void:
	to_release.emit()


func _on_reset_fields_pressed() -> void:
	reset()


func _on_open_build_button_pressed() -> void:
	OS.shell_show_in_file_manager(ProjectSettings.globalize_path(SteamRoller.LATEST_BUILD_BASE_PATH))
