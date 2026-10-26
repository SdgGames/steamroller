@tool
class_name SteamRollerStep extends Resource
## One step of a SteamRoller checklist.
##
## Every kind of step is this one resource; `action` says what it does, and the
## fields that action does not use are ignored. A step renders as one row:
##
##   [x] Display name           a checkbox (INPUT: a label and a text field;
##                              a step with no display name has no header)
##   description                BBCode, ${NAME} variables resolved
##        [ Button ] [ ... ]    the step's own buttons, then those of every
##                              step attached to it (attach_to)
##   console                    the output of the row's steps, hidden until
##                              there is some
##
## A step with `attach_to` set renders no row of its own: its buttons join the
## named step's row. It keeps its own id, completion, gating and output.

## What a step does. The values are stored as numbers in config files, so a new
## action is only ever appended, and none is ever renumbered.
enum Action {
	## A manual checkbox: tick it when the thing is done.
	CHECKBOX = 0,
	## A tab divider: the steps after it go on a new tab named `tab_name`.
	NEW_TAB = 1,
	## A text field bound to a project setting and a variable. It is complete
	## when it holds text (unless require_non_empty is off).
	INPUT = 2,
	## Run every GdUnit4 test. Disabled when GdUnit4 is not installed.
	RUN_GDUNIT = 3,
	## Play the main scene under Movie Maker, then optionally re-encode the
	## film with ffmpeg. params: { "output_path": String, "reencode": bool,
	## "crf": int = 23, "preset": String = "medium", "suffix": String = "_sample.mp4" }
	RECORD_MOVIE = 4,
	## Delete a folder and everything in it, then optionally create folders.
	## params: { "path": String, "paths": Array[String] (optional) }
	DELETE_FOLDER = 5,
	## Create folders (existing ones are fine). params: { "paths": Array[String] }
	CREATE_FOLDERS = 6,
	## Copy a folder into another, newer files only (xcopy /D).
	## params: { "source": String, "destination": String }
	ARCHIVE_FOLDER = 7,
	## Delete everything in the project's user:// folder (confirm_text asks first).
	CLEAR_USER_DATA = 8,
	## Open a folder in the file manager. params: { "path": String,
	## "create": bool = false (make the folder first when it is missing) }
	OPEN_IN_EXPLORER = 9,
	## Copy text to the clipboard. params: { "text": String }
	COPY_TO_CLIPBOARD = 10,
	## Add one to the last number of the version, clear the commit message,
	## untick every step, clear every console and show the first tab.
	RESET_AND_INCREMENT = 11,
	## Run a program: `executable`, `args`, `working_dir`.
	RUN_COMMAND = 12,
	## Run other steps in order (`step_ids`); a step that is not yet enabled is
	## skipped. Each one that runs is ticked or unticked by its result.
	RUN_STEPS = 13,
	## Write the Steam build description (and optionally the branch it goes
	## live on) into app build VDF files.
	## params: { "files": Array[String], "desc": String, "branch": String (optional) }
	WRITE_VDF_DESC = 14,
	## Export headlessly, like the editor's Export All: two buttons, Debug and
	## Release, each exporting every preset to its own export path.
	## params: { "debug": bool (optional: one button, that mode),
	##           "exports": Array[{ "preset": String, "output": String }] (optional) }
	EXPORT_PROJECT = 15,
	## Removed in 0.3: runs as RUN_COMMAND. Kept so old configs still load.
	RUN_COMMAND_ASYNC = 16,
	## Turn files into videos (or anything else) in a batch: the row lists what
	## it finds under `render_scan_dirs`, and runs every selected input through
	## every ticked `render_jobs` entry, one after the other. See the README.
	RENDER_QUEUE = 17,
}

## Stable identifier: what `depends_on`, `attach_to` and `step_ids` name. A
## step with no id cannot be ticked, gated on, or attached to.
@export var id: String = ""

## What this step does.
@export var action: Action = Action.CHECKBOX

