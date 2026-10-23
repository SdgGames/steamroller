@tool
class_name SteamRollerVariables extends RefCounted
## The ${NAME} variables and the template engine.
##
## A rebuild layers four sources, each over the one before: the config's own
## variables, the built-ins (read fresh from the project settings), the INPUT
## steps bound to a setting (their setting's current value), and values set at
## runtime by INPUT steps bound to none. resolve() expands ${NAME} until nothing
## changes, so a variable may use other variables.

## The template syntax: what config files write (structural).
const TOKEN_PATTERN := r"\$\{([A-Z_][A-Z0-9_]*)\}"
## Expansion passes before giving up: variables nest at most this deep (also
## what stops a variable that names itself).
const MAX_PASSES := 8

## The current values, by name.
var values: Dictionary[String, String] = {}

## Variable -> project setting, for INPUT steps bound to a setting.
var _from_settings: Dictionary[String, String] = {}
## Values of INPUT steps bound to no setting.
var _runtime: Dictionary[String, String] = {}
## Undefined names already warned about since the last rebuild.
var _warned: Dictionary[String, bool] = {}
var _token: RegEx = RegEx.create_from_string(TOKEN_PATTERN)


## Forget every INPUT binding (a config is being loaded).
func clear_bindings() -> void:
	_from_settings.clear()
	_runtime.clear()


## `variable` always holds the current value of the project setting `setting`.
func bind_setting(variable: String, setting: String) -> void:
	_from_settings[variable] = setting


## Set a runtime value (an INPUT step bound to no setting).
func set_runtime(variable: String, value: String) -> void:
	_runtime[variable] = value
	values[variable] = value


func rebuild(config_vars: Dictionary[String, String]) -> void:
	values.clear()
	_warned.clear()
	values.merge(config_vars, true)
	values.merge(builtins(), true)
	for variable: String in _from_settings:
		values[variable] = SteamRollerSettings.text(_from_settings[variable])
	values.merge(_runtime, true)


## The built-in variables, read now.
static func builtins() -> Dictionary[String, String]:
	var commit := SteamRollerSettings.text(SteamRollerSettings.COMMIT_MESSAGE)
	var out: Dictionary[String, String] = {
		"VERSION": SteamRollerSettings.text(SteamRollerSettings.VERSION),
		"APP_NAME": SteamRollerSettings.text(SteamRollerSettings.APP_NAME),
		"COMMIT_MESSAGE": commit,
		"COMMIT_MESSAGE_SLUG": slug(commit),
		"STEAM_BRANCH": SteamRollerSettings.text(SteamRollerSettings.STEAM_BRANCH),
		"DEMO_MODE": "true" if SteamRollerSettings.demo_mode() else "false",
		"USER_DIR": ProjectSettings.globalize_path("user://"),
		"USER_DIR_FULL": SteamRollerSettings.full_user_dir(),
		"USER_DIR_DEMO": SteamRollerSettings.demo_user_dir(),
		"PROJECT_DIR": ProjectSettings.globalize_path("res://"),
		"PLATFORM": OS.get_name(),
		"GODOT_EXE": OS.get_executable_path(),
	}
	return out


## Expand every ${NAME} in `template`. `extra` is looked up first (a render
## job's own variables). An undefined name is left as written and warned
## about once, so a typo shows in the command it broke.
func resolve(template: String, extra: Dictionary[String, String] = {}) -> String:
	if not template.contains("${"):
		return template
	var result := template
	for _pass in MAX_PASSES:
		var found := _token.search_all(result)
		if found.is_empty():
			break
		var parts := PackedStringArray()
		var last := 0
		for m: RegExMatch in found:
			parts.append(result.substr(last, m.get_start() - last))
			var token_name := m.get_string(1)
			if extra.has(token_name):
				parts.append(extra[token_name])
			elif values.has(token_name):
				parts.append(values[token_name])
			else:
				_warn_undefined(token_name)
				parts.append(m.get_string(0))
			last = m.get_end()
		parts.append(result.substr(last))
		var next := "".join(parts)
		if next == result:
			break
		result = next
	return result


## resolve() for display: the project's and user folder's paths shortened to
## "...", so a description reads the same wherever the project lives.
func resolve_display(template: String) -> String:
	var result := resolve(template).replace("\\", "/")
	for key: String in ["PROJECT_DIR", "USER_DIR"]:
		var root := str(values.get(key, "")).replace("\\", "/").trim_suffix("/")
		if not root.is_empty():
			result = result.replace(root + "/", ".../")
	var before := ""
	while before != result:
		before = result
		result = result.replace(".../../", ".../")
	return result


func resolve_args(templates: PackedStringArray,
		extra: Dictionary[String, String] = {}) -> PackedStringArray:
	var out := PackedStringArray()
	for t in templates:
		out.append(resolve(t, extra))
	return out


## Resolve every string in a value, inside arrays and dictionaries too.
func resolve_value(v: Variant) -> Variant:
	if v is String:
		return resolve(v)
	if v is PackedStringArray:
		return resolve_args(v)
	if v is Array:
		var out: Array = []
		for entry: Variant in v:
			out.append(resolve_value(entry))
		return out
	if v is Dictionary:
		var out: Dictionary = {}
		var d: Dictionary = v
		for key: Variant in d:
			out[key] = resolve_value(d[key])
		return out
	return v


func resolve_params(params: Dictionary) -> Dictionary:
	var resolved: Variant = resolve_value(params)
	return resolved


## Free text as a folder-name segment: lower case, letters, digits, "_" and
## "-" kept, spaces as "_", everything else dropped.
static func slug(text: String) -> String:
	var out := ""
	for ch in text.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-":
			out += ch
		elif ch == " ":
			out += "_"
	return out


## One added to the last number of a dotted version: 1.2.3.4 -> 1.2.3.5,
## 0.1 -> 0.2, 5 -> 6. "" when the last part is not a number.
static func bump_version(version: String) -> String:
	var dot := version.rfind(".")
	var tail := version.substr(dot + 1)
	if not tail.is_valid_int():
		return ""
	return version.substr(0, dot + 1) + str(tail.to_int() + 1)


func _warn_undefined(token_name: String) -> void:
	if _warned.has(token_name):
		return
	_warned[token_name] = true
	push_warning("[SteamRoller] Undefined variable: ${%s}" % token_name)
