@tool
class_name SteamRollerRunner extends Node
## Owns the variable bag, completion state, and step execution.
##
## Variable substitution and Godot tool implementations live here directly
## — there's not enough volume to justify separate helper files.

signal step_state_changed(step_id: String)
signal log_line_emitted(step_id: String, line: String)
signal variables_changed
signal step_input_set(step_id: String, new_value: String)
signal tab_switch_requested(tab_index: int)
## Emitted on the 0<->1 edges of step execution. The UI uses it to disable every
## action button while something is running - now that external processes no
## longer block the editor, nothing else stops a second click.
signal busy_changed(busy: bool)

const TOKEN_REGEX := r"\$\{([A-Z_][A-Z0-9_]*)\}"

## How often a running external process is polled for exit and new output.
## Short enough that output feels live, long enough that polling costs nothing.
const SHELL_POLL_INTERVAL := 0.25

## How often a still-running process reports that it is alive. Output from a
## redirected command generally cannot be read until it exits (see _drain_log),
## so without this a ten-minute upload would sit in complete silence.
const HEARTBEAT_SECONDS := 10

## Lines of a failed quiet command's log echoed to the console. Enough to see
## the actual error without replaying a whole export.
const QUIET_FAIL_TAIL := 40

## Log files kept per project in the cache directory before the oldest are
## pruned. Logs are kept on success too: a failed steamcmd push is far easier to
## diagnose from the full file than from the three-line console tail.
const LOGS_KEPT := 30

var config: SteamRollerConfig

## Runtime variable bag: config.variables + dynamic built-ins + values
## written by input steps.
var variables: Dictionary = {}

## step_id -> bool completion.
var completed: Dictionary = {}

## step_id -> tab index (used by RESET_AND_INCREMENT to know which tab to reset).
var step_tab_index: Dictionary = {}

## step_id -> missing requirement string (empty when satisfied).
var missing_requirements: Dictionary = {}

## Step id whose inline console receives log output. Chosen by the OUTERMOST
## execute_step() call and inherited by nested ones, so a RUN_STEPS aggregate
## collects the output of every child it runs - including optional children,
## which have no console of their own.
var _console_step_id: String = ""
var _busy_depth: int = 0
var _log_seq: int = 0
var _token_regex: RegEx = null
var _ansi_regex: RegEx = null


func _ready() -> void:
	_token_regex = RegEx.new()
	_token_regex.compile(TOKEN_REGEX)
	# Console colour codes from tools like butler, stripped from captured output.
	_ansi_regex = RegEx.new()
	_ansi_regex.compile("\u001b\\[[0-9;?]*[ -/]*[@-~]")
	_prune_logs()


## True while any step is executing (including nested children).
func is_busy() -> bool:
	return _busy_depth > 0


# --- Config loading --------------------------------------------------------

func load_config(cfg: SteamRollerConfig) -> void:
	config = cfg
	completed.clear()
	missing_requirements.clear()
	step_tab_index.clear()
	rebuild_variables()
	_validate_and_index()


func rebuild_variables() -> void:
	variables.clear()
	if config:
		for key in config.variables.keys():
			variables[str(key)] = str(config.variables[key])
	# Built-in dynamic variables, computed fresh each rebuild.
	variables["VERSION"] = str(ProjectSettings.get_setting("application/config/version", ""))
	variables["APP_NAME"] = str(ProjectSettings.get_setting("application/config/name", ""))
	var _raw_commit: String = str(ProjectSettings.get_setting("application/config/commit_message", ""))
	variables["COMMIT_MESSAGE"] = _raw_commit
	variables["COMMIT_MESSAGE_SLUG"] = _sanitize_path_segment(_raw_commit).replace(" ", "_")
	variables["STEAM_BRANCH"] = str(ProjectSettings.get_setting("application/steamroller/steam_branch", ""))
	variables["DEMO_MODE"] = "true" if _get_demo_mode() else "false"
	variables["USER_DIR"] = ProjectSettings.globalize_path("user://")
	variables["PROJECT_DIR"] = ProjectSettings.globalize_path("res://")
	variables["PLATFORM"] = OS.get_name()
	variables["GODOT_EXE"] = OS.get_executable_path()
	variables_changed.emit()


func _get_demo_mode() -> bool:
	const SETTING := "application/steamroller/demo_mode"
	if ProjectSettings.has_setting(SETTING):
		return bool(ProjectSettings.get_setting(SETTING))
	return false


