@tool
class_name SteamRollerConfig extends Resource
## Top-level SteamRoller configuration. Point project setting
## `application/steamroller/config_path` at a saved instance of this resource.

## Name shown on the panel header.
@export var config_name: String = "SteamRoller"

## Name for the first tab (steps before the first NEW_TAB divider).
@export var first_tab_name: String = "Build"

## Identity constants available to all steps via ${VAR} substitution.
##
## Example:
##   { "STEAM_APP_ID": "480", "BUILDS_DIR": "${PROJECT_DIR}/../builds" }
@export var variables: Dictionary = {}

## Ordered list of workflow steps.
@export var steps: Array = []
