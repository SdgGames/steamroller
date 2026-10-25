@tool
class_name SteamRollerActions extends RefCounted
## What each SteamRollerStep.Action does. run() is the one entry point; the
## runner calls it with the step's resolved params and the pressed button's
## overrides. Every action logs through the runner, so its output lands in the
## console of the row that was pressed.
##
## Folder deletion and archiving use cmd.exe (rmdir, xcopy): Windows only, like
## the shell itself.

var _runner: SteamRollerStepRunner
var _shell: SteamRollerShell
var _render: SteamRollerRenderQueue
## A step started the editor's own play session (Record gameplay, the unit
## tests), so Stop may end it. A session the user started is never stopped.
var owns_play := false


func _init(runner: SteamRollerStepRunner, shell: SteamRollerShell) -> void:
	_runner = runner
	_shell = shell
	_render = SteamRollerRenderQueue.new(runner, shell)


func run(step: SteamRollerStep, p: Dictionary, overrides: Dictionary) -> bool:
	match step.action:
		SteamRollerStep.Action.CHECKBOX, SteamRollerStep.Action.NEW_TAB, \
				SteamRollerStep.Action.INPUT:
			return true
		SteamRollerStep.Action.RUN_GDUNIT:
			return await _run_gdunit()
		SteamRollerStep.Action.RECORD_MOVIE:
			return await _record_movie(p)
		SteamRollerStep.Action.DELETE_FOLDER:
			return await _delete_folder(p)
		SteamRollerStep.Action.CREATE_FOLDERS:
			return _create_folders(p)
		SteamRollerStep.Action.ARCHIVE_FOLDER:
			return await _archive_folder(p)
		SteamRollerStep.Action.CLEAR_USER_DATA:
			return await _clear_user_data()
		SteamRollerStep.Action.OPEN_IN_EXPLORER:
			return _open_folder(p)
		SteamRollerStep.Action.COPY_TO_CLIPBOARD:
			return _copy_to_clipboard(p)
		SteamRollerStep.Action.RESET_AND_INCREMENT:
			return _reset_and_increment()
		SteamRollerStep.Action.RUN_COMMAND, SteamRollerStep.Action.RUN_COMMAND_ASYNC:
			return await _run_command(step)
		SteamRollerStep.Action.RUN_STEPS:
			return await _run_steps(step, overrides)
		SteamRollerStep.Action.WRITE_VDF_DESC:
			return _write_vdf_desc(p)
		SteamRollerStep.Action.EXPORT_PROJECT:
			return await _export_project(p)
		SteamRollerStep.Action.RENDER_QUEUE:
			return await _render.run(step, p)
	_runner.log_error("Step '%s' has no action to run." % step.id)
	return false


## True when a script class (or a native class) of this name exists.
static func class_registered(target: String) -> bool:
	return ClassDB.class_exists(target) or _script_class(target) != null


# --- GdUnit4 -------------------------------------------------------------------

func _run_gdunit() -> bool:
	var handler_script := _script_class("GdUnitCommandHandler")
	var command_script := _script_class("GdUnitCommandRunTestsOverall")
	if handler_script == null or command_script == null:
		_runner.log_error("GdUnit4 is not installed (GdUnitCommandHandler not found).")
		return false
	var since := Time.get_unix_time_from_system()
	# GdUnit is loaded by name so this plugin does not depend on it.
	var handler: Object = handler_script.call("instance")
	owns_play = true
	await handler.call("command_execute", command_script.get_script_constant_map().get("ID"))
	while EditorInterface.is_playing_scene():
		await _runner.get_tree().create_timer(0.5).timeout
	owns_play = false
	if _runner.stop_requested():
		return false
	return _gdunit_result(since)


