@tool
class_name SteamRollerStepRunner extends Node
## Runs a SteamRoller checklist: completion, gating, logging and dispatch.
##
## The panel owns one runner. Rows ask it whether a step is enabled, run steps
## through execute_step(), and listen for state, log and busy changes. What an
## action does lives in SteamRollerActions; processes in SteamRollerShell; the
## ${NAME} variables in SteamRollerVariables.

## A step was ticked or unticked.
signal step_state_changed(step_id: String)
## A line for the console of the row whose step id is `console_id`.
signal log_line_emitted(console_id: String, line: String)
## The variables were rebuilt; descriptions and the header refresh.
signal variables_changed
## A step started running (true) or the last running step ended (false).
signal busy_changed(busy: bool)
## The checklist was reset: rows clear their consoles and re-read their inputs,
## and the panel shows the first tab.
signal reset_requested

var config: SteamRollerConfig
var vars := SteamRollerVariables.new()
var shell: SteamRollerShell
## Step id -> why it cannot run (a missing addon), for steps that cannot.
var missing_requirements: Dictionary[String, String] = {}

var _actions: SteamRollerActions
var _steps: Dictionary[String, SteamRollerStep] = {}
var _completed: Dictionary[String, bool] = {}
## The row whose console receives log lines: chosen by the outermost
## execute_step(), inherited by the steps it runs, restored when they return.
var _console_id := ""
var _busy_depth := 0
var _stop_requested := false
## Bumped by abandon(): a run that started before it no longer touches the busy
## count or the console when (if ever) it returns.
var _generation := 0
## An INPUT changed a project setting that is not saved yet.
var _settings_dirty := false


func _init() -> void:
	shell = SteamRollerShell.new(self)
	_actions = SteamRollerActions.new(self, shell)


func _ready() -> void:
	shell.prune_logs()


# --- Config ----------------------------------------------------------------------

func load_config(cfg: SteamRollerConfig) -> void:
	config = cfg
	_steps.clear()
	_completed.clear()
	missing_requirements.clear()
	vars.clear_bindings()
	for s in cfg.steps:
		if s == null or s.action == SteamRollerStep.Action.NEW_TAB:
			continue
		if not s.id.is_empty():
			if _steps.has(s.id):
				push_warning("[SteamRoller] Two steps share the id '%s'." % s.id)
			_steps[s.id] = s
		if s.action == SteamRollerStep.Action.INPUT and not s.target_variable.is_empty() \
				and not s.project_setting_path.is_empty():
			vars.bind_setting(s.target_variable, s.project_setting_path)
	_validate()
	refresh_variables()


func find_step(step_id: String) -> SteamRollerStep:
	return _steps.get(step_id, null)


## A step's name for messages: its display name, else its button, else its id.
func step_label(s: SteamRollerStep) -> String:
	if not s.display_name.is_empty():
		return "'%s'" % s.display_name
	if not s.button_label.is_empty():
		return "'%s'" % s.button_label
	return "'%s'" % s.id


func refresh_variables() -> void:
	var own: Dictionary[String, String] = {}
	if config:
		own = config.variables
	vars.rebuild(own)
	variables_changed.emit()


## Warn about everything a config can get wrong; nothing here blocks the dock.
func _validate() -> void:
	var legacy := false
	for s in config.steps:
		if s == null:
			push_warning("[SteamRoller] The config has an empty step; it is skipped.")
			continue
		var who := s.id if not s.id.is_empty() else (s.display_name if not s.display_name.is_empty() else s.button_label)
		for dep in s.depends_on + s.depends_on_any:
			if not _steps.has(dep):
				push_warning("[SteamRoller] Step '%s' depends on an unknown step '%s'." % [who, dep])
		for sid in s.step_ids:
			if not _steps.has(sid):
				push_warning("[SteamRoller] Step '%s' runs an unknown step '%s'." % [who, sid])
		if not s.attach_to.is_empty():
			var host := find_step(s.attach_to)
			if host == null or host == s or not host.attach_to.is_empty():
				push_warning("[SteamRoller] Step '%s' attaches to '%s', which is not a step with a row of its own; it gets a row instead."
					% [who, s.attach_to])
		legacy = legacy or (s.is_optional and s.attach_to.is_empty())
		match s.action:
			SteamRollerStep.Action.RUN_GDUNIT:
				if not SteamRollerActions.class_registered("GdUnitCommandHandler"):
					missing_requirements[s.id] = "GdUnit4 (GdUnitCommandHandler not found)"
			SteamRollerStep.Action.RUN_COMMAND_ASYNC:
				push_warning("[SteamRoller] Step '%s' uses RUN_COMMAND_ASYNC, which now runs as RUN_COMMAND." % who)
			SteamRollerStep.Action.RENDER_QUEUE:
				_validate_render(s, who)
	if legacy:
		print("[SteamRoller] The config marks steps is_optional (SteamRoller 0.2): they join the row above. attach_to = \"<step id>\" says which row.")


func _validate_render(s: SteamRollerStep, who: String) -> void:
	if s.render_jobs.is_empty():
		push_warning("[SteamRoller] Render step '%s' has no render_jobs." % who)
	var ids: Dictionary[String, bool] = {}
	for job in s.render_jobs:
		if job == null:
			continue
		if job.id.is_empty() or ids.has(job.id):
			push_warning("[SteamRoller] Render step '%s' has a job with no id, or a repeated one ('%s')." % [who, job.id])
		ids[job.id] = true
		if job.passes.is_empty():
			push_warning("[SteamRoller] Render job '%s' has no passes." % job.id)


# --- State -----------------------------------------------------------------------

func is_completed(step_id: String) -> bool:
	return _completed.get(step_id, false)


