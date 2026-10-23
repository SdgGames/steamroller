@tool
class_name SteamRollerRenderJob extends Resource
## One output of a RENDER_QUEUE step: a checkbox in its row, and the commands
## (passes) that turn one selected input into one result. The batch runs every
## selected input through every ticked job, one after the other.

## Stable id: the ${JOB_ID} variable, and part of the scratch folder's name.
@export var id: String = ""

## Checkbox text.
@export var label: String = ""

## Tooltip on the checkbox: what this job makes and how.
@export_multiline var description: String = ""

## Ticked when the dock opens.
@export var checked: bool = false

## Project settings that hold only while this job runs, as
## { "section/key": value }, merged over the step's render_settings. They are
## written to the project's override.cfg for the duration of the job, so a game
## launched by a pass reads them, and project.godot never changes.
@export var settings: Dictionary = {}

## The commands, in order. The first that fails ends the job.
@export var passes: Array[SteamRollerRenderPass] = []
