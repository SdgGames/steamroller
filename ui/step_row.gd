@tool
class_name SteamRollerStepRow extends VBoxContainer
## One row of the checklist:
##
##   [x] Display name           a checkbox (INPUT: a label and a text field;
##                              a step with no display name has no header)
##   description                BBCode, variables resolved
##        [ Button ] [ ... ]    the step's own buttons, then those of the
##                              steps attached to it (attach())
##   console                    hidden until a line arrives
##
## While a button's step runs, that button reads Stop. A step that asks a
## question first (SteamRollerStep.confirmation) runs only on OK.

const ConsoleScene := preload("res://addons/steamroller/ui/console_output.tscn")

## One button and the step it runs.
class ButtonEntry:
	var button: Button
	var step: SteamRollerStep
	## Merged over the step's params when pressed (Debug vs Release).
	var overrides: Dictionary
	var label: String

var step: SteamRollerStep
var runner: SteamRollerStepRunner

var _checkbox: CheckBox = null
var _input: LineEdit = null
var _description: RichTextLabel = null
var _flow: HFlowContainer = null
var _console: SteamRollerConsoleOutput = null
var _buttons: Array[ButtonEntry] = []
## The button whose step is running: it reads Stop.
var _running: ButtonEntry = null
## The button waiting on the confirmation dialog.
var _pending: ButtonEntry = null
var _confirm: ConfirmationDialog = null
## Console ids whose lines this row's console shows: its steps' ids, and its own
## key for steps with none.
var _hosted: PackedStringArray = []
## Step ids whose ticks change what this row shows.
var _watched: Dictionary[String, bool] = {}
var _row_key := ""


func setup(p_step: SteamRollerStep, p_runner: SteamRollerStepRunner) -> void:
	step = p_step
	runner = p_runner
	_row_key = "row_%d" % get_instance_id()
	_hosted.append(_row_key)
	if step.action == SteamRollerStep.Action.INPUT:
		_build_input()
	elif not step.display_name.is_empty():
		_build_checkbox()
	if runner.missing_requirements.has(step.id):
		var missing := Label.new()
		missing.text = "Missing: " + runner.missing_requirements[step.id]
		missing.add_theme_color_override("font_color", get_theme_color("warning_color", "Editor"))
		missing.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		add_child(missing)
	if not step.description.is_empty():
		_description = RichTextLabel.new()
		_description.bbcode_enabled = true
		_description.fit_content = true
		_description.scroll_active = false
		_description.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_apply_mono_font(_description)
		add_child(_description)
	_build_body()
	if step.has_action_button():
		_add_buttons(step)
	_take(step)
	runner.step_state_changed.connect(_on_state_changed)
	runner.log_line_emitted.connect(_on_log_line)
	runner.busy_changed.connect(func(_busy: bool) -> void: _refresh())
	runner.variables_changed.connect(_refresh_description)
	runner.reset_requested.connect(_on_reset)
	_refresh()


## Show `extra`'s buttons in this row: its attach_to names this row's step. It
## keeps its own id, completion, gating and console output (shown here).
func attach(extra: SteamRollerStep) -> void:
	if extra.new_button_row:
		_flow = null
	if extra.has_action_button():
		_add_buttons(extra)
	_take(extra)
	_refresh()


# --- Overridden by row types with more to show (SteamRollerRenderPanel) ---------

## Add controls between the description and the buttons.
func _build_body() -> void:
	pass


## More params for a button's step when it is pressed.
func _overrides_for(_e: ButtonEntry) -> Dictionary:
	return {}


## Whether a button may run now, beyond its step's gates.
func _can_run(_e: ButtonEntry) -> bool:
	return true


# --- Building ----------------------------------------------------------------------

func _build_checkbox() -> void:
	_checkbox = CheckBox.new()
	_checkbox.text = step.display_name
	_checkbox.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_checkbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_checkbox.toggled.connect(func(on: bool) -> void: runner.set_completed(step.id, on))
	add_child(_checkbox)


func _build_input() -> void:
	var row := HBoxContainer.new()
	add_child(row)
	var label := Label.new()
	label.text = step.display_name
	row.add_child(label)
	_input = LineEdit.new()
	_input.placeholder_text = step.placeholder
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text = runner.input_value(step)
	row.add_child(_input)
	# Each keystroke updates the setting in memory (descriptions follow at once);
	# project.godot is written when the field is left, on Enter, or before a step runs.
	_input.text_changed.connect(func(text: String) -> void: runner.set_input(step, text))
	_input.text_submitted.connect(func(_text: String) -> void: runner.save_settings())
	_input.focus_exited.connect(runner.save_settings)
	runner.set_completed(step.id, step.input_complete(_input.text))


