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
var _action_button: Button = null
var _button_flow: HFlowContainer = null
var _console: SteamRollerConsole = null
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
	var btn := _make_button_for(optional_step)
	_button_flow.add_child(btn)


## Start a new button line inside this row (no separator in the parent list).
## Creates a second HFlowContainer and re-points _button_flow to it so that
## subsequent attach_optional_button calls land on the new line.
func attach_new_button_line(optional_step: SteamRollerStep) -> void:
	var flow := HFlowContainer.new()
	flow.alignment = HFlowContainer.ALIGNMENT_CENTER
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(flow)
	_button_flow = flow
	var btn := _make_button_for(optional_step)
	flow.add_child(btn)


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
		_action_button = _make_button_for(step)
		_button_flow.add_child(_action_button)

	# Console (only for non-optional actions that produce output).
	if not step.is_optional and step.produces_output():
		_console = ConsoleScene.instantiate()
		add_child(_console)

	# Subscribe to runner state changes after everything is built.
	runner.step_state_changed.connect(_on_state_changed)
	runner.log_line_emitted.connect(_on_log_line)
	if step.action == SteamRollerStep.Action.INPUT:
		runner.step_input_set.connect(_on_step_input_set)
	if not step.description.is_empty():
		runner.variables_changed.connect(_on_variables_changed)

	_refresh()


# --- Header builders -------------------------------------------------------

func _build_checkbox_header() -> void:
	var hbox := HBoxContainer.new()
	add_child(hbox)
	_checkbox = CheckBox.new()
	_checkbox.toggled.connect(_on_checkbox_toggled)
	hbox.add_child(_checkbox)
	var label := Label.new()
	label.text = step.display_name
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(label)


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

## Build a button for any step (main or optional). Wires the press handler
## to call the runner. The button captures its own step reference so a single
## row can host buttons for several optional steps.
func _make_button_for(target_step: SteamRollerStep) -> Button:
	var btn := Button.new()
	var lbl := target_step.button_label if not target_step.button_label.is_empty() \
			else target_step.get_default_button_label()
	btn.text = lbl
	btn.custom_minimum_size = Vector2(180, 0)
	btn.pressed.connect(_on_any_button_pressed.bind(target_step, btn))
	# Only the main step's button is gated by dependencies/requirements.
	# Optional buttons (whether attached to another row or standing alone)
	# are always enabled.
	if target_step == step and target_step.has_action_button() and not target_step.is_optional:
		btn.disabled = not runner.is_enabled(target_step)
	return btn


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


## Handler for any button in this row's flow container. The "main" path
## (updates completion, drives the console) only applies to non-optional
## steps. Optional buttons — whether attached to another row or standing
## alone in an orphan row — re-enable themselves and don't touch state.
func _on_any_button_pressed(target_step: SteamRollerStep, btn: Button) -> void:
	var is_main := (target_step == step) and not target_step.is_optional
	if is_main and _console:
		_console.clear_log()
	btn.disabled = true
	var orig_label := btn.text
	btn.text = "Running..."
	var ok := await runner.execute_step(target_step)
	btn.text = orig_label
	if is_main:
		runner.set_completed(step.id, ok)
		_refresh()
	else:
		btn.disabled = false
		if not ok:
			var label := target_step.button_label if not target_step.button_label.is_empty() else target_step.get_default_button_label()
			push_error("[SteamRoller] Optional action '%s' failed." % label)


func _on_state_changed(changed_id: String) -> void:
	if changed_id == step.id or step.depends_on.has(changed_id):
		_refresh()


func _on_variables_changed() -> void:
	_refresh_description()


func _on_log_line(target_id: String, line: String) -> void:
	# Only show log lines from the main step. Optional steps print directly
	# to the editor output (via push_warning / push_error) rather than the
	# per-step console.
	if target_id == step.id and _console:
		_console.append(line)


func _refresh() -> void:
	if _checkbox:
		var done := runner.is_completed(step.id)
		if _checkbox.button_pressed != done:
			_checkbox.set_pressed_no_signal(done)
	if _action_button and not step.is_optional:
		_action_button.disabled = not runner.is_enabled(step)
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