func set_completed(step_id: String, value: bool) -> void:
	if step_id.is_empty() or (_completed.has(step_id) and _completed[step_id] == value):
		return
	_completed[step_id] = value
	step_state_changed.emit(step_id)


func is_enabled(s: SteamRollerStep) -> bool:
	return blocked_reason(s).is_empty()


## Why a step cannot run yet ("" when it can): a missing addon, unticked steps
## in depends_on, or none ticked of depends_on_any.
func blocked_reason(s: SteamRollerStep) -> String:
	if missing_requirements.has(s.id):
		return "Missing " + missing_requirements[s.id]
	var waiting := PackedStringArray()
	for dep in s.depends_on:
		if not is_completed(dep):
			waiting.append(_dep_label(dep))
	if not s.depends_on_any.is_empty():
		var any := false
		var names := PackedStringArray()
		for dep in s.depends_on_any:
			any = any or is_completed(dep)
			names.append(_dep_label(dep))
		if not any:
			waiting.append(" or ".join(names))
	return "" if waiting.is_empty() else "Waiting on " + ", ".join(waiting)


func _dep_label(step_id: String) -> String:
	var s := find_step(step_id)
	return step_label(s) if s != null else "'%s'" % step_id


## Untick every step, clear every console, show the first tab (Reset).
func reset_checklist() -> void:
	for step_id: String in _completed:
		_completed[step_id] = false
	refresh_variables()
	reset_requested.emit()
	for step_id: String in _steps:
		step_state_changed.emit(step_id)


# --- Inputs ------------------------------------------------------------------------

## An INPUT step's current text: its setting's value, or when that is empty its
## default, which is then written to the setting (saved with the next save).
func input_value(s: SteamRollerStep) -> String:
	if s.project_setting_path.is_empty():
		var held := str(vars.values.get(s.target_variable, ""))
		return held if not held.is_empty() else s.default_value
	var stored := SteamRollerSettings.text(s.project_setting_path)
	if stored.is_empty() and not s.default_value.is_empty():
		SteamRollerSettings.put(s.project_setting_path, s.default_value)
		_settings_dirty = true
		return s.default_value
	return stored


## The user typed into an INPUT step: set its setting (in memory) or variable,
## then refresh the variables. save_settings() writes project.godot.
func set_input(s: SteamRollerStep, text: String) -> void:
	if not s.project_setting_path.is_empty():
		SteamRollerSettings.put(s.project_setting_path, text)
		_settings_dirty = true
	elif not s.target_variable.is_empty():
		vars.set_runtime(s.target_variable, text)
	refresh_variables()
	set_completed(s.id, s.input_complete(text))


## Write INPUT edits to project.godot, if there are any.
func save_settings() -> void:
	if _settings_dirty:
		_settings_dirty = false
		SteamRollerSettings.save()


# --- Running ---------------------------------------------------------------------

func is_busy() -> bool:
	return _busy_depth > 0


## True once Stop was pressed during the current run.
func stop_requested() -> bool:
	return _stop_requested


## The console the running step writes to (names its log files).
func console_id() -> String:
	return _console_id


## Run one step and return whether it succeeded. `overrides` is merged over the
## step's resolved params (how one step offers several buttons). `console`
## names the row whose console shows the output; a step run by another step
## writes to its parent's. An instant step (is_instant) never makes the runner
## busy, so it can run while another step does.
func execute_step(s: SteamRollerStep, overrides: Dictionary = {}, console: String = "") -> bool:
	var instant := s.is_instant()
	var generation := _generation
	var outer_console := _console_id
	if _console_id.is_empty() or instant:
		_console_id = console if not console.is_empty() else s.id
	if not instant:
		_busy_depth += 1
		if _busy_depth == 1:
			_stop_requested = false
			busy_changed.emit(true)
	save_settings()
	refresh_variables()
	var params := vars.resolve_params(s.params)
	params.merge(overrides, true)
	var ok: bool = await _actions.run(s, params, overrides)
	if generation != _generation:
		return false   # abandoned while it ran: the dock has moved on
	if _stop_requested and not instant and _busy_depth == 1:
		log_line("Stopped.")
	if not instant:
		_busy_depth -= 1
		if _busy_depth == 0:
			busy_changed.emit(false)
	_console_id = outer_console
	return ok and not (_stop_requested and not instant)


## Give up on whatever is running, after stopping its process: for a run that
## can no longer finish (its coroutine was cancelled by a script reload, or a
## script error ended it), which would otherwise leave the dock busy for good.
func abandon() -> void:
	if not is_busy():
		return
	shell.stop()
	if _actions.owns_play and EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	_generation += 1
	_busy_depth = 0
	_stop_requested = false
	_console_id = ""
	push_warning("[SteamRoller] Abandoned the running step (the dock was reloaded while it ran).")
	busy_changed.emit(false)


## Stop the running step: end its process (and everything it started), or the
## play session it started, and let a batch or a chain of steps stop between
## items.
func stop() -> void:
	if not is_busy() or _stop_requested:
		return
	_stop_requested = true
	log_line("Stopping…")
	shell.stop()
	if _actions.owns_play and EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()


# --- Logging ---------------------------------------------------------------------
# Every line goes to the editor's Output panel and to the console of the row
# that was pressed.

## `to_output` false keeps the line out of the Output panel (a heartbeat).
func log_line(line: String, to_output: bool = true) -> void:
	if to_output:
		print("[SteamRoller] " + line)
	if not _console_id.is_empty():
		log_line_emitted.emit(_console_id, line)


func log_error(line: String) -> void:
	push_error("[SteamRoller] " + line)
	if not _console_id.is_empty():
		log_line_emitted.emit(_console_id, "[err] " + line)
