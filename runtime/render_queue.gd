@tool
class_name SteamRollerRenderQueue extends RefCounted
## RENDER_QUEUE: every selected input through every ticked job, one after the
## other, each job's passes in order through the shell.
##
## A job's project settings (the step's render_settings and the job's own) are
## written to the project's override.cfg for the duration of the job, so the
## game a pass launches reads them and project.godot never changes. The file
## carries a mark; one without it is the project's own and is never touched:
## a batch refuses to start while it exists. An override.cfg left behind by a
## batch that never finished is removed when the plugin next loads.

## The mark in an override.cfg written here (structural: what the stale-file
## sweep looks for). The game reads it as a harmless extra setting.
const MARK_SECTION := "steamroller"
const MARK_KEY := "written_by"
const MARK_VALUE := "render_queue"
## How deep below a source folder inputs are looked for: a scan of a big build
## folder stays quick.
const SCAN_DEPTH := 5

var _runner: SteamRollerStepRunner
var _shell: SteamRollerShell


func _init(runner: SteamRollerStepRunner, shell: SteamRollerShell) -> void:
	_runner = runner
	_shell = shell


## A source folder the row offers: { "path", "label", "modified" }.
## Each scan root's subfolders that hold inputs, newest first; then the root
## itself when it holds inputs directly.
static func list_sources(step: SteamRollerStep, vars: SteamRollerVariables) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var skip := _skipped_dirs(step, vars)
	for raw in step.render_scan_dirs:
		var root := _clean(vars.resolve(raw))
		if root.is_empty() or not DirAccess.dir_exists_absolute(root):
			continue
		for sub in DirAccess.get_directories_at(root):
			var path := root.path_join(sub)
			if sub.begins_with(".") or skip.has(path.to_lower()):
				continue
			var found: Array[String] = []
			_find(path, step.render_pattern, SCAN_DEPTH, skip, found, true)
			if not found.is_empty():
				out.append({"path": path, "label": sub, "modified": _newest_time(path)})
		var direct: Array[String] = []
		_find(root, step.render_pattern, 1, skip, direct, true)
		if not direct.is_empty():
			out.append({"path": root, "label": root.get_file() + " (top)",
				"modified": _newest_time(root)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["modified"]) > float(b["modified"]))
	return out


## The inputs under one source folder: { "path", "label", "is_dir", "bytes",
## "modified", "count" }. With render_include_folders, each folder that holds
## inputs comes first as one input (all of them), newest first, then each file.
static func list_inputs(step: SteamRollerStep, vars: SteamRollerVariables,
		source: String) -> Array[Dictionary]:
	var files: Array[String] = []
	_find(source, step.render_pattern, SCAN_DEPTH, _skipped_dirs(step, vars), files, false)
	var by_dir: Dictionary[String, Array] = {}
	var out: Array[Dictionary] = []
	for f in files:
		var dir := f.get_base_dir()
		if not by_dir.has(dir):
			by_dir[dir] = []
		by_dir[dir].append(f)
		out.append({"path": f, "label": "%s · %s" % [f.get_base_dir().get_file(), f.get_file()],
			"is_dir": false, "bytes": FileAccess.get_size(f),
			"modified": FileAccess.get_modified_time(f), "count": 1})
	out.sort_custom(_newest_first)
	if not step.render_include_folders:
		return out
	var dirs: Array[Dictionary] = []
	for dir: String in by_dir:
		var bytes := 0
		var newest := 0
		for f: String in by_dir[dir]:
			bytes += FileAccess.get_size(f)
			newest = maxi(newest, FileAccess.get_modified_time(f))
		var n := by_dir[dir].size()
		dirs.append({"path": dir, "label": "%s/ (all %d)" % [dir.get_file(), n], "is_dir": true,
			"bytes": bytes, "modified": newest, "count": n})
	dirs.sort_custom(_newest_first)
	dirs.append_array(out)
	return dirs


## An input's name for its outputs: a file as <parent>_<name without
## extension>, a folder as its name.
static func input_name(path: String) -> String:
	var p := path.trim_suffix("/")
	if DirAccess.dir_exists_absolute(p):
		return p.get_file()
	return "%s_%s" % [p.get_base_dir().get_file(), p.get_file().get_basename()]


