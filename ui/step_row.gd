@tool
class_name SteamRollerStepRow extends VBoxContainer
## One row in the SteamRoller checklist.
##
## Standard layout (composed based on step.action):
##   [Checkbox] [Step name]            (INPUT replaces this with [Label] [LineEdit])
##   <description RichTextLabel>        (only if description is non-empty)
##         [ Action button ]            (centered, in an HFlowContainer)
##   <per-step console output>          (only if action produces output)
##
## When `step.is_optional` is true, the row is NOT created standalone — the
## panel calls `attach_optional_to(...)` on the *previous* row to inject this
## step's button into the previous row's button flow container.

const ConsoleScene := preload("res://addons/steamroller/ui/console_output.tscn")

var step: SteamRollerStep
var runner: SteamRollerRunner

var _checkbox: CheckBox = null
var _input: LineEdit = null
## One entry per button this row hosts:
##   button           : Button
##   step             : SteamRollerStep - the step the button runs
##   overrides        : Dictionary      - merged over that step's params
##   marks_completion : bool            - whether pressing it ticks this row
##   label            : String          - restored after "Running..."
var _buttons: Array[Dictionary] = []
var _button_flow: HFlowContainer = null
var _console: SteamRollerConsole = null
## Ids of every step whose buttons this row hosts - its own plus any attached
## optional steps - so their streamed output is accepted by _on_log_line.
var _hosted_ids: PackedStringArray = []
var _description_label: RichTextLabel = null
var _status_label: Label = null

## True if this row has a button flow container that can host additional
## optional buttons. Panels query this before attaching an optional step.
func has_button_flow() -> bool:
	return _button_flow != null


## Append a button for an optional step into this row's flow container.
## Caller must have verified has_button_flow() == true.
func attach_optional_button(optional_step: SteamRollerStep) -> void:
	if _button_flow == null:
		push_warning("[SteamRoller] attach_optional_button called on row with no button flow.")
		return
	_add_buttons_for(optional_step, _button_flow)
	_ensure_console(optional_step)


## Start a new button line inside this row (no separator in the parent list).
## Creates a second HFlowContainer and re-points _button_flow to it so that
## subsequent attach_optional_button calls land on the new line.
func attach_new_button_line(optional_step: SteamRollerStep) -> void:
	var flow := HFlowContainer.new()
	flow.alignment = HFlowContainer.ALIGNMENT_CENTER
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(flow)
	_button_flow = flow
	_add_buttons_for(optional_step, flow)
	_ensure_console(optional_step)
	if _console:
		move_child(_console, -1)  # the console stays at the bottom of the row


# --- Setup -----------------------------------------------------------------

func setup(p_step: SteamRollerStep, p_runner: SteamRollerRunner) -> void:
	step = p_step
	runner = p_runner

	# Header — depends on action type. Optional orphan steps skip the
	# checkbox entirely; they're button-only.
	if step.is_optional:
		pass  # button-only row, see below
	elif step.action == SteamRollerStep.Action.INPUT:
		_build_input_header()
	else:
		_build_checkbox_header()

	# Status (for missing requirements). Only show on non-optional steps.
	if not step.is_optional and runner.missing_requirements.has(step.id):
		_status_label = Label.new()
		_status_label.text = "Missing: " + str(runner.missing_requirements[step.id])
		_status_label.modulate = Color(1, 0.7, 0.3)
		_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		add_child(_status_label)

	# Description (only if non-empty and not optional).
	if not step.is_optional and not step.description.is_empty():
		_description_label = RichTextLabel.new()
		_description_label.bbcode_enabled = true
		_description_label.fit_content = true
		_description_label.scroll_active = false
		_apply_editor_mono_font(_description_label)
		_description_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		add_child(_description_label)
		_refresh_description()

	# Button row (only for actions with a button). Always created as an
	# HFlowContainer so optional buttons can be appended later.
	if step.has_action_button():
		_button_flow = HFlowContainer.new()
		_button_flow.alignment = HFlowContainer.ALIGNMENT_CENTER
		_button_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		add_child(_button_flow)
		_add_buttons_for(step, _button_flow)

	# Console (only for non-optional actions that produce output).
	if not step.is_optional:
		if not step.id.is_empty() and not _hosted_ids.has(step.id):
			_hosted_ids.append(step.id)
		_ensure_console(step)

	# Subscribe to runner state changes after everything is built.
	runner.step_state_changed.connect(_on_state_changed)
	runner.log_line_emitted.connect(_on_log_line)
	# Nothing is clickable while any step runs, now that steps no longer block.
	runner.busy_changed.connect(_on_busy_changed)
	if step.action == SteamRollerStep.Action.INPUT:
		runner.step_input_set.connect(_on_step_input_set)
	if not step.description.is_empty():
		runner.variables_changed.connect(_on_variables_changed)

	_refresh()


# --- Header builders -------------------------------------------------------

func _build_checkbox_header() -> void:
	_checkbox = CheckBox.new()
	_checkbox.text = step.display_name
	_checkbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_checkbox.toggled.connect(_on_checkbox_toggled)
	add_child(_checkbox)


func _build_input_header() -> void:
	var hbox := HBoxContainer.new()
	add_child(hbox)
	var label := Label.new()
	label.text = step.display_name
	hbox.add_child(label)
	_input = LineEdit.new()
	_input.placeholder_text = step.placeholder
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var initial := step.default_value
	if not step.project_setting_path.is_empty() \
			and ProjectSettings.has_setting(step.project_setting_path):
		var stored := str(ProjectSettings.get_setting(step.project_setting_path))
		if not stored.is_empty():
			initial = stored
	_input.text = initial
	hbox.add_child(_input)

	if not step.target_variable.is_empty():
		runner.set_variable(step.target_variable, initial)
	_input.text_changed.connect(_on_input_text_changed)

	var initially_complete := (not step.require_non_empty) or (not initial.is_empty())
	runner.set_completed(step.id, initially_complete)


