@tool
class_name SteamRollerConsole extends RichTextLabel
## Per-step console log.
##
## Hidden when empty. Once a line is appended, it becomes visible with a
## fixed height that fits ~3 lines, scrolling internally if more arrive.

const VISIBLE_LINES := 3


func _ready() -> void:
	bbcode_enabled = true
	scroll_following = true
	selection_enabled = true
	# Compute height for ~3 lines from the current default font.
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var line_height: int = 18
	if font:
		line_height = int(font.get_height(font_size))
	# Add a couple pixels of vertical padding so descenders aren't clipped.
	custom_minimum_size = Vector2(0, line_height * VISIBLE_LINES + 4)
	visible = false


func append(line: String) -> void:
	if not visible:
		visible = true
	append_text(line + "\n")


func clear_log() -> void:
	clear()
	visible = false