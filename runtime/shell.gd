@tool
class_name SteamRollerShell extends RefCounted
## Runs external commands without blocking the editor.
##
## A command runs through cmd.exe with stdout and stderr redirected to a fresh
## log file, and is polled from a coroutine, so the editor stays usable for the
## whole run. The log is kept (newest config.logs_kept) in the OS cache folder,
## outside user://, which CLEAR_USER_DATA deletes.
##
## Output reaches the console when the process exits. While cmd.exe holds the
## redirect open, Godot cannot open the file (measured on Windows: it asks for
## read access without sharing writes), so a heartbeat line marks progress
## meanwhile. stop() ends the process and everything it started.
##
## Windows only: cmd.exe and taskkill.

## The exit code run() returns when the process could not be started.
const NOT_STARTED := -1
## How the heartbeat line begins: a console replaces the last heartbeat with the next one
## (structural: the console matches on it).
const HEARTBEAT_PREFIX := "… still running"

var _runner: SteamRollerStepRunner
## The running cmd.exe, or 0.
var _pid := 0
## stop() was called during the current run.
var _stopping := false
var _log_seq := 0
var _ansi: RegEx = RegEx.create_from_string("\u001b\\[[0-9;?]*[ -/]*[@-~]")


func _init(runner: SteamRollerStepRunner) -> void:
	_runner = runner


## True while a command runs.
func is_running() -> bool:
	return _pid > 0 and OS.is_process_running(_pid)


## End the running command and every process it started.
func stop() -> void:
	if not is_running():
		return
	_stopping = true
	var out: Array = []
	OS.execute("taskkill", ["/T", "/F", "/PID", str(_pid)], out, true)


## Run a cmd.exe command line and return its exit code (NOT_STARTED when it
## could not start). Lines go to the running step's console when the process
## exits: all of them; only those matching `filter`; or with `quiet`, none,
## unless it fails. A failure that was filtered or quiet also shows the last
## lines of the log, and the log's path.
func run(command: String, working_dir: String = "", quiet: bool = false,
		filter: RegEx = null) -> int:
	var log_path := _new_log_path()
	if log_path.is_empty():
		return NOT_STARTED
	var body := command
	if not working_dir.is_empty():
		# A trailing separator would escape its own closing quote: "C:\dir\".
		body = "cd /d \"%s\" && %s" % [working_dir.trim_suffix("/").trim_suffix("\\"), body]
	# chcp keeps tool output out of the OEM code page; >nul hides its banner.
	# The parentheses take a failing `cd` into the redirect too.
	var full := "(chcp 65001>nul & %s) > \"%s\" 2>&1" % [body, log_path]
	_stopping = false
	_pid = OS.create_process("cmd", ["/c", full], false)
	if _pid <= 0:
		_pid = 0
		_runner.log_error("Could not start: %s" % command)
		return NOT_STARTED
	var cfg := _runner.config
	var poll_s := cfg.poll_interval_s if cfg else 0.25
	var beat_ms := (cfg.heartbeat_s if cfg else 10) * 1000
	var started := Time.get_ticks_msec()
	var next_beat := beat_ms
	var offset := 0
	while OS.is_process_running(_pid):
		await _runner.get_tree().create_timer(poll_s).timeout
		if not quiet:
			offset = _drain(log_path, offset, false, filter)
		var elapsed := Time.get_ticks_msec() - started
		if elapsed >= next_beat:
			# The console only: an eight-hour render must not fill the Output panel.
			_runner.log_line("%s (%s)" % [HEARTBEAT_PREFIX, format_duration(elapsed)], false)
			next_beat += beat_ms
	var code := OS.get_process_exit_code(_pid)
	var stopped := _stopping
	_pid = 0
	_stopping = false
	if not quiet:
		_drain(log_path, offset, true, filter)
	if code != 0 and not stopped and (quiet or filter != null):
		_runner.log_error("Full output: %s" % log_path)
		_echo_tail(log_path, cfg.fail_tail_lines if cfg else 40)
	prune_logs()
	return code


## A command line for cmd.exe: the program and each argument quoted as needed.
static func command_line(exe: String, args: PackedStringArray) -> String:
	var parts := PackedStringArray([quote(exe)])
	for a in args:
		parts.append(quote(a))
	return " ".join(parts)


