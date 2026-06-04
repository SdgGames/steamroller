@tool
class_name SteamRollerStep extends Resource
## A single step in a SteamRoller workflow.
##
## All step variations are expressed as one resource with an `action` enum.
## Fields irrelevant to the chosen action are simply ignored.
##
## Layout per row in the UI:
##   [Checkbox]  Step name              <- always present, except NEW_TAB (skipped)
##                                          and INPUT (replaced by LineEdit)
##   <description RichTextLabel>        <- only if `description` is non-empty
##         [ Action button ]            <- only for actions that DO something
##   <per-step console output>          <- only for RUN_COMMAND and built-ins
##                                          that produce output

enum Action {
	## Manual checkbox. No-op action — the user just ticks it when done.
	CHECKBOX,
	## Tab divider. Steps after this are placed in a new tab named `tab_name`.
	NEW_TAB,
	## Text input bound to a project setting. The field itself is the
	## completion signal (non-empty = done, if require_non_empty is true).
	INPUT,
	## Run all GdUnit4 tests. Disabled with a warning if GdUnit is not present.
	RUN_GDUNIT,
	## Movie maker mode + main scene playback + optional ffmpeg re-encode.
	## params: { "output_path": String, "reencode": bool }
	RECORD_MOVIE,
	## Recursively delete a folder, then optionally recreate paths.
	## params: { "path": String, "paths": Array[String] (optional) }
	DELETE_FOLDER,
	## Create folders (idempotent). params: { "paths": Array[String] }
	CREATE_FOLDERS,
	## Copy folder contents to a destination via xcopy.
	## params: { "source": String, "destination": String }
	ARCHIVE_FOLDER,
	## Recursively delete user://. No params.
	CLEAR_USER_DATA,
	## Reveal a path in the OS file manager. params: { "path": String }
	OPEN_IN_EXPLORER,
	## Copy a templated string to the clipboard. params: { "text": String }
	COPY_TO_CLIPBOARD,
	## Reset completion state for steps in the current tab, then increment
	## the last numeric segment of application/config/version.
	RESET_AND_INCREMENT,
	## External CLI command. Uses `executable`, `args`, `working_dir`.
	RUN_COMMAND,
}

## Stable identifier. Referenced by `depends_on` in other steps. Optional
## for CHECKBOX/NEW_TAB but required if anything depends on this step.
@export var id: String = ""

## Action this step performs.
@export var action: Action = Action.CHECKBOX

## Display name shown in the row header.
@export var display_name: String = ""

## Optional BBCode description shown as a RichTextLabel below the header.
## Variable substitution applies, so [color=cyan]${BUILDS_DIR}[/color] works.
@export_multiline var description: String = ""

## IDs of other steps that must be completed before this one is enabled.
@export var depends_on: PackedStringArray = []

## Action button label. Defaults are provided per action — leave empty to use
## the default ("Run unit tests", "Record gameplay", etc.).
@export var button_label: String = ""

## Optional shortcut button. If true, this step:
##   - renders no checkbox, description, or separator
##   - stacks its button into the previous step's button row (or creates a
##     new orphan row if there's no previous row to attach to)
##   - does not gate other steps and is not tracked in completion state
##   - suppresses per-step console output on success (errors still print
##     via push_warning / push_error to the editor output)
##
## Use this for shortcuts like "Open build folder" or "Clear user data".
@export var is_optional: bool = false

## Action-specific parameters. String values pass through variable
## substitution before execution. See enum docs above for expected keys.
@export var params: Dictionary = {}

# --- Action-specific fields ------------------------------------------------
# These could go in `params`, but they're common enough that exporting them
# directly makes the inspector friendlier.

## INPUT: variable name (without ${}) that this input writes into the
## runtime variable bag.
@export_group("Input")
@export var target_variable: String = ""
## INPUT: project setting path the field persists to.
@export var project_setting_path: String = ""
## INPUT: default value if the project setting is empty.
@export var default_value: String = ""
## INPUT: placeholder text shown when the field is empty.
@export var placeholder: String = ""
## INPUT: require non-empty input for the step to count as complete.
@export var require_non_empty: bool = true

@export_group("Run Command")
## RUN_COMMAND: path to the executable. May use ${VAR} substitution.
@export var executable: String = ""
## RUN_COMMAND: arguments. Each entry may use ${VAR} substitution.
@export var args: PackedStringArray = []
## RUN_COMMAND: working directory. Empty = project root.
@export var working_dir: String = ""
## RUN_COMMAND: treat non-zero exit code as failure.
@export var require_zero_exit: bool = true

@export_group("New Tab")
## NEW_TAB: name for the new tab.
@export var tab_name: String = ""


## Default button label for actions that show an action button.
## Returns "" for actions that don't need a button (CHECKBOX, NEW_TAB, INPUT).
func get_default_button_label() -> String:
	match action:
		Action.RUN_GDUNIT: return "Run unit tests"
		Action.RECORD_MOVIE: return "Record gameplay"
		Action.DELETE_FOLDER: return "Delete folder"
		Action.CREATE_FOLDERS: return "Create folders"
		Action.ARCHIVE_FOLDER: return "Archive build"
		Action.CLEAR_USER_DATA: return "Clear user data"
		Action.OPEN_IN_EXPLORER: return "Open in file manager"
		Action.COPY_TO_CLIPBOARD: return "Copy to clipboard"
		Action.RESET_AND_INCREMENT: return "Reset and increment version"
		Action.RUN_COMMAND: return "Run command"
		_: return ""


## True if this action has a button the user can press to execute it.
func has_action_button() -> bool:
	return not get_default_button_label().is_empty()


## True if this action produces console output worth showing.
func produces_output() -> bool:
	match action:
		Action.RUN_GDUNIT, Action.RECORD_MOVIE, Action.DELETE_FOLDER, \
		Action.CREATE_FOLDERS, Action.ARCHIVE_FOLDER, Action.CLEAR_USER_DATA, \
		Action.COPY_TO_CLIPBOARD, Action.RESET_AND_INCREMENT, Action.RUN_COMMAND:
			return true
		_:
			return false