static func override_path() -> String:
	return ProjectSettings.globalize_path("res://override.cfg")


## Remove an override.cfg a batch left behind (the editor closed mid-job).
static func remove_stale_override() -> void:
	if _override_is_ours():
		DirAccess.remove_absolute(override_path())
		print("[SteamRoller] Removed the override.cfg an unfinished render left behind.")


## Run the batch. params: inputs (paths), jobs (ids), and optionally out_dir,
## work_dir (override the step's) and keep_work (keep every scratch folder).
func run(step: SteamRollerStep, p: Dictionary) -> bool:
	var inputs: Array = p.get("inputs", [])
	var wanted: Array = p.get("jobs", [])
	var jobs: Array[SteamRollerRenderJob] = []
	for job in step.render_jobs:
		if job != null and wanted.has(job.id):
			jobs.append(job)
	if inputs.is_empty() or jobs.is_empty():
		_runner.log_error("Select at least one input and tick at least one render.")
		return false
	var out_dir := _clean(str(p.get("out_dir", _runner.vars.resolve(step.render_out_dir))))
	if out_dir.is_empty():
		_runner.log_error("The step has no render_out_dir.")
		return false
	var work_root := _clean(str(p.get("work_dir", _runner.vars.resolve(step.render_work_dir))))
	if work_root.is_empty():
		work_root = OS.get_cache_dir().path_join("steamroller_render").path_join(
			SteamRollerSettings.text(SteamRollerSettings.APP_NAME).validate_filename())
	if FileAccess.file_exists(override_path()) and not _override_is_ours():
		_runner.log_error("%s exists and is not SteamRoller's: move it aside to render." % override_path())
		return false
	DirAccess.make_dir_recursive_absolute(out_dir)
	var keep_work: bool = p.get("keep_work", false) == true
	var total := inputs.size() * jobs.size()
	var n := 0
	var failed := PackedStringArray()
	var started := Time.get_ticks_msec()
	_runner.log_line("%d render(s) into %s" % [total, out_dir])
	for raw: Variant in inputs:
		if _runner.stop_requested():
			break
		var input := _clean(str(raw))
		for job in jobs:
			if _runner.stop_requested():
				break
			n += 1
			_runner.log_line("[%d/%d] %s · %s" % [n, total, job.label, input_name(input)])
			if not await _run_job(step, job, input, out_dir, work_root, keep_work):
				failed.append("%s · %s" % [job.id, input_name(input)])
	var took := SteamRollerShell.format_duration(Time.get_ticks_msec() - started)
	if _runner.stop_requested():
		_runner.log_line("Stopped after %d of %d, %s." % [n, total, took])
		return false
	if failed.is_empty():
		_runner.log_line("All %d done in %s: %s" % [total, took, out_dir])
		return true
	_runner.log_error("%d of %d failed (%s): %s" % [failed.size(), total, took, ", ".join(failed)])
	return false


func _run_job(step: SteamRollerStep, job: SteamRollerRenderJob, input: String, out_dir: String,
		work_root: String, keep_work: bool) -> bool:
	var input_id := input_name(input)
	var work := work_root.path_join("%s_%s" % [job.id, input_id])
	DirAccess.make_dir_recursive_absolute(work)
	var extra: Dictionary[String, String] = {
		"INPUT": input, "INPUT_NAME": input_id, "INPUT_DIR": input.get_base_dir(),
		"JOB_ID": job.id, "OUT_DIR": out_dir, "WORK_DIR": work,
	}
	var settings := step.render_settings.duplicate()
	settings.merge(job.settings, true)
	if not settings.is_empty() and not _write_override(settings):
		return false
	var ok := job.passes.size() > 0
	if not ok:
		_runner.log_error("  The job '%s' has no passes." % job.id)
	var started := Time.get_ticks_msec()
	for i in job.passes.size():
		var render_pass := job.passes[i]
		if render_pass == null:
			continue
		var exe := _runner.vars.resolve(render_pass.executable, extra)
		var args := _runner.vars.resolve_args(render_pass.args, extra)
		var wd := _runner.vars.resolve(render_pass.working_dir, extra)
		_runner.log_line("  pass %d/%d: %s" % [i + 1, job.passes.size(), exe.get_file()])
		var filter: RegEx = null
		if not render_pass.echo_pattern.is_empty():
			filter = RegEx.create_from_string(render_pass.echo_pattern)
		var code := await _shell.run(SteamRollerShell.command_line(exe, args), wd, false, filter)
		if _runner.stop_requested():
			ok = false
			break
		if not render_pass.ok_exit_codes.has(code):
			_runner.log_error("  pass %d failed (exit %d); its files are kept in %s" % [
				i + 1, code, work])
			ok = false
			break
	if not settings.is_empty():
		_remove_override()
	if ok:
		_runner.log_line("  done in %s" % SteamRollerShell.format_duration(
			Time.get_ticks_msec() - started))
		if not keep_work:
			_remove_tree(work)
	return ok


