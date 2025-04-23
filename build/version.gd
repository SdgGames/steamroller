@tool
extends LineEdit

# The project setting path where you want to store the version
const VERSION_SETTING_PATH = "application/config/version"

# Prevents the cursor from jumping around.
var skip_update := false


func _ready():
	# Connect to the text_changed signal
	text_changed.connect(_on_text_changed)
	add_to_group("settings_sync")
	
	update_settings()


## Called after ProjectSettings changes - we should check that we are up-to-date.
func update_settings():
	if !skip_update:
		text = ProjectSettings.get_setting(VERSION_SETTING_PATH)


# Called when the text in the LineEdit changes
func _on_text_changed(new_text):
	# Update the project setting with the new version
	ProjectSettings.set_setting(VERSION_SETTING_PATH, new_text)
	# Save the project settings to disk
	ProjectSettings.save()
	skip_update = true
	get_tree().call_group("settings_sync", "update_settings")
	skip_update = false
