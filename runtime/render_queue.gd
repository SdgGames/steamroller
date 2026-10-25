@tool
class_name SteamRollerRenderQueue extends RefCounted
## RENDER_QUEUE: every selected input through every ticked job, one after the
## other, each job's passes in order through the shell.
##
## A job's project settings (the step's render_settings and the job's own) are
## written to an override.cfg for the duration of the job, so the game a pass
## launches reads them and project.godot never changes. With render_build_exe
## the game is an exported build (find_build()), copied into the job's scratch
## folder (its game, .pck and libraries) with the file beside it, where an
## export reads it; no build folder is ever written to (an export template has
## no --main-pack to load a pack from elsewhere). Without it the file is the
## project's own override.cfg, read by the editor binary a pass launches with
## --path. That file carries a mark; one without it is the project's own
## and is never touched: a batch refuses to start while it exists. An
## override.cfg left behind by a batch that never finished is removed when the
## plugin next loads.

## The mark in an override.cfg written here (structural: what the stale-file
## sweep looks for). The game reads it as a harmless extra setting.
const MARK_SECTION := "steamroller"
const MARK_KEY := "written_by"
const MARK_VALUE := "render_queue"
## How deep below a source folder inputs are looked for: a scan of a big build
## folder stays quick.
const SCAN_DEPTH := 5
## The variables a job adds (structural: the names passes and render_out_dir
## write; render_out_dir may use any but OUT_DIR).
const JOB_VARIABLES: Array[String] = ["INPUT", "INPUT_NAME", "INPUT_DIR", "INPUT_HOME",
	"INPUT_STEM", "JOB_ID", "OUT_DIR", "WORK_DIR", "BUILD_DIR", "BUILD_EXE", "BUILD_VERSION"]
