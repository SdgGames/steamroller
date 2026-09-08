@tool
class_name SteamRollerConsole extends RichTextLabel
## Per-step console log.
##
## Hidden when empty. Once a line is appended, it becomes visible with a fixed
## height, scrolling internally as more arrive. External processes stream their
## output here live while they run.

const VISIBLE_LINES := 6

## Upper bound on retained lines. A chatty tool can emit thousands; the full
## text is always in the log file the runner names in the Output panel.
const MAX_LINES := 800

var _line_count: int = 0


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


## Append one line of process output. Uses add_text(), NOT append_text():
## the latter parses BBCode, which would swallow or mangle any "[" in the
## output of tools like butler and steamcmd.
func append(line: String) -> void:
	if not visible:
		visible = true
	if _line_count >= MAX_LINES:
		clear()
		_line_count = 0
		add_text("… earlier output trimmed (see the log file) …\n")
	if line.begins_with("[err]"):
		push_color(Color(1.0, 0.45, 0.45))
		add_text(line + "\n")
		pop()
	else:
		add_text(line + "\n")
	_line_count += 1


func clear_log() -> void:
	clear()
	_line_count = 0
	visible = false