## One argument as cmd.exe and the program's argument parser both read it back:
## an empty one, or one with a space or a cmd metacharacter, goes in double
## quotes, with backslashes doubled only where they precede a quote (the
## CommandLineToArgvW rule). An argument already in quotes is left alone.
static func quote(arg: String) -> String:
	if arg.is_empty():
		return "\"\""
	if arg.length() >= 2 and arg.begins_with("\"") and arg.ends_with("\""):
		return arg
	var needs := false
	for ch: String in [" ", "\t", "&", "|", "<", ">", "^", "(", ")", "\""]:
		if arg.contains(ch):
			needs = true
			break
	if not needs:
		return arg
	var out := ""
	var slashes := 0
	for ch in arg:
		if ch == "\\":
			slashes += 1
			continue
		if ch == "\"":
			out += "\\".repeat(slashes * 2 + 1) + "\""
		else:
			out += "\\".repeat(slashes) + ch
		slashes = 0
	return "\"" + out + "\\".repeat(slashes * 2) + "\""


## "42s", "3m05s", "2h07m".
static func format_duration(msec: int) -> String:
	var s := msec / 1000
	if s < 60:
		return "%ds" % s
	if s < 3600:
		return "%dm%02ds" % [s / 60, s % 60]
	return "%dh%02dm" % [s / 3600, (s % 3600) / 60]


## Keep the newest logs (config.logs_kept). Timestamped names sort by age.
func prune_logs() -> void:
	var keep := _runner.config.logs_kept if _runner.config else 30
	var dir := log_dir()
	var names := Array(DirAccess.get_files_at(dir))
	if names.size() <= keep:
		return
	names.sort()
	for i in names.size() - keep:
		DirAccess.remove_absolute(dir.path_join(str(names[i])))


## Where the logs live: the OS cache folder, per project, never user://.
static func log_dir() -> String:
	var base := OS.get_cache_dir()
	if base.is_empty():
		base = ProjectSettings.globalize_path("user://")
	var app := SteamRollerSettings.text(SteamRollerSettings.APP_NAME)
	var dir := base.path_join("steamroller_logs").path_join(
		(app if not app.is_empty() else "project").validate_filename())
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


## A fresh, empty log file named <timestamp>_<seq>_<console>.log, so a plain
## name sort is by age and a stale read is impossible. "" if it cannot be made.
func _new_log_path() -> String:
	_log_seq += 1
	var slug := _runner.console_id()
	if slug.is_empty():
		slug = "step"
	var stamp := Time.get_datetime_string_from_system(false, false).replace(":", "").replace("-", "")
	var path := log_dir().path_join("%s_%03d_%s.log" % [stamp, _log_seq, slug.validate_filename()])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_runner.log_error("Cannot create the log file %s (error %d)." % [
			path, FileAccess.get_open_error()])
		return ""
	f.close()
	return path


## Emit the complete lines appended to `path` since `offset`; return the new
## offset. The offset only advances to the last newline read, so a half-written
## line or a split UTF-8 sequence is simply read again next time. `final` also
## emits a last line with no newline.
func _drain(path: String, offset: int, final: bool, filter: RegEx) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return offset   # still held by cmd.exe: see the class comment
	var size := f.get_length()
	if size <= offset:
		f.close()
		return offset
	f.seek(offset)
	var text := f.get_buffer(size - offset).get_string_from_utf8()
	f.close()
	var consumed := size
	if not final:
		var cut := text.rfind("\n")
		if cut == -1:
			return offset
		text = text.substr(0, cut + 1)
		consumed = offset + text.to_utf8_buffer().size()
	_emit(text, filter)
	return consumed


func _emit(text: String, filter: RegEx) -> void:
	for raw in text.replace("\r\n", "\n").split("\n"):
		var line := raw
		# A progress bar redraws itself with \r: keep its last state.
		var cr := line.rfind("\r")
		if cr != -1:
			line = line.substr(cr + 1)
		line = _ansi.sub(line, "", true).strip_edges()
		if line.is_empty() or (filter != null and filter.search(line) == null):
			continue
		_runner.log_line(line)


func _echo_tail(path: String, max_lines: int) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var lines := f.get_as_text().replace("\r\n", "\n").strip_edges().split("\n")
	f.close()
	var start := maxi(0, lines.size() - max_lines)
	if start > 0:
		_runner.log_line("… %d earlier line(s) in the log" % start)
	for i in range(start, lines.size()):
		var line := _ansi.sub(lines[i], "", true).strip_edges()
		if not line.is_empty():
			_runner.log_line(line)