## Header text: the checkbox's, or the INPUT field's label.
@export var display_name: String = ""

## BBCode shown under the header. ${NAME} variables are resolved, so
## [color=cyan]${BUILDS_DIR}[/color] shows the real folder.
@export_multiline var description: String = ""

## Steps that must all be ticked before this step's buttons are enabled.
@export var depends_on: PackedStringArray = []

## Steps of which at least one must be ticked before this step's buttons are
## enabled (an "either one" gate). Applies together with depends_on.
@export var depends_on_any: PackedStringArray = []

## Steps ticked along with this one: it stands in for them (Copy saves for
## Record gameplay). Only a tick carries; unticking this step leaves them.
@export var also_ticks: PackedStringArray = []

## Button text. Empty = the action's default ("Run unit tests", ...).
@export var button_label: String = ""

## The id of the step whose row shows this step's buttons. Such a step has no
## row of its own, but keeps its own id, completion, gating and output.
@export var attach_to: String = ""

## Attached steps only: start a new line of buttons in the host row.
@export var new_button_row: bool = false

## A question asked before the step runs (OK runs it, Cancel does not).
## Variables apply. Empty = no question.
@export_multiline var confirm_text: String = ""

## Action-specific parameters (see Action). Strings, also inside arrays and
## dictionaries, are resolved before the step runs.
@export var params: Dictionary = {}

@export_group("Input")
## INPUT: the variable (without ${}) the field's text is available as.
@export var target_variable: String = ""
## INPUT: the project setting the field reads and writes.
@export var project_setting_path: String = ""
## INPUT: written to the setting when the setting is empty.
@export var default_value: String = ""
## INPUT: grey text shown while the field is empty.
@export var placeholder: String = ""
## INPUT: the step counts as done only while the field holds text.
@export var require_non_empty: bool = true

@export_group("Run Command")
## RUN_COMMAND: the program. Variables apply.
@export var executable: String = ""
## RUN_COMMAND: its arguments, one per entry. Variables apply to each.
@export var args: PackedStringArray = []
## RUN_COMMAND: working directory. Empty = the editor's own.
@export var working_dir: String = ""
## RUN_COMMAND: a non-zero exit code fails the step.
@export var require_zero_exit: bool = true

@export_group("Run Steps")
## RUN_STEPS: the ids of the steps to run, in order.
@export var step_ids: PackedStringArray = []

@export_group("New Tab")
## NEW_TAB: the new tab's name.
@export var tab_name: String = ""

@export_group("Render Queue")
## RENDER_QUEUE: folders to look in. Each one's subfolders that hold inputs
## become the row's source choices (newest first). Variables apply.
@export var render_scan_dirs: PackedStringArray = []
## RENDER_QUEUE: which files are inputs, as a file-name pattern ("*.tape").
@export var render_pattern: String = ""
## RENDER_QUEUE: also list each folder that holds inputs, as one input.
@export var render_include_folders: bool = false
## RENDER_QUEUE: where the results go: the jobs' ${OUT_DIR}. Variables apply,
## the job's own too (all but ${OUT_DIR}): "${INPUT_HOME}" puts each result
## beside its input, "${INPUT_SOURCE}" in the source folder it was found in.
@export var render_out_dir: String = ""
## RENDER_QUEUE: the game inside a build folder ("game_depot/Game.exe"). Set,
## each input is run by an exported build instead of the editor: the build
## named by the input's version (render_version_pattern), else the nearest
## folder above the input that holds it. Passes get ${BUILD_EXE}: a copy of
## it in the job's scratch folder. Empty = passes run whatever they name
## (${GODOT_EXE}).
@export var render_build_exe: String = ""
## RENDER_QUEUE: a regular expression whose first group is the version that
## made an input, read from its first line (a folder: its last input's), e.g.
## "\"game\":\"([^\"]+)\"". The build folder named that version, or starting
## with it and "_", runs it. Empty = the build the input sits in.
@export var render_version_pattern: String = ""
## RENDER_QUEUE: a regular expression whose first group is an input's length
## in seconds, read from its last line that holds it (a folder: its inputs'
## sum), shown beside it in the list, e.g. "\"t\":([0-9.eE+-]+)". Empty = no
## length.
@export var render_length_pattern: String = ""
## RENDER_QUEUE: where each job's scratch folder (${WORK_DIR}) is made.
## Empty = a folder in the OS cache directory. Variables apply.
@export var render_work_dir: String = ""
## RENDER_QUEUE: project settings that hold while any job runs, as
## { "section/key": value }; each job can add to them (SteamRollerRenderJob).
@export var render_settings: Dictionary = {}
## RENDER_QUEUE: the outputs on offer, one checkbox each.
@export var render_jobs: Array[SteamRollerRenderJob] = []

