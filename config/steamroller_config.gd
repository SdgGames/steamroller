@tool
class_name SteamRollerConfig extends Resource
## A SteamRoller checklist. Point the project setting
## `application/steamroller/config_path` at a saved instance; the dock renders
## its steps, one tab per NEW_TAB group.

## Name shown in the dock's header.
@export var config_name: String = "SteamRoller"

## Name of the first tab (the steps before the first NEW_TAB divider).
@export var first_tab_name: String = "Build"

## Variables every step can use as ${NAME}. A value may itself use variables,
## e.g. { "BUILDS_DIR": "${PROJECT_DIR}../builds" }. The built-ins (README,
## "Variables") are added on top and win over a variable of the same name.
@export var variables: Dictionary[String, String] = {}

## The checklist, in order.
@export var steps: Array[SteamRollerStep] = []

@export_group("Advanced")
## Seconds between polls of a running external process.
@export_range(0.05, 2.0, 0.05) var poll_interval_s: float = 0.25
## Seconds between "still running" lines while a process has printed nothing
## the console can show (a redirected process's output arrives when it exits).
@export_range(1, 600, 1) var heartbeat_s: int = 10
## Lines of a failed process's log echoed into its console when only part of
## the output was being shown.
@export_range(0, 500, 1) var fail_tail_lines: int = 40
## Process logs kept in the cache folder before the oldest are deleted.
@export_range(1, 1000, 1) var logs_kept: int = 30
## Smallest width of a step's button (px). The buttons of a row wrap onto more
## lines when the dock is narrower than they are.
@export_range(60, 400, 1) var button_min_width: int = 160
## Lines of inputs a render row's list shows before it scrolls.
@export_range(3, 40, 1) var render_list_rows: int = 8
