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
## While a button's step runs, that button reads Stop. Pressing another button
## meanwhile queues its step (SteamRollerStepRunner.submit): the button shows a
## yellow hourglass until its turn, and pressing it again takes it back out. A
## ticked step's buttons carry a check icon, whether it ran or was ticked by
## hand. A step that asks a question first (SteamRollerStep.confirmation) asks
## it when pressed, and runs or queues only on OK.

const ConsoleScene := preload("res://addons/steamroller/ui/console_output.tscn")
## Every icon colour of a Button, all tinted while it is queued. Locked to
## Button's theme items.
const ICON_COLORS: Array[StringName] = [&"icon_normal_color", &"icon_pressed_color",
	&"icon_hover_color", &"icon_hover_pressed_color", &"icon_focus_color", &"icon_disabled_color"]

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
var _asking: ButtonEntry = null
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
	runner.queue_changed.connect(_refresh)
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
	if runner.queue_position(e) > 0:
		runner.unqueue(e)
		return
	var question := runner.vars.resolve(e.step.confirmation())
	if question.is_empty():
		_press(e)
		return
	if _confirm == null:
		_confirm = ConfirmationDialog.new()
		_confirm.title = "SteamRoller"
		_confirm.confirmed.connect(_on_confirmed)
		_confirm.canceled.connect(func() -> void: _asking = null)
		add_child(_confirm)
	_asking = e
	_confirm.dialog_text = question
	_confirm.popup_centered()


func _on_confirmed() -> void:
	var e := _asking
	_asking = null
	if e != null:
		_press(e)


## An instant step runs at once; any other goes through the runner's queue,
## which runs it at once when nothing is running. The params are taken now, so
## a queued render keeps the inputs that were selected when it was pressed.
func _press(e: ButtonEntry) -> void:
	var overrides := e.overrides.duplicate()
	overrides.merge(_overrides_for(e), true)
	if e.step.is_instant():
		_run(e, overrides)
	else:
		runner.submit(e.step, e, _run.bind(e, overrides), e.label, _console_key(e))


## Run a press now and return whether it succeeded (false when the dock was
## rebuilt while it ran).
func _run(e: ButtonEntry, overrides: Dictionary) -> bool:
	# An instant step runs beside whatever is running: it neither clears the
	# console nor turns its button into Stop.
	if not e.step.is_instant():
		if _console:
			_console.clear_log()
		_running = e
	var ok: bool = await runner.execute_step(e.step, overrides, _console_key(e))
	if not is_instance_valid(e.button) or not is_inside_tree():
		return false   # the dock was rebuilt while the step ran
	if _running == e:
		_running = null
	if e.step.marks_completion():
		runner.set_completed(e.step.id, ok)
	_refresh()
	return ok


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
	# What the running and queued presses tick: a step behind one of them can
	# queue, and an export already on its way locks its other button.
	var pending := runner.pending_ticks()
	for e in _buttons:
		if not is_instance_valid(e.button):
			continue
		var place := runner.queue_position(e)
		_tint_icon(e.button, place > 0)
		if e == _running:
			var stopping := runner.stop_requested()
			e.button.text = "Stopping…" if stopping else "Stop"
			e.button.icon = null
			e.button.disabled = stopping
			e.button.tooltip_text = "" if stopping else "Stop this step, and whatever it started"
			continue
		if place > 0:
			e.button.text = e.label
			e.button.icon = _queued_icon()
			e.button.disabled = false
			e.button.tooltip_text = "Queued (#%d): runs when the steps ahead of it finish. " % place \
				+ "Press to take it out of the queue."
			continue
		var s := e.step
		var why := runner.blocked_reason(s, true)
		var done_once := runner.is_completed(s.id) or pending.has(s.id)
		var locked := s.locks_when_completed() and done_once
		e.button.text = e.label
		e.button.disabled = not why.is_empty() or locked or not _can_run(e)
		if not why.is_empty():
			e.button.tooltip_text = why
		elif locked and runner.is_completed(s.id):
			e.button.tooltip_text = "Done for this version: Reset unlocks it."
		elif locked:
			e.button.tooltip_text = "Already running or queued: it runs once per version."
		elif busy and not s.is_instant():
			e.button.tooltip_text = "Queue it: it runs when the steps ahead of it finish."
		else:
			e.button.tooltip_text = ""
		# A ticked step shows its tick on its buttons, the row's own step as well as
		# attached ones. The row's checkbox is the same tick, set by hand to skip a step.
		var done := s.marks_completion() and runner.is_completed(s.id)
		e.button.icon = get_theme_icon("StatusSuccess", "EditorIcons") if done else null
	_refresh_description()


## The icon a queued button carries: the editor's Timer icon (an hourglass),
## tinted by _tint_icon().
func _queued_icon() -> Texture2D:
	if has_theme_icon("Timer", "EditorIcons"):
		return get_theme_icon("Timer", "EditorIcons")
	return get_theme_icon("StatusWarning", "EditorIcons")


## Tint a button's icon the config's queued_icon_color while it is queued, and
## clear the tint otherwise (the check icon keeps its own green).
func _tint_icon(button: Button, on: bool) -> void:
	if on and runner.config == null:
		return
	for item in ICON_COLORS:
		if on:
			button.add_theme_color_override(item, runner.config.queued_icon_color)
		elif button.has_theme_color_override(item):
			button.remove_theme_color_override(item)


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