## Converts a free-text string into a safe, lowercase path segment.
## Lowercases the text and removes characters that are invalid in folder names
## (anything other than alphanumeric, space, underscore, or hyphen).
static func _sanitize_path_segment(text: String) -> String:
	var result := text.to_lower()
	var clean := ""
	for ch in result:
		if ch.unicode_at(0) >= 97 and ch.unicode_at(0) <= 122: # a-z
			clean += ch
		elif ch.unicode_at(0) >= 48 and ch.unicode_at(0) <= 57: # 0-9
			clean += ch
		elif ch == " " or ch == "_" or ch == "-":
			clean += ch
	return clean


## Validate IDs, depends_on references, and per-step requirements.
## Everything emits warnings rather than blocking the panel.
func _validate_and_index() -> void:
	if config == null:
		return
	var seen_ids := {}
	var current_tab := 0
	for step in config.steps:
		if step == null:
			push_warning("[SteamRoller] Null step in config — skipping.")
			continue
		if step.action == SteamRollerStep.Action.NEW_TAB:
			current_tab += 1
			continue
		var id: String = step.id
		if not id.is_empty():
			if seen_ids.has(id):
				push_warning("[SteamRoller] Duplicate step ID: '%s'" % id)
			seen_ids[id] = true
			step_tab_index[id] = current_tab
		# Per-action requirement checks.
		if step.action == SteamRollerStep.Action.RUN_GDUNIT:
			if not _class_name_registered("GdUnitCommandHandler"):
				missing_requirements[id] = "GdUnit4 (GdUnitCommandHandler not found)"
				push_warning("[SteamRoller] Step '%s' requires GdUnit4." % id)
	# Second pass: validate depends_on references.
	for step in config.steps:
		if step == null or step.action == SteamRollerStep.Action.NEW_TAB:
			continue
		for dep in step.depends_on:
			if not seen_ids.has(dep):
				push_warning("[SteamRoller] Step '%s' depends on unknown ID '%s'." % [step.id, dep])


static func _class_name_registered(target: String) -> bool:
	if ClassDB.class_exists(target):
		return true
	for entry in ProjectSettings.get_global_class_list():
		if entry.get("class", "") == target:
			return true
	return false


# --- State -----------------------------------------------------------------

func is_completed(step_id: String) -> bool:
	return completed.get(step_id, false)


func is_enabled(step: SteamRollerStep) -> bool:
	if missing_requirements.has(step.id):
		return false
	for dep in step.depends_on:
		if not is_completed(dep):
			return false
	return true


func set_completed(step_id: String, value: bool) -> void:
	completed[step_id] = value
	step_state_changed.emit(step_id)
	# Notify everyone so dependents re-evaluate.
	for other_id in step_tab_index.keys():
		if other_id != step_id:
			step_state_changed.emit(other_id)


func set_variable(name: String, value: String) -> void:
	variables[name] = value
	variables_changed.emit()


# --- Variable substitution -------------------------------------------------

func resolve(template: String) -> String:
	if template.is_empty():
		return template
	# Iterate until stable so that variable values containing ${...} tokens
	# (e.g. BUILDS_DIR = "${PROJECT_DIR}../builds") are fully expanded.
	var result := template
	for _pass in range(8):
		var matches := _token_regex.search_all(result)
		if matches.is_empty():
			break
		var next := result
		for i in range(matches.size() - 1, -1, -1):
			var m := matches[i]
			var name := m.get_string(1)
			var replacement: String
			if variables.has(name):
				replacement = str(variables[name])
			else:
				push_warning("[SteamRoller] Undefined variable: ${%s}" % name)
				replacement = m.get_string(0)
			next = next.substr(0, m.get_start()) + replacement + next.substr(m.get_end())
		if next == result:
			break
		result = next
	return result


## Like resolve() but collapses PROJECT_DIR and USER_DIR to "..." so that
## descriptions stay compact regardless of where the project lives on disk.
func resolve_display(template: String) -> String:
	var result := resolve(template)
	result = result.replace("\\", "/")
	for key in ["PROJECT_DIR", "USER_DIR"]:
		var root: String = variables.get(key, "").replace("\\", "/").trim_suffix("/")
		if root.is_empty():
			continue
		result = result.replace(root + "/", ".../")
		result = result.replace(root, "...")
	# Collapse ".../" followed by any number of "../" up-traversals.
	var prev := ""
	while prev != result:
		prev = result
		result = result.replace(".../../", ".../")
	return result


