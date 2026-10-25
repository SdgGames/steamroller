@tool
class_name SteamRollerRenderPass extends Resource
## One command of a render job (SteamRollerRenderJob), run through the same
## shell as RUN_COMMAND. Besides every config variable and built-in, the
## command may use the job's own variables:
##   ${INPUT}      the selected file or folder (absolute path)
##   ${INPUT_NAME} a file as <parent folder>_<file name without extension>,
##                 a folder as its name
##   ${INPUT_DIR}  the input's parent folder
##   ${INPUT_HOME} a folder itself, a file's folder
##   ${INPUT_STEM} a folder's name, a file's name without extension
##   ${JOB_ID}     the job's id
##   ${OUT_DIR}    the step's output folder (render_out_dir)
##   ${WORK_DIR}   a scratch folder for this input and job, deleted when the
##                 job succeeds and kept when it fails
## and, when the step names render_build_exe, the build that runs the input:
##   ${BUILD_EXE}  its game, copied into ${WORK_DIR} with its .pck and libraries
##                 and the job's override.cfg (the build folder is never written)
##   ${BUILD_DIR}  the build's own folder
##   ${BUILD_VERSION} the version read from the input ("" when none was found)

## The program to run. Variables apply.
@export var executable: String = ""

## Its arguments, one per entry. Variables apply to each.
@export var args: PackedStringArray = []

## Working directory. Empty = the editor's own.
@export var working_dir: String = ""

## Exit codes that count as success. A game that reports a soft problem with
## its exit code can list that code here too.
@export var ok_exit_codes: PackedInt32Array = [0]

## A regular expression; only output lines that match it reach the console
## (the log file keeps every line). Empty = every line.
@export var echo_pattern: String = ""