## The libraries an export loads from beside its game, by platform: they travel
## with it into the job's scratch folder, with its .pck (structural: an
## export's own file layout).
const LIBRARY_TYPES: Dictionary[String, String] = {"Windows": "dll", "macOS": "dylib"}
const LIBRARY_TYPE_ELSE := "so"

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
## A label is the input's path below the source, so two folders of one name in
## different places stay apart.
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
		out.append({"path": f, "label": "%s · %s" % [_below(dir, source), f.get_file()],
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
		dirs.append({"path": dir, "label": "%s/ (all %d)" % [_below(dir, source), n], "is_dir": true,
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


## The exported build that runs an input's passes (render_build_exe set):
## { "dir", "exe", "version", "recorded" }, or {} when none holds the game.
## The version is read from the input with render_version_pattern (a folder's
## last input in natural order: its last sitting); the build is the scan
## root's subfolder named that version, or starting with it and "_", the
## newest if several ("recorded" true). Failing that, the nearest folder above
## the input that holds the game (a build not archived yet, or a version that
## never was).
static func find_build(step: SteamRollerStep, vars: SteamRollerVariables,
		input: String) -> Dictionary:
	var exe_rel := step.render_build_exe
	var version := _version_of(step, input)
	if not version.is_empty():
		var best := ""
		var best_time := -1
		for raw in step.render_scan_dirs:
			var root := _clean(vars.resolve(raw))
			if root.is_empty() or not DirAccess.dir_exists_absolute(root):
				continue
			for sub in DirAccess.get_directories_at(root):
				if sub != version and not sub.begins_with(version + "_"):
					continue
				var exe := root.path_join(sub).path_join(exe_rel)
				if FileAccess.file_exists(exe) and FileAccess.get_modified_time(exe) > best_time:
					best_time = FileAccess.get_modified_time(exe)
					best = root.path_join(sub)
		if not best.is_empty():
			return {"dir": best, "exe": best.path_join(exe_rel), "version": version,
				"recorded": true}
	var dir := input if DirAccess.dir_exists_absolute(input) else input.get_base_dir()
	for _level in 64:
		if FileAccess.file_exists(dir.path_join(exe_rel)):
			return {"dir": dir, "exe": dir.path_join(exe_rel), "version": version,
				"recorded": false}
		var up := dir.get_base_dir()
		if up.is_empty() or up == dir:
			break
		dir = up
	return {}


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
	var out_template := str(p.get("out_dir", step.render_out_dir))
	if out_template.is_empty():
		_runner.log_error("The step has no render_out_dir.")
		return false
	var work_root := _clean(str(p.get("work_dir", _runner.vars.resolve(step.render_work_dir))))
	if work_root.is_empty():
		work_root = OS.get_cache_dir().path_join("steamroller_render").path_join(
			SteamRollerSettings.text(SteamRollerSettings.APP_NAME).validate_filename())
	if step.render_build_exe.is_empty() and FileAccess.file_exists(override_path()) \
			and not _override_is_ours():
		_runner.log_error("%s exists and is not SteamRoller's: move it aside to render." % override_path())
		return false
	var keep_work: bool = p.get("keep_work", false) == true
	var total := inputs.size() * jobs.size()
	var n := 0
	var failed := PackedStringArray()
	var started := Time.get_ticks_msec()
	_runner.log_line("%d render(s)" % total)
	for raw: Variant in inputs:
		if _runner.stop_requested():
			break
		var input := _clean(str(raw))
		for job in jobs:
			if _runner.stop_requested():
				break
			n += 1
			_runner.log_line("[%d/%d] %s · %s" % [n, total, job.label, _shown(step, input)])
			if not await _run_job(step, job, input, out_template, work_root, keep_work, n):
				failed.append("%s · %s" % [job.id, _shown(step, input)])
	var took := SteamRollerShell.format_duration(Time.get_ticks_msec() - started)
	if _runner.stop_requested():
		_runner.log_line("Stopped after %d of %d, %s." % [n, total, took])
		return false
	if failed.is_empty():
		_runner.log_line("All %d done in %s." % [total, took])
		return true
	_runner.log_error("%d of %d failed (%s): %s" % [failed.size(), total, took, ", ".join(failed)])
	return false


func _run_job(step: SteamRollerStep, job: SteamRollerRenderJob, input: String,
		out_template: String, work_root: String, keep_work: bool, n: int) -> bool:
	var input_id := input_name(input)
	var is_dir := DirAccess.dir_exists_absolute(input)
	var work := work_root.path_join("%d_%s_%s" % [n, job.id, input_id])
	DirAccess.make_dir_recursive_absolute(work)
	var extra: Dictionary[String, String] = {
		"INPUT": input, "INPUT_NAME": input_id, "INPUT_DIR": input.get_base_dir(),
		"INPUT_HOME": input if is_dir else input.get_base_dir(),
		"INPUT_STEM": input.get_file() if is_dir else input.get_file().get_basename(),
		"JOB_ID": job.id, "WORK_DIR": work,
	}
	var settings := step.render_settings.duplicate()
	settings.merge(job.settings, true)
	var cfg_path := override_path()
	if not step.render_build_exe.is_empty():
		var build := find_build(step, _runner.vars, input)
		if build.is_empty():
			_runner.log_error("  No game build for this input: no %s in a build named by its version, nor in a folder above it." % step.render_build_exe)
			return false
		var version := str(build["version"])
		_runner.log_line("  filmed by %s (%s%s)" % [version if not version.is_empty() else "?",
			str(build["dir"]).get_file(), "" if build["recorded"] else ", the build it sits in"])
		var staged := _stage_build(str(build["exe"]), work)
		if staged.is_empty():
			return false
		extra["BUILD_DIR"] = str(build["dir"])
		extra["BUILD_EXE"] = staged
		extra["BUILD_VERSION"] = version
		cfg_path = work.path_join("override.cfg")
	var out_dir := _clean(_runner.vars.resolve(out_template, extra))
	extra["OUT_DIR"] = out_dir
	DirAccess.make_dir_recursive_absolute(out_dir)
	if not settings.is_empty() and not _write_override(settings, cfg_path):
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
	if not settings.is_empty() and step.render_build_exe.is_empty():
		_remove_override()
	if ok:
		_runner.log_line("  done in %s: %s" % [SteamRollerShell.format_duration(
			Time.get_ticks_msec() - started), out_dir])
		if not keep_work:
			_remove_tree(work)
	return ok


## The build's game copied into the job's scratch folder with its .pck and this
## platform's libraries beside it (LIBRARY_TYPES), so the job's override.cfg
## sits where the export reads it; the copy's path, or "" on failure.
func _stage_build(exe: String, work: String) -> String:
	var pck := exe.get_basename() + ".pck"
	if not FileAccess.file_exists(pck):
		_runner.log_error("  The build has no %s beside its game." % pck.get_file())
		return ""
	var dir := exe.get_base_dir()
	var library: String = LIBRARY_TYPES.get(OS.get_name(), LIBRARY_TYPE_ELSE)
	var files: Array[String] = [exe.get_file(), pck.get_file()]
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() == library:
			files.append(f)
	for f in files:
		if DirAccess.copy_absolute(dir.path_join(f), work.path_join(f)) != OK:
			_runner.log_error("  Cannot copy %s into %s." % [dir.path_join(f), work])
			return ""
	return work.path_join(exe.get_file())


func _write_override(settings: Dictionary, path: String) -> bool:
	var cfg := ConfigFile.new()
	for key: Variant in settings:
		var k := str(key)
		var slash := k.find("/")
		if slash <= 0:
			_runner.log_error("  The render setting '%s' needs a section: 'section/key'." % k)
			return false
		cfg.set_value(k.substr(0, slash), k.substr(slash + 1), settings[key])
	cfg.set_value(MARK_SECTION, MARK_KEY, MARK_VALUE)
	var err := cfg.save(path)
	if err != OK:
		_runner.log_error("  Cannot write %s (error %d)." % [path, err])
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


## The version render_version_pattern finds in the input's first line (a
## folder's last input in natural order), or "".
static func _version_of(step: SteamRollerStep, input: String) -> String:
	if step.render_version_pattern.is_empty():
		return ""
	var file := input
	if DirAccess.dir_exists_absolute(input):
		var names: Array[String] = []
		for f in DirAccess.get_files_at(input):
			if step.render_pattern.is_empty() or f.matchn(step.render_pattern):
				names.append(f)
		if names.is_empty():
			return ""
		names.sort_custom(func(a: String, b: String) -> bool:
			return a.naturalnocasecmp_to(b) < 0)
		file = input.path_join(names[names.size() - 1])
	var fa := FileAccess.open(file, FileAccess.READ)
	if fa == null:
		return ""
	var found := RegEx.create_from_string(step.render_version_pattern).search(fa.get_line())
	if found == null or found.get_group_count() < 1:
		return ""
	return found.get_string(1)


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


## Folders never scanned: the output and scratch folders (lower case). An
## output folder made per input (render_out_dir naming a job variable) is not
## one place, so it is not skipped.
static func _skipped_dirs(step: SteamRollerStep, vars: SteamRollerVariables) -> Dictionary[String, bool]:
	var out: Dictionary[String, bool] = {}
	for raw: String in [step.render_out_dir, step.render_work_dir]:
		if _names_job_variable(raw):
			continue
		var path := _clean(vars.resolve(raw))
		if not path.is_empty():
			out[path.to_lower()] = true
	return out


static func _names_job_variable(template: String) -> bool:
	for v in JOB_VARIABLES:
		if template.contains("${%s}" % v):
			return true
	return false


## An input as the console names it: its path below the scan root it was found
## in (the build folder first), else its full path.
func _shown(step: SteamRollerStep, input: String) -> String:
	for raw in step.render_scan_dirs:
		var root := _clean(_runner.vars.resolve(raw))
		if not root.is_empty() and input.begins_with(root + "/"):
			return input.substr(root.length() + 1)
	return input


## `path` below `root`, or its last folder's name when it is `root` itself.
static func _below(path: String, root: String) -> String:
	if path.begins_with(root + "/"):
		return path.substr(root.length() + 1)
	return path.get_file()


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