func _write_override(settings: Dictionary) -> bool:
	var cfg := ConfigFile.new()
	for key: Variant in settings:
		var k := str(key)
		var slash := k.find("/")
		if slash <= 0:
			_runner.log_error("  The render setting '%s' needs a section: 'section/key'." % k)
			return false
		cfg.set_value(k.substr(0, slash), k.substr(slash + 1), settings[key])
	cfg.set_value(MARK_SECTION, MARK_KEY, MARK_VALUE)
	var err := cfg.save(override_path())
	if err != OK:
		_runner.log_error("  Cannot write %s (error %d)." % [override_path(), err])
		return false
	return true


func _remove_override() -> void:
	if _override_is_ours():
		DirAccess.remove_absolute(override_path())


static func _override_is_ours() -> bool:
	var path := override_path()
	if not FileAccess.file_exists(path):
		return false
	var cfg := ConfigFile.new()
	return cfg.load(path) == OK and str(cfg.get_value(MARK_SECTION, MARK_KEY, "")) == MARK_VALUE


## Delete a scratch folder this queue made, and everything in it.
static func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	for f in dir.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for d in dir.get_directories():
		_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)


## Every file matching `pattern` under `dir`, `depth` levels down. `first_only`
## stops at the first match (a quick "holds anything?").
static func _find(dir: String, pattern: String, depth: int, skip: Dictionary[String, bool],
		out: Array[String], first_only: bool) -> void:
	if depth <= 0 or (first_only and not out.is_empty()):
		return
	for f in DirAccess.get_files_at(dir):
		if pattern.is_empty() or f.matchn(pattern):
			out.append(dir.path_join(f))
			if first_only:
				return
	for sub in DirAccess.get_directories_at(dir):
		var path := dir.path_join(sub)
		if not sub.begins_with(".") and not skip.has(path.to_lower()):
			_find(path, pattern, depth - 1, skip, out, first_only)
			if first_only and not out.is_empty():
				return


## Folders never scanned: the output and scratch folders (lower case).
static func _skipped_dirs(step: SteamRollerStep, vars: SteamRollerVariables) -> Dictionary[String, bool]:
	var out: Dictionary[String, bool] = {}
	for raw: String in [step.render_out_dir, step.render_work_dir]:
		var path := _clean(vars.resolve(raw))
		if not path.is_empty():
			out[path.to_lower()] = true
	return out


## The newest modification time of the files directly in a folder.
static func _newest_time(dir: String) -> int:
	var newest := FileAccess.get_modified_time(dir)
	for f in DirAccess.get_files_at(dir):
		newest = maxi(newest, FileAccess.get_modified_time(dir.path_join(f)))
	return newest


static func _newest_first(a: Dictionary, b: Dictionary) -> bool:
	return int(a["modified"]) > int(b["modified"])


## An absolute path, forward slashes, no trailing slash, `..` folded away.
static func _clean(path: String) -> String:
	if path.is_empty():
		return ""
	return ProjectSettings.globalize_path(path).replace("\\", "/").simplify_path().trim_suffix("/")
