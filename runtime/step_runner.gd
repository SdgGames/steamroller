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

const TOKEN_REGEX := r"\$\{([A-Z_][A-Z0-9_]*)\}"

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

var _active_step_id: String = ""
var _active_is_optional: bool = false
var _token_regex: RegEx = null


func _ready() -> void:
	_token_regex = RegEx.new()
	_token_regex.compile(TOKEN_REGEX)


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
	variables["COMMIT_MESSAGE_SLUG"] = _raw_commit.replace(" ", "_")
	variables["STEAM_BRANCH"] = str(ProjectSettings.get_setting("application/steamroller/steam_branch", ""))
	variables["DEMO_MODE"] = "true" if _get_demo_mode() else "false"
	variables["USER_DIR"] = ProjectSettings.globalize_path("user://")
	variables["PROJECT_DIR"] = ProjectSettings.globalize_path("res://")
	variables["PLATFORM"] = OS.get_name()
	variables_changed.emit()


func _get_demo_mode() -> bool:
	const SETTING := "application/steamroller/demo_mode"
	if ProjectSettings.has_setting(SETTING):
		return bool(ProjectSettings.get_setting(SETTING))
	return false


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
# Verbose output always goes to the Godot Output panel via print/push_error.
# The inline per-step console stays compact: only errors are surfaced there
# so the user gets a quick signal without having to watch the full log.

func log_line(line: String) -> void:
	print("[SteamRoller] " + line)


## Use this from tool implementations when reporting failure conditions.
## Always surfaces in the Godot Output panel AND in the inline step console
## so the user sees the failure even if they are not watching the full log.
func log_error(line: String) -> void:
	push_error("[SteamRoller] " + line)
	if not _active_is_optional and not _active_step_id.is_empty():
		log_line_emitted.emit(_active_step_id, "[err] " + line)


# --- Execution dispatch ----------------------------------------------------

func execute_step(step: SteamRollerStep) -> bool:
	_active_step_id = step.id
	_active_is_optional = step.is_optional
	rebuild_variables()
	var resolved := resolve_params(step.params)
	var ok := false
	match step.action:
		SteamRollerStep.Action.RUN_GDUNIT:
			ok = await _run_gdunit_tests()
		SteamRollerStep.Action.RECORD_MOVIE:
			ok = await _record_movie(resolved)
		SteamRollerStep.Action.DELETE_FOLDER:
			ok = _delete_folder(resolved)
		SteamRollerStep.Action.CREATE_FOLDERS:
			ok = _create_folders(resolved)
		SteamRollerStep.Action.ARCHIVE_FOLDER:
			ok = _archive_folder(resolved)
		SteamRollerStep.Action.CLEAR_USER_DATA:
			ok = _clear_user_data()
		SteamRollerStep.Action.OPEN_IN_EXPLORER:
			ok = _open_in_explorer(resolved)
		SteamRollerStep.Action.COPY_TO_CLIPBOARD:
			ok = _copy_to_clipboard(resolved)
		SteamRollerStep.Action.RESET_AND_INCREMENT:
			ok = _reset_and_increment()
		SteamRollerStep.Action.RUN_COMMAND:
			ok = await _run_command(step)
		SteamRollerStep.Action.RUN_STEPS:
			ok = await _run_steps(step)
		SteamRollerStep.Action.WRITE_VDF_DESC:
			ok = _write_vdf_desc(resolved)
		SteamRollerStep.Action.EXPORT_PROJECT:
			ok = await _export_project(resolved)
		_:
			log_error("Step has no executable action: %s" % str(step.action))
	_active_step_id = ""
	_active_is_optional = false
	return ok


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
	var out: Array = []
	OS.execute("cmd", ["/c", "del", "/f", abs_avi], out, true)
	log_line("Re-encode complete.")
	return true


func _delete_folder(p: Dictionary) -> bool:
	var path: String = p.get("path", "")
	if path.is_empty():
		log_error("delete_folder: missing 'path'.")
		return false
	var abs := ProjectSettings.globalize_path(path).replace("/", "\\")
	log_line("Deleting %s" % abs)
	var out: Array = []
	var ec := OS.execute("cmd", ["/c", "if exist \"%s\" rmdir /s /q \"%s\"" % [abs, abs]], out, true)
	if ec != 0:
		log_error("Delete failed: %s" % str(out))
		return false
	var paths: Array = p.get("paths", [])
	if not paths.is_empty():
		return _create_folders({"paths": paths})
	return true


