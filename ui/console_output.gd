@tool
class_name SteamRollerConsole extends RichTextLabel
## Per-step console log.
##
## Hidden when empty. Once a line is appended it becomes visible and grows with
## its content, from `min_lines` high up to `max_visible_lines`; past that it
## keeps its height and scrolls internally as more arrive. External processes
## stream their output here live while they run.

## Height, in text lines, of a console with (almost) nothing in it.
@export_range(1, 20) var min_lines: int = 1
## Tallest the console grows before it scrolls instead.
@export_range(1, 40) var max_visible_lines: int = 4

## Upper bound on retained lines. A chatty tool can emit thousands; the full
## text is always in the log file the runner names in the Output panel.
const MAX_LINES := 800

## Vertical padding so descenders on the last line are not clipped.
const PAD_PX := 4

## Narrower than this and the label has not been laid out by its container
## yet (a hidden control keeps a token width), so its wrapped height is noise.
const MIN_LAYOUT_WIDTH := 50.0

var _line_count: int = 0


func _ready() -> void:
	bbcode_enabled = true
	scroll_following = true
	selection_enabled = true
	custom_minimum_size = Vector2(0, _line_height() * min_lines + PAD_PX)
	visible = false
	# Wrapped height depends on width: refit when the dock is resized, and when
	# the container first lays the console out after it becomes visible.
	resized.connect(_fit_height)


## Append one line of process output. Uses add_text(), NOT append_text():
## the latter parses BBCode, which would swallow or mangle any "[" in the
## output of tools like butler and steamcmd.
func append(line: String) -> void:
	if not visible:
		visible = true
	if _line_count >= MAX_LINES:
		clear()
		_line_count = 0
		add_text("… earlier output trimmed (see the log file) …")
		newline()
	# Lines are separated, not terminated, so there is no empty last paragraph
	# adding a phantom line to the content height.
	if _line_count > 0:
		newline()
	if line.begins_with("[err]"):
		push_color(Color(1.0, 0.45, 0.45))
		add_text(line)
		pop()
	else:
		add_text(line)
	_line_count += 1
	# The laid-out height is only known once the text has been shaped.
	_fit_height.call_deferred()


func clear_log() -> void:
	clear()
	_line_count = 0
	custom_minimum_size.y = _line_height() * min_lines + PAD_PX
	visible = false


func _line_height() -> float:
	var font := get_theme_default_font()
	if font == null:
		return 18.0
	return font.get_height(get_theme_default_font_size())


## Grow to fit the content (wrapped lines included), between min_lines and
## max_visible_lines high. A no-op until the console has a real width.
func _fit_height() -> void:
	if not is_inside_tree() or not visible or size.x < MIN_LAYOUT_WIDTH:
		return
	var content := float(get_content_height())
	# The label's real line pitch (measured: 16 px where the font reports 21),
	# so the cap is max_visible_lines of what is actually drawn. get_line_count()
	# counts wrapped lines, which is what we want here.
	var lh := _line_height()
	if content > 0.0:
		lh = content / maxi(get_line_count(), 1)
	var fitted := clampf(content + PAD_PX, lh * min_lines + PAD_PX, lh * max_visible_lines + PAD_PX)
	if not is_equal_approx(custom_minimum_size.y, fitted):
		custom_minimum_size.y = fitted