## Configs written for SteamRoller 0.2 marked a step that joins the row above
## as optional. It still works that way; attach_to is the way to say it now.
@export_storage var is_optional: bool = false


## The button text an action gets when `button_label` is empty, or "" for an
## action with no button.
func get_default_button_label() -> String:
	match action:
		Action.RUN_GDUNIT: return "Run unit tests"
		Action.RECORD_MOVIE: return "Record gameplay"
		Action.DELETE_FOLDER: return "Delete folder"
		Action.CREATE_FOLDERS: return "Create folders"
		Action.ARCHIVE_FOLDER: return "Archive build"
		Action.CLEAR_USER_DATA: return "Clear user data"
		Action.OPEN_IN_EXPLORER: return "Open folder"
		Action.COPY_TO_CLIPBOARD: return "Copy to clipboard"
		Action.RESET_AND_INCREMENT: return "Reset and increment version"
		Action.RUN_COMMAND, Action.RUN_COMMAND_ASYNC: return "Run command"
		Action.RUN_STEPS: return "Run all"
		Action.WRITE_VDF_DESC: return "Write VDF description"
		Action.EXPORT_PROJECT: return "Export All"
		Action.RENDER_QUEUE: return "Render selected"
	return ""


## The buttons this step shows, in order, as { "label": String,
## "overrides": Dictionary (merged over the resolved params when pressed) }.
## EXPORT_PROJECT shows Debug and Release unless params.debug pins one mode.
func get_button_specs() -> Array[Dictionary]:
	var specs: Array[Dictionary] = []
	var default_label := get_default_button_label()
	if default_label.is_empty():
		return specs
	var base := button_label if not button_label.is_empty() else default_label
	if action == Action.EXPORT_PROJECT and not params.has("debug"):
		specs.append({"label": "%s Debug" % base, "overrides": {"debug": true}})
		specs.append({"label": "%s Release" % base, "overrides": {"debug": false}})
	else:
		specs.append({"label": base, "overrides": {}})
	return specs


func has_action_button() -> bool:
	return not get_default_button_label().is_empty()


## True when this step's buttons stay disabled once it is ticked, until the
## checklist is reset: exports overwrite their destination, so they run once
## per version.
func locks_when_completed() -> bool:
	return action == Action.EXPORT_PROJECT


## True when the action writes to a console.
func produces_output() -> bool:
	match action:
		Action.CHECKBOX, Action.NEW_TAB, Action.INPUT:
			return false
	return true


## True for actions that finish at once and touch nothing a running step uses:
## they stay available while another step runs.
func is_instant() -> bool:
	match action:
		Action.OPEN_IN_EXPLORER, Action.COPY_TO_CLIPBOARD:
			return true
	return false


## True when running the step ticks (or, on failure, unticks) it.
func marks_completion() -> bool:
	return not id.is_empty() and action != Action.RESET_AND_INCREMENT


## The question asked before running, unresolved ("" = none).
func confirmation() -> String:
	return confirm_text


## INPUT: whether `text` makes the step complete.
func input_complete(text: String) -> bool:
	return not require_non_empty or not text.is_empty()