# --- Button factory --------------------------------------------------------

## Build every button `target_step` declares and add them to `flow`. A step
## normally declares one; EXPORT_PROJECT declares Debug and Release. Each
## button captures its own step and param overrides, so one row can host
## buttons for several steps.
func _add_buttons_for(target_step: SteamRollerStep, flow: HFlowContainer) -> void:
	# Only the row's own non-optional step drives completion. Optional buttons
	# are shortcuts: they gate nothing and are always enabled.
	var is_main := (target_step == step) and not target_step.is_optional
	var specs := target_step.get_button_specs()
	for spec in specs:
		var btn := Button.new()
		btn.text = str(spec.get("label", ""))
		# Two buttons have to share the width of a narrow dock.
		btn.custom_minimum_size = Vector2(150.0 if specs.size() > 1 else 180.0, 0.0)
		var entry := {
			"button": btn,
			"step": target_step,
			"overrides": spec.get("overrides", {}),
			"marks_completion": is_main,
			"label": btn.text,
		}
		_buttons.append(entry)
		btn.pressed.connect(_on_any_button_pressed.bind(entry))
		flow.add_child(btn)
	if not target_step.id.is_empty() and not _hosted_ids.has(target_step.id):
		_hosted_ids.append(target_step.id)


## Give this row a console if `src_step` produces output and it has none yet.
## Optional push buttons attach to rows (like a plain checkbox) that would
## otherwise have nowhere to show the output those pushes now stream.
func _ensure_console(src_step: SteamRollerStep) -> void:
	if _console != null or not src_step.produces_output():
		return
	_console = ConsoleScene.instantiate()
	add_child(_console)


func _set_buttons_disabled(value: bool) -> void:
	for e in _buttons:
		var b: Button = e["button"]
		if is_instance_valid(b):
			b.disabled = value


# --- Event handlers --------------------------------------------------------

func _on_checkbox_toggled(value: bool) -> void:
	runner.set_completed(step.id, value)


func _on_input_text_changed(new_text: String) -> void:
	if not step.target_variable.is_empty():
		runner.set_variable(step.target_variable, new_text)
	if not step.project_setting_path.is_empty():
		ProjectSettings.set_setting(step.project_setting_path, new_text)
		ProjectSettings.save()
	var is_complete := (not step.require_non_empty) or (not new_text.is_empty())
	runner.set_completed(step.id, is_complete)


func _on_step_input_set(changed_id: String, new_value: String) -> void:
	if _input and step.id == changed_id:
		_input.text = new_value


## Handler for any button in this row. Only the row's own non-optional step
## updates completion; optional buttons gate nothing. Every button in the row
## is disabled for the duration, so a second export or upload cannot be
## launched on top of the first.
func _on_any_button_pressed(entry: Dictionary) -> void:
	var target_step: SteamRollerStep = entry["step"]
	var btn: Button = entry["button"]
	if _console:
		_console.clear_log()
	_set_buttons_disabled(true)
	btn.text = "Running..."
	# Route output to this row's console whichever button was pressed, so an
	# optional step attached here streams into the row the user clicked.
	var console_id := ""
	if _console != null:
		console_id = step.id if not step.id.is_empty() else target_step.id
	var ok: bool = await runner.execute_step(target_step, entry["overrides"], console_id)
	if not is_instance_valid(btn) or not is_inside_tree():
		return  # the row was rebuilt while the step ran
	btn.text = str(entry["label"])
	if bool(entry["marks_completion"]):
		runner.set_completed(step.id, ok)
	elif not ok:
		push_error("[SteamRoller] Optional action '%s' failed." % str(entry["label"]))
	_refresh()


func _on_state_changed(changed_id: String) -> void:
	if changed_id == step.id or step.depends_on.has(changed_id):
		_refresh()


func _on_variables_changed() -> void:
	_refresh_description()


func _on_log_line(target_id: String, line: String) -> void:
	# Accept output from this row's own step and from any optional step whose
	# button this row hosts - those have no console of their own.
	if _console and _hosted_ids.has(target_id):
		_console.append(line)


func _on_busy_changed(_busy: bool) -> void:
	_refresh()


func _refresh() -> void:
	if _checkbox:
		var done := runner.is_completed(step.id)
		if _checkbox.button_pressed != done:
			_checkbox.set_pressed_no_signal(done)
	var busy := runner.is_busy()
	# Exports lock once complete: they overwrite their destination, so they are
	# one-shot until Reset-and-increment restarts the checklist.
	var locked := step.locks_when_completed() and runner.is_completed(step.id)
	for e in _buttons:
		var b: Button = e["button"]
		if not is_instance_valid(b):
			continue
		var s: SteamRollerStep = e["step"]
		# Main buttons are gated by dependencies; optional buttons are always
		# available - but nothing is clickable while a step is running.
		var gated: bool = (s == step) and not s.is_optional and not runner.is_enabled(s)
		b.disabled = busy or gated or (locked and bool(e["marks_completion"]))
	_refresh_description()


func _refresh_description() -> void:
	if _description_label == null:
		return
	_description_label.text = runner.resolve_display(step.description)


static func _apply_editor_mono_font(label: RichTextLabel) -> void:
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
		var font_size: int = int(settings.get_setting("interface/editor/main_font_size"))
		label.add_theme_font_size_override("mono_font_size", font_size)