## Read the JUnit report the run wrote under res://reports. When there is none,
## the result cannot be known here: the step passes and says so.
func _gdunit_result(since: float) -> bool:
	var root := ProjectSettings.globalize_path("res://reports")
	var newest := ""
	var newest_t := since - 5.0
	for d in DirAccess.get_directories_at(root):
		var xml := root.path_join(d).path_join("results.xml")
		if FileAccess.file_exists(xml) and FileAccess.get_modified_time(xml) >= newest_t:
			newest_t = FileAccess.get_modified_time(xml)
			newest = xml
	if newest.is_empty():
		_runner.log_line("No GdUnit report from this run: see the GdUnit panel for the result.")
		return true
	var head := FileAccess.get_file_as_string(newest).substr(0, 4096)
	var suites := RegEx.create_from_string("<testsuites\\b[^>]*>").search(head)
	if suites == null:
		_runner.log_line("Could not read %s: see the GdUnit panel for the result." % newest)
		return true
	var tag := suites.get_string()
	var tests := _xml_count(tag, "tests")
	var failed := _xml_count(tag, "failures") + _xml_count(tag, "errors")
	if failed > 0:
		_runner.log_error("GdUnit: %d of %d test(s) failed (%s)." % [failed, tests, newest])
		return false
	_runner.log_line("GdUnit: %d test(s), all passed." % tests)
	return true


static func _xml_count(tag: String, attribute: String) -> int:
	var m := RegEx.create_from_string("\\b%s=\"(\\d+)\"" % attribute).search(tag)
	return m.get_string(1).to_int() if m != null else 0


# --- Movie Maker ---------------------------------------------------------------

func _record_movie(p: Dictionary) -> bool:
	var output := _abs(str(p.get("output_path", "")))
	if output.is_empty():
		_runner.log_error("Record gameplay needs params.output_path.")
		return false
	if SteamRollerSettings.text(SteamRollerSettings.MAIN_SCENE).is_empty():
		_runner.log_error("The project has no main scene to record.")
		return false
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	if FileAccess.file_exists(output):
		DirAccess.remove_absolute(output)   # an older film must not pass for this one
	var previous: Variant = ProjectSettings.get_setting(SteamRollerSettings.MOVIE_FILE, "")
	ProjectSettings.set_setting(SteamRollerSettings.MOVIE_FILE, output)
	EditorInterface.movie_maker_enabled = true
	owns_play = true
	EditorInterface.play_main_scene()
	_runner.log_line("Recording the main scene to %s" % output)
	await _runner.get_tree().create_timer(0.5).timeout
	# The editor handed the game the path when it launched it. Put the setting
	# back, so no later save writes this machine's path into project.godot.
	ProjectSettings.set_setting(SteamRollerSettings.MOVIE_FILE, previous)
	while EditorInterface.is_playing_scene():
		await _runner.get_tree().create_timer(0.5).timeout
	owns_play = false
	EditorInterface.movie_maker_enabled = false
	if _runner.stop_requested():
		return false
	if not FileAccess.file_exists(output):
		_runner.log_error("Movie Maker wrote no file at %s." % output)
		return false
	if p.get("reencode", false) == true:
		return await _reencode(output, p)
	return true


## The film as an H.264 mp4 beside it (params crf, preset, suffix); the film
## itself is deleted once the mp4 is written.
func _reencode(movie: String, p: Dictionary) -> bool:
	var mp4 := movie.get_basename() + str(p.get("suffix", "_sample.mp4"))
	_runner.log_line("Re-encoding with ffmpeg: %s" % mp4)
	# -loglevel error keeps the console to the progress line and real errors
	# (it also hides FFmpeg #11628's false keyframe warnings on an OGV film).
	var args := PackedStringArray(["-hide_banner", "-loglevel", "error", "-stats", "-y",
		"-i", movie, "-vf", "scale=-2:1080", "-c:v", "libx264",
		"-crf", str(p.get("crf", 23)), "-preset", str(p.get("preset", "medium")),
		"-c:a", "aac", "-b:a", "128k", mp4])
	var code := await _shell.run(SteamRollerShell.command_line("ffmpeg", args))
	if code != 0:
		_runner.log_error("ffmpeg failed (exit %d); is it on PATH? The film is kept at %s." % [
			code, movie])
		return false
	DirAccess.remove_absolute(movie)
	_runner.log_line("Wrote %s." % mp4)
	return true


# --- Folders -------------------------------------------------------------------