func _create_folders(p: Dictionary) -> bool:
	var paths: Array = p.get("paths", [])
	if paths.is_empty():
		log_error("create_folders: missing 'paths'.")
		return false
	var all_ok := true
	for path in paths:
		var abs := ProjectSettings.globalize_path(str(path)).replace("/", "\\")
		var out: Array = []
		var ec := OS.execute("cmd", ["/c", "if not exist \"%s\" mkdir \"%s\"" % [abs, abs]], out, true)
		if ec != 0:
			log_error("Could not create %s: %s" % [abs, str(out)])
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
	var src_abs := ProjectSettings.globalize_path(source).replace("/", "\\")
	var dst_abs := ProjectSettings.globalize_path(dest).replace("/", "\\")
	log_line("Archiving %s → %s" % [src_abs, dst_abs])
	var out: Array = []
	var ec := OS.execute("cmd", [
		"/c",
		"mkdir \"%s\" && xcopy \"%s\" \"%s\" /E /I /H /Y" % [dst_abs, src_abs, dst_abs]
	], out, true)
	if ec != 0:
		log_error("Archive failed: %s" % str(out))
		return false
	return true


func _clear_user_data() -> bool:
	var user_dir := ProjectSettings.globalize_path("user://").replace("/", "\\")
	log_line("Clearing user data at %s" % user_dir)
	var out: Array = []
	var ec := OS.execute("cmd", [
		"/c", "if exist \"%s\" rmdir /s /q \"%s\"" % [user_dir, user_dir]
	], out, true)
	if ec != 0:
		log_error("Failed: %s" % str(out))
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


func _run_steps(step: SteamRollerStep) -> bool:
	var all_ok := true
	for sid in step.step_ids:
		var child := find_step(sid)
		if child == null:
			log_error("run_steps: unknown step id '%s'" % sid)
			all_ok = false
			continue
		var child_ok := await execute_step(child)
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

	var quoted_args := _quote_args(resolved_args)
	var full_cmd: String
	if wd.is_empty():
		full_cmd = "\"%s\" %s" % [exe, " ".join(quoted_args)]
	else:
		full_cmd = "cd /d \"%s\" && \"%s\" %s" % [wd, exe, " ".join(quoted_args)]

	var output: Array = []
	var ec := OS.execute("cmd", ["/c", full_cmd], output, true)
	for line in output:
		for sub in str(line).split("\n"):
			if not sub.strip_edges().is_empty():
				log_line(sub)
	log_line("Exit code: %s" % str(ec))
	if step.require_zero_exit and ec != 0:
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


func _export_project(p: Dictionary) -> bool:
	var exports: Array = p.get("exports", [])
	if exports.is_empty():
		log_error("export_project: missing 'exports'.")
		return false
	var godot_exe: String = OS.get_executable_path()
	var project_path: String = ProjectSettings.globalize_path("res://")
	var all_ok := true
	for entry in exports:
		var preset: String = str(entry.get("preset", ""))
		var output: String = ProjectSettings.globalize_path(str(entry.get("output", "")))
		if preset.is_empty() or output.is_empty():
			log_error("export_project: each entry needs 'preset' and 'output'.")
			all_ok = false
			continue
		log_line("Exporting preset '%s' → %s" % [preset, output])
		var pid := OS.create_process(godot_exe, [
			"--headless", "--path", project_path,
			"--export-release", preset, output
		], true)
		if pid <= 0:
			log_error("export_project: failed to start process for preset '%s'." % preset)
			all_ok = false
			continue
		while OS.is_process_running(pid):
			await get_tree().create_timer(1.0).timeout
		var exit_code := OS.get_process_exit_code(pid)
		log_line("Preset '%s' exit code: %s" % [preset, str(exit_code)])
		if exit_code != 0:
			log_error("export_project: preset '%s' failed (exit %s)." % [preset, str(exit_code)])
			all_ok = false
	return all_ok
