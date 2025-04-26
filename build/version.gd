@tool
extends LineEdit

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
		text = GameVersion.get_version_number()


# Called when the text in the LineEdit changes
func _on_text_changed(new_text):
	# Update the project setting with the new version
	GameVersion.set_version_number(new_text)
	# Save the project settings to disk
	ProjectSettings.save()
	skip_update = true
	get_tree().call_group("settings_sync", "update_settings")
	skip_update = false