func _delete_folder(p: Dictionary) -> bool:
	var path := _abs(str(p.get("path", ""))).trim_suffix("/")
	if path.is_empty():
		_runner.log_error("Delete folder needs params.path.")
		return false
	if not _deletable(path):
		_runner.log_error("Refusing to delete %s: a drive, a top-level folder, the home folder or the project itself." % path)
		return false
	if DirAccess.dir_exists_absolute(path):
		_runner.log_line("Deleting %s" % path)
		var code := await _shell.run("rmdir /s /q %s" % SteamRollerShell.quote(_win(path)))
		if code != 0 or DirAccess.dir_exists_absolute(path):
			_runner.log_error("Could not delete %s (exit %d): is a file in it open?" % [path, code])
			return false
	var paths: Array = p.get("paths", [])
	if not paths.is_empty():
		return _create_folders({"paths": paths})
	return true


func _create_folders(p: Dictionary) -> bool:
	var paths: Array = p.get("paths", [])
	if paths.is_empty():
		_runner.log_error("Create folders needs params.paths.")
		return false
	var all_ok := true
	for raw: Variant in paths:
		var path := _abs(str(raw))
		var err := DirAccess.make_dir_recursive_absolute(path)
		if err != OK:
			_runner.log_error("Could not create %s (error %d)." % [path, err])
			all_ok = false
		else:
			_runner.log_line("Folder ready: %s" % path)
	return all_ok


## Copy `source` into `destination`, newer files only, so archiving twice is
## safe and only copies what changed.
func _archive_folder(p: Dictionary) -> bool:
	var source := _abs(str(p.get("source", ""))).trim_suffix("/")
	var dest := _abs(str(p.get("destination", ""))).trim_suffix("/")
	if source.is_empty() or dest.is_empty():
		_runner.log_error("Archive needs params.source and params.destination.")
		return false
	if not DirAccess.dir_exists_absolute(source):
		_runner.log_error("Nothing to archive at %s." % source)
		return false
	_runner.log_line("Archiving %s → %s" % [source, dest])
	var code := await _shell.run("xcopy %s %s /E /I /H /Y /D /Q" % [
		SteamRollerShell.quote(_win(source)), SteamRollerShell.quote(_win(dest))])
	# xcopy: 0 copied, 1 nothing to copy; anything else is an error.
	if code != 0 and code != 1:
		_runner.log_error("Archive failed (xcopy exit %d)." % code)
		return false
	return true


func _clear_user_data() -> bool:
	var dir := ProjectSettings.globalize_path("user://").replace("\\", "/").trim_suffix("/")
	if not _deletable(dir):
		_runner.log_error("Refusing to clear %s." % dir)
		return false
	_runner.log_line("Clearing %s" % dir)
	var code := await _shell.run("rmdir /s /q %s" % SteamRollerShell.quote(_win(dir)))
	DirAccess.make_dir_recursive_absolute(dir)
	if code != 0:
		_runner.log_error("Could not clear every file (exit %d): is the game running?" % code)
		return false
	_runner.log_line("Cleared.")
	return true


func _open_folder(p: Dictionary) -> bool:
	var path := _abs(str(p.get("path", "")))
	if path.is_empty():
		_runner.log_error("Open folder needs params.path.")
		return false
	if p.get("create", false) == true:
		DirAccess.make_dir_recursive_absolute(path)
	if not DirAccess.dir_exists_absolute(path) and not FileAccess.file_exists(path):
		_runner.log_error("Nothing at %s yet." % path)
		return false
	var err := OS.shell_show_in_file_manager(path, true)
	if err != OK:
		_runner.log_error("Could not open %s (error %d)." % [path, err])
		return false
	return true


# --- Text and version ----------------------------------------------------------

func _copy_to_clipboard(p: Dictionary) -> bool:
	var text := str(p.get("text", ""))
	if text.strip_edges().is_empty():
		_runner.log_error("Nothing to copy: params.text is empty.")
		return false
	DisplayServer.clipboard_set(text)
	_runner.log_line("Copied: %s" % text)
	return true


func _reset_and_increment() -> bool:
	var current := SteamRollerSettings.text(SteamRollerSettings.VERSION)
	var bumped := SteamRollerVariables.bump_version(current)
	if bumped.is_empty():
		_runner.log_error("Cannot increment the version '%s': its last part is not a number." % current)
		return false
	SteamRollerSettings.put(SteamRollerSettings.VERSION, bumped)
	SteamRollerSettings.put(SteamRollerSettings.COMMIT_MESSAGE, "")
	if not SteamRollerSettings.save():
		return false
	_runner.reset_checklist()
	_runner.log_line("Version %s → %s" % [current, bumped])
	return true