func _add_buttons(target: SteamRollerStep) -> void:
	if _flow == null:
		_flow = HFlowContainer.new()
		_flow.alignment = FlowContainer.ALIGNMENT_CENTER
		_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		add_child(_flow)
		if _console:
			move_child(_console, -1)
	var width := runner.config.button_min_width if runner.config else 160
	for spec in target.get_button_specs():
		var e := ButtonEntry.new()
		e.step = target
		e.label = str(spec.get("label", ""))
		e.overrides = spec.get("overrides", {})
		e.button = Button.new()
		e.button.text = e.label
		e.button.custom_minimum_size = Vector2(width, 0)
		e.button.pressed.connect(_on_pressed.bind(e))
		_flow.add_child(e.button)
		_buttons.append(e)


## Take `s` into the row: watch its gates, show its output.
func _take(s: SteamRollerStep) -> void:
	_watched[s.id] = true
	for dep in s.depends_on:
		_watched[dep] = true
	for dep in s.depends_on_any:
		_watched[dep] = true
	if not s.id.is_empty() and not _hosted.has(s.id):
		_hosted.append(s.id)
	if _console == null and s.produces_output():
		_console = ConsoleScene.instantiate()
		add_child(_console)
	if _console:
		move_child(_console, -1)


# --- Running -----------------------------------------------------------------------

func _on_pressed(e: ButtonEntry) -> void:
	if e == _running:
		runner.stop()
		_refresh()
		return
	var question := runner.vars.resolve(e.step.confirmation())
	if question.is_empty():
		_run(e)
		return
	if _confirm == null:
		_confirm = ConfirmationDialog.new()
		_confirm.title = "SteamRoller"
		_confirm.confirmed.connect(_on_confirmed)
		_confirm.canceled.connect(func() -> void: _pending = null)
		add_child(_confirm)
	_pending = e
	_confirm.dialog_text = question
	_confirm.popup_centered()


func _on_confirmed() -> void:
	var e := _pending
	_pending = null
	if e != null:
		_run(e)


func _run(e: ButtonEntry) -> void:
	# An instant step runs beside whatever is running: it neither clears the
	# console nor turns its button into Stop.
	if not e.step.is_instant():
		if _console:
			_console.clear_log()
		_running = e
	var overrides := e.overrides.duplicate()
	overrides.merge(_overrides_for(e), true)
	var ok: bool = await runner.execute_step(e.step, overrides, _console_key(e))
	if not is_instance_valid(e.button) or not is_inside_tree():
		return   # the dock was rebuilt while the step ran
	if _running == e:
		_running = null
	if e.step.marks_completion():
		runner.set_completed(e.step.id, ok)
	_refresh()


## The console a button's output goes to: the row's step, else the button's.
func _console_key(e: ButtonEntry) -> String:
	if not step.id.is_empty():
		return step.id
	if not e.step.id.is_empty():
		return e.step.id
	return _row_key


# --- Refresh -------------------------------------------------------------------------

func _refresh() -> void:
	if _checkbox and _checkbox.button_pressed != runner.is_completed(step.id):
		_checkbox.set_pressed_no_signal(runner.is_completed(step.id))
	var busy := runner.is_busy()
	for e in _buttons:
		if not is_instance_valid(e.button):
			continue
		if e == _running:
			var stopping := runner.stop_requested()
			e.button.text = "Stopping…" if stopping else "Stop"
			e.button.icon = null
			e.button.disabled = stopping
			e.button.tooltip_text = "" if stopping else "Stop this step, and whatever it started"
			continue
		var s := e.step
		var why := runner.blocked_reason(s)
		var locked := s.locks_when_completed() and runner.is_completed(s.id)
		e.button.text = e.label
		e.button.disabled = (busy and not s.is_instant()) or not why.is_empty() or locked \
			or not _can_run(e)
		if not why.is_empty():
			e.button.tooltip_text = why
		elif locked:
			e.button.tooltip_text = "Done for this version: Reset unlocks it."
		else:
			e.button.tooltip_text = ""
		# An attached step's tick shows on its button (the row's checkbox is the
		# row's own step).
		var done := s != step and s.marks_completion() and runner.is_completed(s.id)
		e.button.icon = get_theme_icon("StatusSuccess", "EditorIcons") if done else null
	_refresh_description()


func _refresh_description() -> void:
	if _description:
		_description.text = runner.vars.resolve_display(step.description)


func _on_state_changed(step_id: String) -> void:
	if _watched.has(step_id):
		_refresh()


func _on_log_line(console_id: String, line: String) -> void:
	if _console and _hosted.has(console_id):
		_console.append(line)


func _on_reset() -> void:
	if _console:
		_console.clear_log()
	if _input:
		_input.text = runner.input_value(step)
		runner.set_completed(step.id, step.input_complete(_input.text))


static func _apply_mono_font(label: RichTextLabel) -> void:
	if not Engine.is_editor_hint():
		return
	var base := EditorInterface.get_base_control()
	if base == null:
		return
	var mono := base.get_theme_font("output_source_mono", "EditorFonts")
	if mono:
		label.add_theme_font_override("mono_font", mono)
	var settings := EditorInterface.get_editor_settings()
	if settings:
		var font_size: int = settings.get_setting("interface/editor/main_font_size")
		label.add_theme_font_size_override("mono_font_size", font_size)