func resolve_args(template_args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for a in template_args:
		out.append(resolve(a))
	return out


func resolve_params(template_params: Dictionary) -> Dictionary:
	var out := {}
	for key in template_params.keys():
		out[key] = _resolve_value(template_params[key])
	return out


func _resolve_value(v: Variant) -> Variant:
	if v is String:
		return resolve(v)
	if v is Array:
		var out := []
		for entry in v:
			out.append(_resolve_value(entry))
		return out
	if v is Dictionary:
		return resolve_params(v)
	if v is PackedStringArray:
		return resolve_args(v)
	return v


# --- Logging ---------------------------------------------------------------
# Everything goes to the Godot Output panel via print/push_error, AND to the
# inline console of whichever step is currently running, so long external
# processes show live progress instead of going quiet until they exit.

func log_line(line: String) -> void:
	print("[SteamRoller] " + line)
	if not _console_step_id.is_empty():
		log_line_emitted.emit(_console_step_id, line)


## Use this from tool implementations when reporting failure conditions.
## Always surfaces in the Godot Output panel AND in the inline step console
## so the user sees the failure even if they are not watching the full log.
func log_error(line: String) -> void:
	push_error("[SteamRoller] " + line)
	if not _console_step_id.is_empty():
		log_line_emitted.emit(_console_step_id, "[err] " + line)


# --- Execution dispatch ----------------------------------------------------

## Run one step. `overrides` is merged over the step's resolved params, which is
## how one step can offer several buttons (Export All Debug vs Release).
## `console_id` names the step whose console should show the output; it is only
## honoured by the outermost call, so nested children stream into the console of
## the row the user actually pressed.
func execute_step(step: SteamRollerStep, overrides: Dictionary = {}, console_id: String = "") -> bool:
	var prev_console := _console_step_id
	if prev_console.is_empty():
		if not console_id.is_empty():
			_console_step_id = console_id
		elif not step.is_optional:
			_console_step_id = step.id
	_busy_depth += 1
	if _busy_depth == 1:
		busy_changed.emit(true)

	rebuild_variables()
	var resolved := resolve_params(step.params)
	for key in overrides.keys():
		resolved[key] = overrides[key]

	var ok := false
	match step.action:
		SteamRollerStep.Action.RUN_GDUNIT:
			ok = await _run_gdunit_tests()
		SteamRollerStep.Action.RECORD_MOVIE:
			ok = await _record_movie(resolved)
		SteamRollerStep.Action.DELETE_FOLDER:
			ok = await _delete_folder(resolved)
		SteamRollerStep.Action.CREATE_FOLDERS:
			ok = await _create_folders(resolved)
		SteamRollerStep.Action.ARCHIVE_FOLDER:
			ok = await _archive_folder(resolved)
		SteamRollerStep.Action.CLEAR_USER_DATA:
			ok = await _clear_user_data()
		SteamRollerStep.Action.OPEN_IN_EXPLORER:
			ok = _open_in_explorer(resolved)
		SteamRollerStep.Action.COPY_TO_CLIPBOARD:
			ok = _copy_to_clipboard(resolved)
		SteamRollerStep.Action.RESET_AND_INCREMENT:
			ok = _reset_and_increment()
		SteamRollerStep.Action.RUN_COMMAND:
			ok = await _run_command(step)
		SteamRollerStep.Action.RUN_COMMAND_ASYNC:
			ok = await _run_command_async(step, resolved)
		SteamRollerStep.Action.RUN_STEPS:
			ok = await _run_steps(step, overrides)
		SteamRollerStep.Action.WRITE_VDF_DESC:
			ok = _write_vdf_desc(resolved)
		SteamRollerStep.Action.EXPORT_PROJECT:
			ok = await _export_project(resolved)
		_:
			log_error("Step has no executable action: %s" % str(step.action))

	_busy_depth -= 1
	if _busy_depth == 0:
		busy_changed.emit(false)
	# Restore rather than clear: a parent's logging after a nested child returns
	# must still reach the console the parent was writing to.
	_console_step_id = prev_console
	return ok


# --- External processes ----------------------------------------------------
# Every external command goes through _shell_async: create_process plus a
# polled await, so the editor stays interactive for the whole run. stdout and
# stderr are redirected to a log file, which is both kept for diagnosis and
# emitted into the running step's console. A heartbeat marks progress while the
# command runs; see _drain_log for why the output itself normally only arrives
# once the process exits.

## The command line _run_command has always built: "exe" arg arg ...
static func _build_cmd_line(exe: String, args: PackedStringArray) -> String:
	return "\"%s\" %s" % [exe, " ".join(_quote_args(args))]


## Run a cmd.exe command line WITHOUT blocking the editor. The editor stays
## interactive for the whole run; a heartbeat reports progress, and the captured
## output is emitted when the process exits (see _drain_log for why it usually
## cannot be read sooner). Returns the exit code, or -1 if it could not start.
## `quiet` keeps a very chatty command's output out of the console: the log file
## still gets everything, but only a failure is echoed. Exports need it — they
## emit thousands of "Storing File" lines nobody wants to scroll past.
func _shell_async(cmd_body: String, working_dir: String = "", quiet: bool = false) -> int:
	var log_path := _make_log_path()
	if log_path.is_empty():
		return -1
	var body := cmd_body
	if not working_dir.is_empty():
		# A trailing separator would escape its own closing quote: "C:\dir\".
		var wd := working_dir.trim_suffix("/").trim_suffix("\\")
		body = "cd /d \"%s\" && %s" % [wd, body]
	# chcp keeps tool output out of the OEM codepage; >nul hides its own banner.
	body = "chcp 65001>nul & " + body
	# The parens group the whole body so a failing `cd` is captured too, rather
	# than the redirect binding to the command after the &&.
	var full_cmd := "(%s) > \"%s\" 2>&1" % [body, log_path]
	# open_console = false: the output is captured, so a console window would
	# only flash and show nothing.
	var pid := OS.create_process("cmd", ["/c", full_cmd], false)
	if pid <= 0:
		log_error("Could not start: %s" % cmd_body)
		return -1
	var offset := 0
	var started := Time.get_ticks_msec()
	var next_beat := HEARTBEAT_SECONDS * 1000
	while OS.is_process_running(pid):
		await get_tree().create_timer(SHELL_POLL_INTERVAL).timeout
		# Usually a no-op until the process exits and releases the file, but it
		# costs nothing and picks output up early whenever the file IS readable.
		if not quiet:
			offset = _drain_log(log_path, offset, false)
		var elapsed := Time.get_ticks_msec() - started
		if elapsed >= next_beat:
			log_line("… still running (%ds)" % int(elapsed / 1000))
			next_beat += HEARTBEAT_SECONDS * 1000
	var exit_code := OS.get_process_exit_code(pid)
	if quiet:
		if exit_code != 0:
			log_error("Full output: %s" % log_path)
			_emit_log_tail(log_path, QUIET_FAIL_TAIL)
	else:
		# Final drain: this is where redirected output normally arrives. The tail
		# may be a line with no terminating newline, hence `final`.
		_drain_log(log_path, offset, true)
	return exit_code


## Echo the last `max_lines` of a log file, for a quiet command that failed.
func _emit_log_tail(path: String, max_lines: int) -> void:
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		log_error("Cannot read log %s" % path)
		return
	var text := fa.get_as_text()
	fa.close()
	var lines := text.replace("\r\n", "\n").split("\n")
	var start: int = maxi(0, lines.size() - max_lines)
	if start > 0:
		log_line("… %d earlier line(s) omitted" % start)
	for i in range(start, lines.size()):
		var line := str(lines[i]).strip_edges()
		if not line.is_empty():
			log_line(line)


## Read everything appended to `path` since `from_offset`, emit the complete
## lines, and return the new read position.
##
## The offset only ever advances to the last newline in the chunk; the leftover
## bytes are simply re-read next poll. That one rule handles both half-written
## lines and a multi-byte UTF-8 sequence split across a read boundary, with no
## pending buffer to maintain. `final` also emits a trailing partial line.
##
## MEASURED ON WINDOWS: while cmd.exe holds a `>` redirect target open,
## FileAccess.open() on it fails with ERR_FILE_CANT_OPEN — Godot's share mode
## conflicts with cmd's, even though other processes can read the file happily.
## So for _shell_async this reliably returns `from_offset` until the process
## exits, and the output lands in one batch at the end. It is kept incremental
## regardless because RUN_COMMAND_ASYNC points it at `tail_file`, a file written
## by a third-party tool that often IS readable while it runs. True live output
## would need OS.execute_with_pipe plus a reader thread, and even then only for
## tools that do not buffer stdout when it is not a console (ping and steamcmd
## do buffer; Go tools like butler do not).
func _drain_log(path: String, from_offset: int, final: bool) -> int:
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return from_offset  # not created yet, or briefly locked - retry next poll
	var size := fa.get_length()
	if size <= from_offset:
		fa.close()
		return from_offset
	fa.seek(from_offset)
	var raw := fa.get_buffer(size - from_offset)
	fa.close()
	var text := raw.get_string_from_utf8()
	var consumed := size
	if not final:
		var cut := text.rfind("\n")
		if cut == -1:
			return from_offset  # no complete line yet
		text = text.substr(0, cut + 1)
		consumed = from_offset + text.to_utf8_buffer().size()
	_emit_process_lines(text)
	return consumed


func _emit_process_lines(text: String) -> void:
	for raw_line in text.replace("\r\n", "\n").split("\n"):
		var line: String = raw_line
		# Progress bars redraw themselves with \r - keep only the final state.
		var cr := line.rfind("\r")
		if cr != -1:
			line = line.substr(cr + 1)
		if _ansi_regex:
			line = _ansi_regex.sub(line, "", true)
		line = line.strip_edges()
		if not line.is_empty():
			log_line(line)


## Where process logs live. Deliberately NOT user:// - CLEAR_USER_DATA deletes
## that directory through this very helper, and would be removing the log it is
## streaming from. Namespaced per project so parallel editors do not collide.
func _log_dir() -> String:
	var base := OS.get_cache_dir()
	if base.is_empty():
		base = ProjectSettings.globalize_path("user://")  # last resort
	var app := str(ProjectSettings.get_setting("application/config/name", "project"))
	var dir := base.path_join("steamroller_logs").path_join(app.validate_filename())
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


## A fresh, uniquely named, zero-length log file, so a stale read is impossible
## by construction. Returns "" if the file could not be created.
func _make_log_path() -> String:
	_log_seq += 1
	var slug := _console_step_id if not _console_step_id.is_empty() else "step"
	var stamp := Time.get_datetime_string_from_system(false, false) \
			.replace(":", "").replace("-", "")
	# Timestamp first so that a plain name sort is chronological, which is what
	# _prune_logs() relies on to drop the oldest.
	var path := _log_dir().path_join("%s_%03d_%s.log" % [stamp, _log_seq, slug.validate_filename()])
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa == null:
		log_error("Cannot create log file at %s (error %s)" % [path, str(FileAccess.get_open_error())])
		return ""
	fa.close()
	return path


## Keep the newest LOGS_KEPT logs. Timestamped names sort chronologically.
func _prune_logs() -> void:
	var dir := _log_dir()
	var names := DirAccess.get_files_at(dir)
	if names.size() <= LOGS_KEPT:
		return
	var sorted := Array(names)
	sorted.sort()
	for i in range(sorted.size() - LOGS_KEPT):
		DirAccess.remove_absolute(dir.path_join(str(sorted[i])))


# --- Tool implementations --------------------------------------------------
# All Windows-only for now. cmd.exe is used liberally so that nothing in the
# rest of the system needs to know about platform differences.

func _run_gdunit_tests() -> bool:
	if not _class_name_registered("GdUnitCommandHandler"):
		log_error("GdUnit4 not installed.")
		return false
	# Load classes lazily so this file has no hard dependency on GdUnit.
	var handler_script := _load_script_class("GdUnitCommandHandler")
	var cmd_script := _load_script_class("GdUnitCommandRunTestsOverall")
	if handler_script == null or cmd_script == null:
		log_error("Could not resolve GdUnit classes.")
		return false
	var handler = handler_script.instance()
	await handler.command_execute(cmd_script.ID)
	while EditorInterface.is_playing_scene():
		await get_tree().create_timer(0.5).timeout
	return true


static func _load_script_class(target: String) -> GDScript:
	for entry in ProjectSettings.get_global_class_list():
		if entry.get("class", "") == target:
			var path: String = entry.get("path", "")
			if not path.is_empty():
				return load(path)
	return null


func _record_movie(p: Dictionary) -> bool:
	var output_path: String = p.get("output_path", "")
	if output_path.is_empty():
		log_error("record_movie: missing 'output_path'.")
		return false
	var reencode: bool = p.get("reencode", false)

	ProjectSettings.set_setting("editor/movie_writer/movie_file", output_path)
	EditorInterface.movie_maker_enabled = true
	log_line("Movie maker enabled, recording to: %s" % output_path)

	var main_scene: String = ProjectSettings.get_setting("application/run/main_scene", "")
	if main_scene.is_empty():
		log_error("No main scene set.")
		EditorInterface.movie_maker_enabled = false
		return false
	EditorInterface.play_main_scene()
	log_line("Playing main scene: %s" % main_scene)

	while EditorInterface.is_playing_scene():
		await get_tree().create_timer(0.5).timeout

	EditorInterface.movie_maker_enabled = false
	log_line("Movie maker disabled.")

	if reencode:
		return await _reencode_video(output_path)
	return true


func _reencode_video(movie_path: String) -> bool:
	var compressed := movie_path.get_basename() + "_sample.mp4"
	log_line("Re-encoding with ffmpeg → %s" % compressed)
	var ffmpeg_args := [
		"-i", ProjectSettings.globalize_path(movie_path),
		"-vf", "scale=-1:1080",
		"-c:v", "libx264", "-crf", "23", "-preset", "medium",
		"-c:a", "aac", "-b:a", "128k", "-y",
		ProjectSettings.globalize_path(compressed),
	]
	var pid := OS.create_process("ffmpeg", ffmpeg_args, true)
	if pid <= 0:
		log_error("Failed to start ffmpeg. Is it on PATH?")
		return false
	while OS.is_process_running(pid):
		await get_tree().process_frame
	var exit_code := OS.get_process_exit_code(pid)
	if exit_code != OK:
		log_error("ffmpeg exited with code %s" % str(exit_code))
		return false
	# Delete the source AVI.
	var abs_avi := ProjectSettings.globalize_path(movie_path).replace("/", "\\")
	await _shell_async("del /f \"%s\"" % abs_avi)
	log_line("Re-encode complete.")
	return true


func _delete_folder(p: Dictionary) -> bool:
	var path: String = p.get("path", "")
	if path.is_empty():
		log_error("delete_folder: missing 'path'.")
		return false
	var abs := ProjectSettings.globalize_path(path).trim_suffix("/").replace("/", "\\")
	log_line("Deleting %s" % abs)
	var ec := await _shell_async("if exist \"%s\" rmdir /s /q \"%s\"" % [abs, abs])
	if ec != 0:
		log_error("Delete failed (exit %s)." % str(ec))
		return false
	var paths: Array = p.get("paths", [])
	if not paths.is_empty():
		return await _create_folders({"paths": paths})
	return true


func _create_folders(p: Dictionary) -> bool:
	var paths: Array = p.get("paths", [])
	if paths.is_empty():
		log_error("create_folders: missing 'paths'.")
		return false
	var all_ok := true
	for path in paths:
		var abs := ProjectSettings.globalize_path(str(path)).trim_suffix("/").replace("/", "\\")
		var ec := await _shell_async("if not exist \"%s\" mkdir \"%s\"" % [abs, abs])
		if ec != 0:
			log_error("Could not create %s (exit %s)." % [abs, str(ec)])
			all_ok = false
		else:
			log_line("Created (or already present): %s" % abs)
	return all_ok


func _archive_folder(p: Dictionary) -> bool:
	var source: String = p.get("source", "")
	var dest: String = p.get("destination", "")
	if source.is_empty() or dest.is_empty():
		log_error("archive_folder: missing 'source' or 'destination'.")
		return false
	var src_abs := ProjectSettings.globalize_path(source).trim_suffix("/").replace("/", "\\")
	var dst_abs := ProjectSettings.globalize_path(dest).trim_suffix("/").replace("/", "\\")
	log_line("Archiving %s → %s" % [src_abs, dst_abs])
	var ec := await _shell_async(
			"mkdir \"%s\" && xcopy \"%s\" \"%s\" /E /I /H /Y" % [dst_abs, src_abs, dst_abs])
	if ec != 0:
		log_error("Archive failed (exit %s)." % str(ec))
		return false
	return true


func _clear_user_data() -> bool:
	# The trailing separator globalize_path() returns must go, or it escapes its
	# own closing quote. The log file lives outside user://, so it survives this.
	var user_dir := ProjectSettings.globalize_path("user://").trim_suffix("/").replace("/", "\\")
	log_line("Clearing user data at %s" % user_dir)
	var ec := await _shell_async("if exist \"%s\" rmdir /s /q \"%s\"" % [user_dir, user_dir])
	if ec != 0:
		log_error("Failed to clear user data (exit %s)." % str(ec))
		return false
	return true


func _open_in_explorer(p: Dictionary) -> bool:
	var path: String = p.get("path", "")
	if path.is_empty():
		log_error("open_in_explorer: missing 'path'.")
		return false
	OS.shell_show_in_file_manager(ProjectSettings.globalize_path(path))
	return true


func _copy_to_clipboard(p: Dictionary) -> bool:
	var text: String = p.get("text", "")
	DisplayServer.clipboard_set(text)
	log_line("Copied: %s" % text)
	return true


func _reset_and_increment() -> bool:
	var current: String = ProjectSettings.get_setting("application/config/version", "0.1")
	var bumped := _increment_last_segment(current)
	if bumped.is_empty():
		log_error("Could not parse version '%s'." % current)
		return false
	ProjectSettings.set_setting("application/config/version", bumped)
	ProjectSettings.set_setting("application/config/commit_message", "")
	ProjectSettings.save()
	variables["VERSION"] = bumped
	variables["COMMIT_MESSAGE"] = ""
	variables["COMMIT_MESSAGE_SLUG"] = ""
	variables_changed.emit()
	log_line("Version: %s → %s" % [current, bumped])
	step_input_set.emit("version", bumped)
	step_input_set.emit("commit_message", "")
	_reset_all_tabs()
	tab_switch_requested.emit(0)
	return true


static func _increment_last_segment(version: String) -> String:
	# Digit-agnostic: 1.2.3.4 → 1.2.3.5, 0.1 → 0.2, 2.345 → 2.346, "5" → "6".
	var last_dot := version.rfind(".")
	if last_dot == -1:
		if version.is_valid_int():
			return str(int(version) + 1)
		return ""
	var prefix := version.substr(0, last_dot + 1)
	var tail := version.substr(last_dot + 1)
	if not tail.is_valid_int():
		return ""
	return prefix + str(int(tail) + 1)


func _reset_all_tabs() -> void:
	for sid in step_tab_index.keys():
		completed[sid] = false
		step_state_changed.emit(sid)


func find_step(id: String) -> SteamRollerStep:
	if config == null:
		return null
	for s in config.steps:
		if s != null and s.id == id:
			return s
	return null


func _run_steps(step: SteamRollerStep, overrides: Dictionary = {}) -> bool:
	var all_ok := true
	for sid in step.step_ids:
		var child := find_step(sid)
		if child == null:
			log_error("run_steps: unknown step id '%s'" % sid)
			all_ok = false
			continue
		# Overrides flow down so an aggregate can pin a mode for all its children.
		var child_ok := await execute_step(child, overrides)
		if child_ok and not child.id.is_empty():
			set_completed(child.id, true)
		if not child_ok:
			all_ok = false
	return all_ok


func _run_command(step: SteamRollerStep) -> bool:
	var exe := resolve(step.executable)
	var resolved_args := resolve_args(step.args)
	var wd := resolve(step.working_dir)

	log_line("Running: %s %s" % [exe, " ".join(resolved_args)])
	if not wd.is_empty():
		log_line("Working dir: %s" % wd)

	var ec := await _shell_async(_build_cmd_line(exe, resolved_args), wd)
	log_line("Exit code: %s" % str(ec))
	if step.require_zero_exit and ec != 0:
		log_error("'%s' failed (exit %s)." % [exe, str(ec)])
		return false
	return true


## Non-blocking variant of _run_command: spawns the process detached and polls
## for exit so long-running commands (benchmarks, tools) don't freeze the editor.
## Optional params["tail_file"] is read after exit and logged to the step console.
func _run_command_async(step: SteamRollerStep, p: Dictionary) -> bool:
	var exe := resolve(step.executable)
	var resolved_args := resolve_args(step.args)
	log_line("Running (async): %s %s" % [exe, " ".join(resolved_args)])
	var pid := OS.create_process(exe, resolved_args, true)
	if pid <= 0:
		log_error("run_command_async: failed to start '%s'." % exe)
		return false
	var tail_file: String = str(p.get("tail_file", ""))
	var offset := 0
	while OS.is_process_running(pid):
		await get_tree().create_timer(SHELL_POLL_INTERVAL).timeout
		if not tail_file.is_empty():
			offset = _drain_log(tail_file, offset, false)
	if not tail_file.is_empty():
		_drain_log(tail_file, offset, true)
	var ec := OS.get_process_exit_code(pid)
	log_line("Exit code: %s" % str(ec))
	if step.require_zero_exit and ec != 0:
		log_error("run_command_async: '%s' failed (exit %s)." % [exe, str(ec)])
		return false
	return true


static func _quote_args(args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for a in args:
		if a.contains(" ") and not a.begins_with("\""):
			out.append("\"%s\"" % a)
		else:
			out.append(a)
	return out


func _write_vdf_desc(p: Dictionary) -> bool:
	var files: Array = p.get("files", [])
	var desc: String = p.get("desc", "")
	var branch: String = p.get("branch", "")
	if files.is_empty():
		log_error("write_vdf_desc: missing 'files'.")
		return false
	if desc.is_empty():
		log_error("write_vdf_desc: missing 'desc'.")
		return false
	var desc_regex := RegEx.new()
	desc_regex.compile(r'"desc"\s+"[^"]*"')
	var setlive_regex := RegEx.new()
	setlive_regex.compile(r'"setlive"\s+"[^"]*"')
	var all_ok := true
	for raw_path in files:
		var path: String = ProjectSettings.globalize_path(str(raw_path))
		var fa := FileAccess.open(path, FileAccess.READ)
		if fa == null:
			log_error("write_vdf_desc: cannot open %s (error %s)" % [path, str(FileAccess.get_open_error())])
			all_ok = false
			continue
		var content: String = fa.get_as_text()
		fa.close()
		if desc_regex.search(content) == null:
			log_error("write_vdf_desc: 'desc' key not found in %s" % path)
			all_ok = false
			continue
		var replacement := '"desc"\t"%s"' % desc
		var updated: String = desc_regex.sub(content, replacement)
		if not branch.is_empty():
			if setlive_regex.search(updated) == null:
				log_error("write_vdf_desc: 'setlive' key not found in %s" % path)
				all_ok = false
				continue
			var setlive_replacement := '"setlive"\t"%s"' % branch
			updated = setlive_regex.sub(updated, setlive_replacement)
		var fw := FileAccess.open(path, FileAccess.WRITE)
		if fw == null:
			log_error("write_vdf_desc: cannot write %s (error %s)" % [path, str(FileAccess.get_open_error())])
			all_ok = false
			continue
		fw.store_string(updated)
		fw.close()
		if branch.is_empty():
			log_line("Updated desc in %s → \"%s\"" % [path, desc])
		else:
			log_line("Updated %s → desc \"%s\", setlive \"%s\"" % [path, desc, branch])
	return all_ok


## Export every preset headlessly, mirroring the editor's "Export All".
## params.debug picks --export-debug over --export-release; params.exports, when
## present, overrides the preset list read from export_presets.cfg.
func _export_project(p: Dictionary) -> bool:
	var exports: Array = p.get("exports", [])
	if exports.is_empty():
		exports = _presets_from_export_cfg()
	if exports.is_empty():
		log_error("export_project: no presets to export.")
		return false
	var debug: bool = bool(p.get("debug", false))
	var mode_flag := "--export-debug" if debug else "--export-release"
	var mode_name := "Debug" if debug else "Release"
	var godot_exe: String = OS.get_executable_path()
	# The trailing separator must go, or it escapes its own closing quote.
	var project_path: String = ProjectSettings.globalize_path("res://").trim_suffix("/")
	log_line("Export All (%s) — %d preset(s)." % [mode_name, exports.size()])
	var all_ok := true
	# Sequential by design: parallel headless exports of one project would
	# contend on the .godot import cache.
	for entry in exports:
		var preset: String = str(entry.get("preset", ""))
		var raw_output: String = str(entry.get("output", ""))
		if preset.is_empty() or raw_output.is_empty():
			log_error("export_project: each entry needs 'preset' and 'output'.")
			all_ok = false
			continue
		var output := _resolve_export_output(raw_output)
		# The export window creates missing folders; the CLI does not.
		var out_dir := output.get_base_dir()
		if not out_dir.is_empty() and not DirAccess.dir_exists_absolute(out_dir):
			var mk := DirAccess.make_dir_recursive_absolute(out_dir)
			if mk != OK:
				log_error("export_project: cannot create %s (error %s)." % [out_dir, str(mk)])
				all_ok = false
				continue
		log_line("Exporting '%s' (%s) → %s" % [preset, mode_name.to_lower(), output])
		var args := PackedStringArray([
			"--headless", "--path", project_path, mode_flag, preset, output
		])
		# quiet: the headless export is thousands of "Storing File" lines. The log
		# file keeps them all; only a failure gets echoed to the console.
		var exit_code := await _shell_async(_build_cmd_line(godot_exe, args), "", true)
		log_line("Preset '%s' exit code: %s" % [preset, str(exit_code)])
		if exit_code != 0:
			log_error("export_project: preset '%s' (%s) failed (exit %s)."
					% [preset, mode_name.to_lower(), str(exit_code)])
			all_ok = false
	log_line("Export All (%s) %s." % [mode_name, "complete" if all_ok else "FAILED"])
	return all_ok


## Every preset in export_presets.cfg paired with its own export_path - the same
## list, in the same order, that the editor's "Export All" button walks.
func _presets_from_export_cfg() -> Array:
	var out: Array = []
	var cfg := ConfigFile.new()
	var err := cfg.load("res://export_presets.cfg")
	if err != OK:
		log_error("export_project: cannot read res://export_presets.cfg (error %s)." % str(err))
		return out
	for section in cfg.get_sections():
		# Each preset owns two sections: "preset.N" and "preset.N.options".
		if not section.begins_with("preset.") or section.ends_with(".options"):
			continue
		var preset_name := str(cfg.get_value(section, "name", ""))
		var export_path := str(cfg.get_value(section, "export_path", ""))
		if preset_name.is_empty():
			continue
		if export_path.is_empty():
			log_error("export_project: preset '%s' has no export path — skipped." % preset_name)
			continue
		out.append({"preset": preset_name, "output": export_path})
	return out


## export_presets.cfg stores paths relative to the project root, so
## globalize_path() alone is wrong for them.
func _resolve_export_output(raw: String) -> String:
	if raw.begins_with("res://") or raw.begins_with("user://"):
		return ProjectSettings.globalize_path(raw)
	if raw.is_absolute_path():
		return raw
	return (ProjectSettings.globalize_path("res://") + raw).simplify_path()