## Set the Steam build description, and the branch it goes live on, in each VDF.
func _write_vdf_desc(p: Dictionary) -> bool:
	var files: Array = p.get("files", [])
	var desc := str(p.get("desc", ""))
	var branch := str(p.get("branch", ""))
	if files.is_empty() or desc.is_empty():
		_runner.log_error("Write VDF description needs params.files and params.desc.")
		return false
	var all_ok := true
	for raw: Variant in files:
		var path := _abs(str(raw))
		if not FileAccess.file_exists(path):
			_runner.log_error("No VDF at %s." % path)
			all_ok = false
			continue
		var updated := _vdf_set(FileAccess.get_file_as_string(path), "desc", desc)
		if not updated.is_empty() and not branch.is_empty():
			updated = _vdf_set(updated, "setlive", branch)
		if updated.is_empty():
			_runner.log_error("%s has no \"desc\"%s key." % [path,
				"" if branch.is_empty() else " or \"setlive\""])
			all_ok = false
			continue
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			_runner.log_error("Cannot write %s (error %d)." % [path, FileAccess.get_open_error()])
			all_ok = false
			continue
		f.store_string(updated)
		f.close()
		_runner.log_line("%s: desc \"%s\"%s" % [path.get_file(), desc,
			"" if branch.is_empty() else ", setlive \"%s\"" % branch])
	return all_ok


## `content` with the value of its `"key" "..."` pair replaced by `value`,
## escaped for VDF; "" when the key is missing.
static func _vdf_set(content: String, key: String, value: String) -> String:
	var m := RegEx.create_from_string("\"%s\"\\s+\"(?:[^\"\\\\]|\\\\.)*\"" % key).search(content)
	if m == null:
		return ""
	var escaped := value.replace("\\", "\\\\").replace("\"", "\\\"")
	return content.substr(0, m.get_start()) + "\"%s\"\t\"%s\"" % [key, escaped] \
		+ content.substr(m.get_end())


# --- Commands ------------------------------------------------------------------

func _run_command(step: SteamRollerStep) -> bool:
	var exe := _runner.vars.resolve(step.executable)
	if exe.is_empty():
		_runner.log_error("Step '%s' has no executable." % step.id)
		return false
	var args := _runner.vars.resolve_args(step.args)
	var wd := _runner.vars.resolve(step.working_dir)
	var line := SteamRollerShell.command_line(exe, args)
	_runner.log_line("Running: %s" % line)
	if not wd.is_empty():
		_runner.log_line("In: %s" % wd)
	var code := await _shell.run(line, wd)
	if _runner.stop_requested():
		return false
	_runner.log_line("Exit code: %d" % code)
	if code == SteamRollerShell.NOT_STARTED or (step.require_zero_exit and code != 0):
		_runner.log_error("'%s' failed (exit %d)." % [exe.get_file(), code])
		return false
	return true


## Run each of `step_ids` in order. One that is not yet enabled is skipped (an
## aggregate never runs ahead of its children's gates); each that runs is
## ticked or unticked by its result.
func _run_steps(step: SteamRollerStep, overrides: Dictionary) -> bool:
	var all_ok := true
	for sid in step.step_ids:
		if _runner.stop_requested():
			return false
		var child := _runner.find_step(sid)
		if child == null:
			_runner.log_error("Run steps: no step '%s'." % sid)
			all_ok = false
			continue
		var why := _runner.blocked_reason(child)
		if not why.is_empty():
			_runner.log_line("Skipped %s: %s" % [_runner.step_label(child), why])
			all_ok = false
			continue
		var ok: bool = await _runner.execute_step(child, overrides)
		if child.marks_completion():
			_runner.set_completed(child.id, ok)
		all_ok = all_ok and ok
	return all_ok


# --- Export --------------------------------------------------------------------

