@tool
class_name SteamRollerConsoleOutput extends RichTextLabel
## A row's console: the output of the steps the row runs.
##
## Hidden while empty. It grows with its content from min_lines up to
## max_visible_lines high, then scrolls. Lines starting "[err]" are coloured.

## Height in lines of a console with (almost) nothing in it.
@export_range(1, 20) var min_lines: int = 1
## Tallest the console grows before it scrolls.
@export_range(1, 40) var max_visible_lines: int = 4
## Lines kept before the console starts over (the log file has every line).
@export_range(50, 10000) var max_lines: int = 800
## Padding under the last line (px), so descenders are not clipped.
@export_range(0, 16) var pad_px: int = 4
## Narrower than this (px) the console has not been laid out yet, and its
## wrapped height means nothing.
@export_range(0.0, 400.0) var min_layout_width: float = 50.0
## Colour of lines that start "[err]".
@export var error_color: Color = Color(1.0, 0.45, 0.45)

## The lines shown, kept to redraw the console when a heartbeat replaces the last one.
var _lines := PackedStringArray()
var _last_was_heartbeat := false


func _ready() -> void:
	bbcode_enabled = true
	scroll_following = true
	selection_enabled = true
	custom_minimum_size = Vector2(0, _line_height() * min_lines + pad_px)
	visible = false
	# Wrapped height depends on width: refit when the dock is resized, and when
	# the container first lays the console out after it becomes visible.
	resized.connect(_fit_height)


## Append one line. A heartbeat right after a heartbeat replaces it, so a long
## run shows one line that ticks.
func append(line: String) -> void:
	visible = true
	var heartbeat := line.begins_with(SteamRollerShell.HEARTBEAT_PREFIX)
	if heartbeat and _last_was_heartbeat and not _lines.is_empty():
		_lines[_lines.size() - 1] = line
		_redraw()
		return
	_last_was_heartbeat = heartbeat
	if _lines.size() >= max_lines:
		_lines = PackedStringArray(["… earlier output trimmed (the log file has it all) …"])
		_redraw()
	_lines.append(line)
	_add(line, _lines.size() > 1)
	# The height is only known once the text has been shaped.
	_fit_height.call_deferred()


func clear_log() -> void:
	clear()
	_lines.clear()
	_last_was_heartbeat = false
	custom_minimum_size.y = _line_height() * min_lines + pad_px
	visible = false


func _redraw() -> void:
	clear()
	for i in _lines.size():
		_add(_lines[i], i > 0)
	_fit_height.call_deferred()


## add_text(), not append_text(): tool output is full of "[" that BBCode parsing
## would swallow. Lines are separated, not terminated: no empty last line adding
## height.
func _add(line: String, separate: bool) -> void:
	if separate:
		newline()
	if line.begins_with("[err]"):
		push_color(error_color)
		add_text(line)
		pop()
	else:
		add_text(line)


func _line_height() -> float:
	var font := get_theme_default_font()
	if font == null:
		return 18.0
	return font.get_height(get_theme_default_font_size())


## Fit the content (wrapped lines included), between min_lines and
## max_visible_lines high. Waits until the console has a real width.
func _fit_height() -> void:
	if not is_inside_tree() or not visible or size.x < min_layout_width:
		return
	var content := float(get_content_height())
	# The real line pitch (16 px where the font reports 21, measured), so the
	# cap is max_visible_lines of what is actually drawn.
	var lh := _line_height()
	if content > 0.0:
		lh = content / maxi(get_line_count(), 1)
	var fitted := clampf(content + pad_px, lh * min_lines + pad_px, lh * max_visible_lines + pad_px)
	if not is_equal_approx(custom_minimum_size.y, fitted):
		custom_minimum_size.y = fitted