## Export every preset headlessly, like the editor's Export All. params.debug
## picks the mode; params.exports, when given, replaces the preset list.
func _export_project(p: Dictionary) -> bool:
	var exports: Array = p.get("exports", [])
	if exports.is_empty():
		exports = _presets_from_export_cfg()
	if exports.is_empty():
		_runner.log_error("Export: no presets to export.")
		return false
	var debug: bool = p.get("debug", false) == true
	var mode := "debug" if debug else "release"
	# The trailing separator would escape its own closing quote.
	var project := ProjectSettings.globalize_path("res://").trim_suffix("/")
	_runner.log_line("Export All (%s): %d preset(s)." % [mode, exports.size()])
	var all_ok := true
	# One at a time: parallel headless exports of one project contend on the
	# import cache.
	for entry: Variant in exports:
		if _runner.stop_requested():
			return false
		var d: Dictionary = entry if entry is Dictionary else {}
		var preset := str(d.get("preset", ""))
		var raw_output := str(d.get("output", ""))
		if preset.is_empty() or raw_output.is_empty():
			_runner.log_error("Export: each entry needs a preset and an output.")
			all_ok = false
			continue
		var output := _export_output(raw_output)
		# The export window creates missing folders; the command line does not.
		DirAccess.make_dir_recursive_absolute(output.get_base_dir())
		_runner.log_line("Exporting '%s' → %s" % [preset, output])
		var args := PackedStringArray(["--headless", "--path", project,
			"--export-" + mode, preset, output])
		# Quiet: an export prints thousands of "Storing File" lines. The log keeps
		# them; only a failure is echoed.
		var code := await _shell.run(SteamRollerShell.command_line(OS.get_executable_path(), args),
			"", true)
		if code != 0:
			_runner.log_error("Export of '%s' (%s) failed (exit %d)." % [preset, mode, code])
			all_ok = false
	_runner.log_line("Export All (%s) %s." % [mode, "done" if all_ok else "FAILED"])
	return all_ok


## Every preset in export_presets.cfg with its own export path: the list the
## editor's Export All walks, in its order.
func _presets_from_export_cfg() -> Array:
	var out: Array = []
	var cfg := ConfigFile.new()
	var err := cfg.load("res://export_presets.cfg")
	if err != OK:
		_runner.log_error("Export: cannot read res://export_presets.cfg (error %d)." % err)
		return out
	for section in cfg.get_sections():
		# Each preset owns "preset.N" and "preset.N.options".
		if not section.begins_with("preset.") or section.ends_with(".options"):
			continue
		var preset := str(cfg.get_value(section, "name", ""))
		var path := str(cfg.get_value(section, "export_path", ""))
		if preset.is_empty():
			continue
		if path.is_empty():
			_runner.log_error("Export: preset '%s' has no export path; skipped." % preset)
			continue
		out.append({"preset": preset, "output": path})
	return out


## export_presets.cfg stores paths relative to the project folder.
static func _export_output(raw: String) -> String:
	if raw.begins_with("res://") or raw.begins_with("user://"):
		return ProjectSettings.globalize_path(raw)
	if raw.is_absolute_path():
		return raw
	return (ProjectSettings.globalize_path("res://") + raw).simplify_path()


# --- Helpers -------------------------------------------------------------------

## A path as an absolute OS path with forward slashes ("" stays "").
static func _abs(path: String) -> String:
	if path.is_empty():
		return ""
	return ProjectSettings.globalize_path(path).replace("\\", "/").simplify_path()


## Backslashes, for cmd.exe built-ins.
static func _win(path: String) -> String:
	return path.replace("/", "\\")


## Whether a folder may be deleted outright: never a drive or a top-level
## folder, the home folder, or the project or a folder that holds it. A guard
## against a variable that resolved to something unexpected.
static func _deletable(path: String) -> bool:
	var p := path.replace("\\", "/").trim_suffix("/").simplify_path().to_lower()
	if p.split("/", false).size() < 3:
		return false
	var project := ProjectSettings.globalize_path("res://").replace("\\", "/") \
		.trim_suffix("/").simplify_path().to_lower()
	if project == p or project.begins_with(p + "/"):
		return false
	for env: String in ["USERPROFILE", "HOME"]:
		var home := OS.get_environment(env).replace("\\", "/").trim_suffix("/").to_lower()
		if not home.is_empty() and home == p:
			return false
	return true


static func _script_class(target: String) -> GDScript:
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == target:
			var path := str(entry.get("path", ""))
			if not path.is_empty():
				return load(path) as GDScript
	return null
