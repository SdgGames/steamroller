#!/usr/bin/env bash
#
# deploy.sh -- export the enclosing Godot project and run it on the Steam Deck,
# in Game Mode. Ships with the SteamRoller addon; lives at
#   <project>/addons/steamroller/deck/deploy.sh
# and needs nothing else from the project but project.godot and export_presets.cfg.
#
# Uses the SteamOS devkit's device-side tools (~/devkit-utils on the Deck,
# installed when the Deck was paired with the SteamOS Devkit Client). The GUI
# client is NOT needed for anything below; it is only required to pair once.
#
#   export (headless) -> kill running instance -> checksum-guarded scp into
#   ~/devkit-game/<TITLE>/ -> register shortcut (argv + runtime) with the
#   running Steam client -> launch through Steam so gamescope owns the window.
#
# Config lives in <project>/data/deck.env (gitignored; --env FILE overrides).
# Template: addons/steamroller/templates/deck.env.example. Keys:
#   DECK_HOST=steamdeck.local
#   DECK_USER=deck
#   DECK_TITLE=                         # devkit title; default: config/name sanitised to
#                                       # [A-Za-z_][A-Za-z0-9_.]+ (no hyphens, no spaces)
#   DECK_RUNTIME=SteamLinuxRuntime_sniper   # compat_tool; empty = run binary directly
#   GODOT_BIN=/c/path/to/Godot_v4.7.2-stable_win64.exe
#   EXPORT_PRESET=Deck_Testing
#   BUILDS_DIR=                         # export dirs may only be wiped under here;
#                                       # default <project>/../builds (SteamRoller's ${BUILDS_DIR})
#   DECK_USER_DIR=                      # user:// on the Deck; default derived from config/name
#   DEBUG_HOST=                         # optional: this PC's IPv4 as seen by the Deck
#
# Transfer is scp guarded by a remote sha256sum comparison (no rsync on this
# workstation). A rebuild after a source change moves only the .pck; the 71 MB
# template binary and the GDExtension .so files are skipped.
#
# Runs from Git Bash, from PowerShell via bash.exe, and from the SteamRoller
# dock (OS.create_process, no console, no stdin). Every failure prints an
# ERROR line; nothing exits silently.

set -Eeuo pipefail

# Godot's OS.create_process gives the child no console and no valid stdin;
# MSYS coreutils probe fd 0 and die. Give them a real one.
[ -t 0 ] || exec </dev/null

# --- Paths -----------------------------------------------------------------

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"; done
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
# deck/ -> steamroller/ -> addons/ -> the project.
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
PROJECT_GODOT="$PROJECT_DIR/project.godot"
PRESETS_CFG="$PROJECT_DIR/export_presets.cfg"
ENV_FILE="$PROJECT_DIR/data/deck.env"

# A project setting as written in project.godot: `key="value"` or `key=value`,
# surrounding quotes stripped. Keys carry their section prefix (config/name).
project_setting() {
	local v; v="$(sed -n "s|^$1=||p" "$PROJECT_GODOT" 2>/dev/null | head -n 1 | tr -d '\r')"
	v="${v#\"}"; v="${v%\"}"; printf '%s' "$v"
}

# --- Defaults (deck.env overrides, the environment overrides both) ----------

# Anything the caller already exported wins over deck.env, so a one-off such as
#   DECK_HOST=192.168.1.20 deploy.sh --doctor
# works without editing the file. Snapshot it before the defaults clobber it.
CONFIG_VARS=(DECK_HOST DECK_USER DECK_TITLE DECK_RUNTIME GODOT_BIN EXPORT_PRESET BUILDS_DIR DECK_USER_DIR DEBUG_HOST DEBUG_PORT)
declare -A _env_override=()
for _v in "${CONFIG_VARS[@]}"; do [ -n "${!_v+x}" ] && _env_override[$_v]="${!_v}"; done

# Everything project-specific is read from project.godot, so this script is
# the same file in every project that carries the addon.
APP_NAME="$(project_setting config/name)"

DECK_HOST="steamdeck.local"
DECK_USER="deck"
# Devkit title: the project name with anything outside [A-Za-z0-9_.] folded to
# "_" (validated below; a leading digit or dot gets a "_" in front).
DECK_TITLE="$(printf '%s' "$APP_NAME" | sed 's/[^A-Za-z0-9_.]/_/g; s/^\([0-9.]\)/_\1/')"
DECK_RUNTIME="SteamLinuxRuntime_sniper"
GODOT_BIN=""
EXPORT_PRESET="Deck_Testing"
# Only export folders under here are ever wiped. Same default as SteamRoller's
# ${BUILDS_DIR}: a builds/ folder beside the project.
BUILDS_DIR="$(cd -- "$PROJECT_DIR/.." && pwd)/builds"
# Godot user:// on the Deck; empty = derived from project.godot below. $HOME is
# expanded by the Deck's shell, so it stays single-quoted.
DECK_USER_DIR=""
DEBUG_HOST=""
DEBUG_PORT=6007

# --- Modes -----------------------------------------------------------------

MODE="deploy"            # deploy | stop | launch | doctor
BUILD_MODE="debug"
DO_EXPORT=1
DO_LAUNCH=1
DO_CLEAN_CACHE=0
DO_TAIL=0
USE_DEBUGGER=0
DEBUGGER_HOST_OVERRIDE=""
DRY_RUN=0
GAME_ARGS=()

# --- Output ----------------------------------------------------------------

if [ -t 1 ]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
	C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'
else
	C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_DIM=""
fi
step() { printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
info() { printf '      %s\n' "$*"; }
warn() { printf '%sWARN%s  %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# set -e aborts on any unhandled failure; make sure that is never silent.
# (Expected failures are handled inline with `|| die`, which never gets here.)
trap 'rc=$?; printf "%sERROR%s command failed (exit %s) at line %s: %s\n" "$C_RED" "$C_RESET" "$rc" "$LINENO" "$BASH_COMMAND" >&2; exit "$rc"' ERR

show_cmd() {
	local out="" a
	for a in "$@"; do
		if [[ "$a" =~ ^[A-Za-z0-9_./:=@,+-]+$ ]]; then out+="$a "; else out+="'${a//\'/\'\\\'\'}' "; fi
	done
	printf '  %s%s%s\n' "$C_DIM" "${out% }" "$C_RESET"
}
run() {
	if [ "$DRY_RUN" -eq 1 ]; then show_cmd "$@"; return 0; fi
	"$@"
}
# Wrap a string in single quotes for a remote bash command line.
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
# Escape a string for use inside a JSON string literal.
json_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

usage() {
	cat <<'USAGE'
Usage: deploy.sh [options] [--run ARGS...]

  (no flags)          export -> push -> launch in Game Mode
  --release           release export instead of debug
  --no-export         push the existing builds/ folder, skip the export
  --no-launch         export and push only
  --launch            launch the build already on the Deck (no export, no push)
  --stop              kill the running instance on the Deck
  --debugger[=HOST]   run with --remote-debug tcp://HOST:6007 (editor must have
                      Debug > Keep Debug Server Open); HOST autodetected
  --clean-cache       wipe user:// on the Deck first (cold shader cache)
  --tail              after launch, follow user://logs/godot.log
  --run ARGS...       extra args passed to the game binary
  --doctor            preflight checks (add --debugger to probe port 6007)
  --dry-run           print what would run; touches neither Godot nor the Deck
  --env FILE          read config from FILE instead of <project>/data/deck.env
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--release)      BUILD_MODE="release"; shift ;;
		--no-export)    DO_EXPORT=0; shift ;;
		--no-launch)    DO_LAUNCH=0; shift ;;
		--launch)       MODE="launch"; shift ;;
		--stop)         MODE="stop"; shift ;;
		--debugger)     USE_DEBUGGER=1; shift ;;
		--debugger=*)   USE_DEBUGGER=1; DEBUGGER_HOST_OVERRIDE="${1#*=}"; shift ;;
		--clean-cache)  DO_CLEAN_CACHE=1; shift ;;
		--tail)         DO_TAIL=1; shift ;;
		--doctor)       MODE="doctor"; shift ;;
		--dry-run)      DRY_RUN=1; shift ;;
		--env)          [ $# -ge 2 ] || die "--env needs a file argument"; ENV_FILE="$2"; shift 2 ;;
		--env=*)        ENV_FILE="${1#*=}"; shift ;;
		--run)          shift; GAME_ARGS=("$@"); break ;;
		-h|--help)      usage; exit 0 ;;
		*)              usage >&2; die "unknown option: $1" ;;
	esac
done

# --- Config ----------------------------------------------------------------

if [ -f "$ENV_FILE" ]; then
	set -a
	# shellcheck disable=SC1090
	. "$ENV_FILE"
	set +a
fi
# Precedence: environment > deck.env > defaults (snapshot taken above, before
# the defaults block overwrote anything the caller exported).
for _v in "${!_env_override[@]}"; do printf -v "$_v" '%s' "${_env_override[$_v]}"; done
unset _v

[ -f "$PROJECT_GODOT" ] || die "no project.godot at $PROJECT_DIR -- deploy.sh must live at <project>/addons/steamroller/deck/"
[ -n "$DECK_TITLE" ] || die "DECK_TITLE is empty and project.godot has no config/name to derive it from"
[[ "$DECK_TITLE" =~ ^[A-Za-z_][A-Za-z0-9_.]+$ ]] \
	|| die "DECK_TITLE '$DECK_TITLE' is invalid: letters, digits, _ and . only, no hyphens"

# user:// on the Deck. Godot names it after config/name unless the project opts
# into a custom user dir name.
if [ -n "$DECK_USER_DIR" ]; then
	USER_DIR="$DECK_USER_DIR"
else
	_udir="$APP_NAME"
	if [ "$(project_setting config/use_custom_user_dir)" = "true" ]; then
		_custom="$(project_setting config/custom_user_dir_name)"
		[ -n "$_custom" ] && _udir="$_custom"
	fi
	[ -n "$_udir" ] || die "cannot derive the Deck-side user:// folder: set DECK_USER_DIR in $ENV_FILE"
	USER_DIR='$HOME/.local/share/godot/app_userdata/'"$_udir"
	unset _udir _custom
fi

# -4: mDNS can hand ssh an IPv6 link-local address, which breaks $SSH_CLIENT
# for --debugger and can flip host keys between runs.
SSH_OPTS=(-4 -o BatchMode=yes -o ConnectTimeout=8)
TARGET="$DECK_USER@$DECK_HOST"

# Run a command on the Deck. The command is a single string for the remote shell.
# MSYS_NO_PATHCONV stops Git Bash rewriting /home/deck/... inside that string
# into C:\Program Files\Git\home\...; it is scoped here on purpose, since Godot
# and scp need the normal /c/... -> C:\... conversion for LOCAL paths.
deck() { MSYS_NO_PATHCONV=1 ssh "${SSH_OPTS[@]}" "$TARGET" "$1"; }
deck_run() {
	if [ "$DRY_RUN" -eq 1 ]; then show_cmd ssh "$TARGET" "$1"; return 0; fi
	deck "$1"
}

# Where the title lives on the Deck. steamos-prepare-upload is the authority
# and overwrites this; the guess covers --launch / --doctor, which skip it.
REMOTE_DIR_ABS="/home/$DECK_USER/devkit-game/$DECK_TITLE"

# Matches every process of the launched title (Steam's reaper, the
# pressure-vessel wrappers and the game itself all carry the path).
# The leading [d] is deliberate: pgrep/pkill -f scan every command line
# including the remote shell running them, and the regex "[d]evkit" matches
# "devkit" in the game's argv but not the literal "[d]evkit" in that shell's.
PROC_PATTERN="[d]evkit-game/$DECK_TITLE/"

# --- export_presets.cfg ----------------------------------------------------

preset_field() {
	awk -v want="$1" -v key="$2" '
		/^\[preset\.[0-9]+\]$/ { inblock = 1; name = ""; next }
		/^\[/ { inblock = 0 }
		inblock && /^name=/ { v = $0; sub(/^name="/, "", v); sub(/"$/, "", v); name = v }
		inblock && name == want && index($0, key "=") == 1 {
			v = substr($0, length(key) + 2); sub(/^"/, "", v); sub(/"$/, "", v); print v; exit
		}
	' "$PRESETS_CFG"
}

normalize_path() {
	local part out=() IFS=/
	# shellcheck disable=SC2206
	local parts=($1)
	for part in ${parts[@]+"${parts[@]}"}; do
		case "$part" in ''|.) ;; ..) [ ${#out[@]} -gt 0 ] && unset 'out[-1]' ;; *) out+=("$part") ;; esac
	done
	printf '/%s' "${out[*]}"
}

export_dir() {
	local raw; raw="$(preset_field "$EXPORT_PRESET" "export_path")"
	[ -n "$raw" ] || return 1
	normalize_path "$PROJECT_DIR/$(dirname "$raw")"
}
export_basename() { basename "$(preset_field "$EXPORT_PRESET" "export_path")"; }

# Matches only the game binary itself (command line starts with its path), so
# a pid reported to the user is the game, not Steam's reaper.
bin_pattern() { printf '^%s/%s' "${REMOTE_DIR_ABS/devkit-game/[d]evkit-game}" "$(export_basename)"; }

# --- Debug host --------------------------------------------------------------

is_ipv4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }

resolve_debug_host() {
	if [ -n "$DEBUGGER_HOST_OVERRIDE" ]; then printf '%s' "$DEBUGGER_HOST_OVERRIDE"; return 0; fi
	if [ -n "$DEBUG_HOST" ]; then printf '%s' "$DEBUG_HOST"; return 0; fi
	# Autodetect asks the Deck which address it sees us on; a dry run must not
	# dial anything, so it shows a placeholder instead.
	if [ "$DRY_RUN" -eq 1 ]; then printf '%s' '<autodetected-from-SSH_CLIENT>'; return 0; fi
	local addr
	addr="$(deck 'echo $SSH_CLIENT' 2>/dev/null | awk '{print $1}' | tr -d '\r\n' || true)"
	is_ipv4 "${addr:-}" || { warn "autodetected debug host '${addr:-none}' is not IPv4; pass --debugger=HOST or set DEBUG_HOST"; return 1; }
	printf '%s' "$addr"
}

# --- Steps -------------------------------------------------------------------

do_export() {
	local outdir outfile flag
	outdir="$(export_dir)" || die "cannot resolve export path for preset '$EXPORT_PRESET' in $PRESETS_CFG"
	outfile="$outdir/$(export_basename)"
	if [ "$BUILD_MODE" = "release" ]; then flag="--export-release"; else flag="--export-debug"; fi

	step "Exporting '$EXPORT_PRESET' ($BUILD_MODE)"
	local before=""; [ -f "$outfile" ] && before="$(stat -c '%Y:%s' "$outfile" 2>/dev/null || true)"

	# Wipe so debug/release GDExtension .so files do not pile up and get synced.
	if [ -d "$outdir" ]; then
		case "$outdir" in
			"$BUILDS_DIR"/*) run rm -rf -- "$outdir" ;;
			*) warn "refusing to wipe '$outdir' (outside $BUILDS_DIR/; set BUILDS_DIR in $ENV_FILE)" ;;
		esac
	fi
	run mkdir -p "$outdir"

	# Godot prints a progress line per packed file ("[ 42% ] savepack | ...",
	# with ANSI colour codes around the stage name even when headless) plus a
	# bare colour-reset line after each stage; drop those, keep everything else
	# (errors, plugin output). Colour codes are stripped when stdout is not a
	# terminal (SteamRoller's log). PIPESTATUS[0] is Godot's real exit code; the
	# `|| true` only stops grep's "no lines left" status tripping pipefail.
	godot_export() {
		"$GODOT_BIN" --headless --path "$PROJECT_DIR" "$flag" "$EXPORT_PRESET" 2>&1 \
			| { grep -v -E $'^\\[ *[0-9]+% \\] |^(\x1b\\[[0-9;]*m)*\r?$' || true; } \
			| if [ -t 1 ]; then cat; else sed $'s/\x1b\\[[0-9;]*m//g'; fi
		return "${PIPESTATUS[0]}"
	}

	local ec=0
	if [ "$DRY_RUN" -eq 1 ]; then
		show_cmd "$GODOT_BIN" --headless --path "$PROJECT_DIR" "$flag" "$EXPORT_PRESET"
		return 0
	fi
	godot_export || ec=$?
	if [ "$ec" -ne 0 ]; then
		warn "export exited $ec; retrying once"
		ec=0; godot_export || ec=$?
		[ "$ec" -eq 0 ] || die "export failed (exit $ec) -- see Godot's output above"
	fi

	[ -s "$outfile" ] || die "export produced no usable file: $outfile"
	local after; after="$(stat -c '%Y:%s' "$outfile" 2>/dev/null || true)"
	[ -n "$before" ] && [ "$before" = "$after" ] && die "export left '$outfile' unchanged -- it silently wrote nothing"
	local pck="$outdir/$(basename "${outfile%.*}").pck"
	[ -f "$pck" ] && info "$(basename "$pck") ($(du -h "$pck" | cut -f1))"
	info "$(basename "$outfile") ($(du -h "$outfile" | cut -f1))"
}

# --no-export: refuse before touching the Deck if there is nothing to push,
# so a running instance is not killed for nothing.
require_build() {
	[ "$DRY_RUN" -eq 1 ] && return 0
	local outdir; outdir="$(export_dir)" || die "cannot resolve export path for preset '$EXPORT_PRESET' in $PRESETS_CFG"
	[ -s "$outdir/$(export_basename)" ] || die "no build in $outdir -- run without --no-export first"
}

# --launch: the title must already be on the Deck (a full deploy creates it).
require_title_on_deck() {
	[ "$DRY_RUN" -eq 1 ] && return 0
	local rc=0
	deck "test -d $(sq "$REMOTE_DIR_ABS")" 2>/dev/null || rc=$?
	case "$rc" in
		0) ;;
		1) die "title '$DECK_TITLE' is not on the Deck ($REMOTE_DIR_ABS missing) -- run a full deploy first" ;;
		*) die "cannot reach $TARGET (ssh exit $rc)" ;;
	esac
}

# Kill any running instance so scp never replaces a file Steam has open.
# "Not running" is fine; an unreachable Deck or a process that will not die is not.
do_stop() {
	local quiet="${1:-0}"
	[ "$quiet" -eq 1 ] || step "Stopping $DECK_TITLE on the Deck"
	if [ "$DRY_RUN" -eq 1 ]; then
		show_cmd ssh "$TARGET" "pgrep -f '$PROC_PATTERN' && pkill -f '$PROC_PATTERN'"; return 0
	fi
	local out rc=0
	# pgrep exits 1 when nothing matches; `|| true` keeps that from looking like
	# an ssh failure. Anything non-zero here is therefore ssh itself.
	out="$(deck "pgrep -f $(sq "$PROC_PATTERN") || true" 2>&1)" || rc=$?
	[ "$rc" -eq 0 ] || die "cannot reach $TARGET to check for a running instance (ssh exit $rc): $out"
	if [ -z "$out" ]; then
		[ "$quiet" -eq 1 ] || info "Game not running"
		return 0
	fi
	local pids; pids="$(printf '%s' "$out" | tr '\n' ' ')"; pids="${pids% }"
	# TERM, wait up to 10 s, then KILL; fail loudly if anything survives.
	deck "pkill -f $(sq "$PROC_PATTERN"); for i in \$(seq 20); do pgrep -f $(sq "$PROC_PATTERN") >/dev/null || exit 0; sleep 0.5; done; pkill -9 -f $(sq "$PROC_PATTERN"); sleep 0.5; ! pgrep -f $(sq "$PROC_PATTERN") >/dev/null" \
		|| die "could not stop $DECK_TITLE on the Deck (pids $pids still alive)"
	info "Game exited (killed pid $pids)"
}

do_prepare() {
	# Creates ~/devkit-game/<TITLE>/ and reports its absolute path.
	step "Preparing $DECK_TITLE on $DECK_HOST"
	if [ "$DRY_RUN" -eq 1 ]; then
		show_cmd ssh "$TARGET" "python3 ~/devkit-utils/steamos-prepare-upload --gameid $DECK_TITLE --restart-steam 0"
		return 0
	fi
	local out rc=0
	out="$(deck "python3 ~/devkit-utils/steamos-prepare-upload --gameid $DECK_TITLE --restart-steam 0" 2>&1)" || rc=$?
	[ "$rc" -eq 0 ] || die "steamos-prepare-upload failed (exit $rc): $(tail -n 3 <<<"$out" | tr '\n' ' ') -- is ~/devkit-utils on the Deck? (pair once with the devkit client)"
	local dir; dir="$(sed -n 's/.*"directory": *"\([^"]*\)".*/\1/p' <<<"$out" | tail -n 1)"
	[ -n "$dir" ] || die "could not parse \"directory\" from steamos-prepare-upload output: $out"
	REMOTE_DIR_ABS="$dir"
	info "$REMOTE_DIR_ABS"
}

do_sync() {
	local outdir; outdir="$(export_dir)" || die "cannot resolve export path for preset '$EXPORT_PRESET'"
	step "Syncing to $TARGET:$REMOTE_DIR_ABS"

	local files=() f
	if [ -d "$outdir" ]; then
		while IFS= read -r f; do files+=("$(basename "$f")"); done < <(
			find "$outdir" -maxdepth 1 -type f ! -name '*.exe' ! -name '*.dll' | sort)
	fi
	if [ ${#files[@]} -eq 0 ]; then
		[ "$DRY_RUN" -eq 1 ] || die "nothing to sync in $outdir -- run an export first"
		local bn; bn="$(export_basename)"; files=("$bn" "${bn%.*}.pck")
		info "(export not run; showing expected file set)"
	fi
	local qfiles=""
	for f in "${files[@]}"; do qfiles+=" $(sq "$f")"; done

	# One round trip for every remote hash. Windows OpenSSH has no ControlMaster.
	declare -A remote_hash=()
	if [ "$DRY_RUN" -eq 1 ]; then
		show_cmd ssh "$TARGET" "cd $(sq "$REMOTE_DIR_ABS") && sha256sum --$qfiles"
	else
		local h n
		# Missing files (first deploy) simply produce no hash -> they get sent.
		while read -r h n; do [ -n "${h:-}" ] && remote_hash["$n"]="$h"; done < <(
			deck "cd $(sq "$REMOTE_DIR_ABS") 2>/dev/null && sha256sum --$qfiles 2>/dev/null" || true)
	fi

	local sent=0 skipped=0
	for f in "${files[@]}"; do
		local lh=""
		[ "$DRY_RUN" -eq 0 ] && lh="$(sha256sum "$outdir/$f" | awk '{print $1}')"
		if [ "$DRY_RUN" -eq 0 ] && [ "${remote_hash[$f]:-}" = "$lh" ]; then
			printf '      %sskip%s  %s\n' "$C_DIM" "$C_RESET" "$f"; skipped=$((skipped + 1)); continue
		fi
		printf '      send  %s (%s)\n' "$f" "$(du -h "$outdir/$f" 2>/dev/null | cut -f1 || echo '?')"
		run scp -q "${SSH_OPTS[@]}" "$outdir/$f" "$TARGET:$REMOTE_DIR_ABS/" \
			|| die "scp of $f to $TARGET:$REMOTE_DIR_ABS/ failed"
		sent=$((sent + 1))
	done

	# Prune so the Deck mirrors builds/ (the devkit GUI's "Delete extraneous remote files").
	if [ "$DRY_RUN" -eq 1 ]; then
		show_cmd ssh "$TARGET" "cd $(sq "$REMOTE_DIR_ABS") && find . -maxdepth 1 -type f -printf '%P\n'"
		info "(then rm -f every remote file not in the set above)"
	else
		local keep remote_list stale=() rf
		keep="$(printf '%s\n' "${files[@]}")"
		remote_list="$(deck "cd $(sq "$REMOTE_DIR_ABS") 2>/dev/null && find . -maxdepth 1 -type f -printf '%P\n'" 2>/dev/null || true)"
		while IFS= read -r rf; do
			[ -n "$rf" ] || continue
			grep -qxF -- "$rf" <<<"$keep" || stale+=("$rf")
		done <<<"$remote_list"
		if [ ${#stale[@]} -gt 0 ]; then
			local quoted=""
			for rf in "${stale[@]}"; do
				printf '      %sprune%s %s\n' "$C_YELLOW" "$C_RESET" "$rf"; quoted+=" $(sq "$rf")"
			done
			deck "cd $(sq "$REMOTE_DIR_ABS") && rm -f --$quoted" || die "could not prune stale files on the Deck"
		fi
	fi

	deck_run "cd $(sq "$REMOTE_DIR_ABS") && chmod +x $(sq "$(export_basename)") 2>/dev/null; chmod +x ./*.sh 2>/dev/null; true"
	info "$sent sent, $skipped unchanged"
}

# Build the argv string Steam will split, and re-register the shortcut.
# This is what the devkit GUI does on every Upload; it is one round trip and
# it is the only way the start command (e.g. --remote-debug) ever changes.
do_register() {
	local argv; argv="$(export_basename)"
	if [ "$USE_DEBUGGER" -eq 1 ]; then
		local dhost; dhost="$(resolve_debug_host)" || die "--debugger: could not determine this workstation's address"
		argv+=" --remote-debug tcp://$dhost:$DEBUG_PORT"
		step "Debugger target: $dhost:$DEBUG_PORT (editor needs Debug > Keep Debug Server Open)"
	fi
	local a
	for a in ${GAME_ARGS[@]+"${GAME_ARGS[@]}"}; do argv+=" $a"; done

	local settings='{"steam_play": "0"'
	[ -n "$DECK_RUNTIME" ] && settings+=', "compat_tool": "'"$DECK_RUNTIME"'"'
	settings+='}'
	# "env" is mandatory: steam-client-create-shortcut indexes parms['env']
	# unconditionally and dies with KeyError without it. Empty = no env vars.
	local parms='{"gameid": "'"$DECK_TITLE"'", "directory": "'"$REMOTE_DIR_ABS"'", "argv": ["'"$(json_str "$argv")"'"], "env": {}, "settings": '"$settings"'}'
	local cmd="python3 ~/devkit-utils/steam-client-create-shortcut --parms $(sq "$parms")"

	step "Registering '$argv' with Steam (${DECK_RUNTIME:-native})"
	if [ "$DRY_RUN" -eq 1 ]; then show_cmd ssh "$TARGET" "$cmd"; return 0; fi
	# The tool logs to stderr and prints one JSON line to stdout at the end.
	local out rc=0
	out="$(deck "$cmd" 2>&1)" || rc=$?
	local last; last="$(tail -n 1 <<<"$out")"
	case "$last" in
		*'"success"'*) info "registered" ;;
		*'"error"'*)   die "shortcut registration failed: $last (is Steam running on the Deck?)" ;;
		*)             die "steam-client-create-shortcut failed (exit $rc): $(tail -n 4 <<<"$out" | tr '\n' ' ')" ;;
	esac
}

do_clean_cache() {
	step "Clearing Deck-side user:// (cold shader cache)"
	if [ "$DRY_RUN" -eq 1 ]; then show_cmd ssh "$TARGET" "rm -rf \"$USER_DIR\""; return 0; fi
	deck "rm -rf \"$USER_DIR\" && test ! -e \"$USER_DIR\"" || die "could not remove $USER_DIR on the Deck"
	info "removed $USER_DIR"
}

do_launch() {
	step "Launching $DECK_TITLE through Steam"
	if [ "$DRY_RUN" -eq 1 ]; then
		show_cmd ssh "$TARGET" "python3 ~/devkit-utils/steam-devkit-rpc run-game gameid=$DECK_TITLE"; return 0
	fi
	local out rc=0
	out="$(deck "python3 ~/devkit-utils/steam-devkit-rpc run-game gameid=$DECK_TITLE" 2>&1)" || rc=$?
	[ "$rc" -eq 0 ] || die "run-game failed (exit $rc): $(tail -n 3 <<<"$out" | tr '\n' ' ') (is Steam running on the Deck?)"
	# Steam accepts the request and starts the runtime asynchronously; wait
	# for the actual game binary so "started" means started.
	local pid
	pid="$(deck "for i in \$(seq 60); do p=\$(pgrep -f $(sq "$(bin_pattern)") | head -n 1); [ -n \"\$p\" ] && { echo \"\$p\"; exit 0; }; sleep 0.5; done; exit 1" 2>/dev/null)" \
		|| die "Steam accepted run-game but no $DECK_TITLE process appeared within 30 s (check the Deck screen / Steam library)"
	info "Game started (pid $pid)"
	if [ "$DO_TAIL" -eq 1 ]; then
		step "Following user://logs/godot.log (Ctrl-C to stop following; the game keeps running)"
		deck "sleep 2; tail -n +1 -F \"$USER_DIR/logs/godot.log\"" || true
	fi
}

# --- Doctor ------------------------------------------------------------------

doctor() {
	local fails=0
	ok()  { printf '%sPASS%s  %s\n' "$C_GREEN" "$C_RESET" "$1"; }
	bad() { printf '%sFAIL%s  %s\n      remedy: %s\n' "$C_RED" "$C_RESET" "$1" "$2"; fails=$((fails + 1)); }
	note() { printf '%sINFO%s  %s\n' "$C_DIM" "$C_RESET" "$1"; }

	step "Preflight"; printf '\n'
	if [ -n "$GODOT_BIN" ] && [ -x "$GODOT_BIN" ]; then
		ok "Godot: $("$GODOT_BIN" --version 2>/dev/null | tail -n 1 | tr -d '\r')"
	else
		bad "GODOT_BIN not executable: ${GODOT_BIN:-<unset>}" "set it in $ENV_FILE"
	fi
	if [ -f "$PRESETS_CFG" ] && [ -n "$(preset_field "$EXPORT_PRESET" "export_path")" ]; then
		ok "preset '$EXPORT_PRESET' -> $(export_dir)/$(export_basename)"
	else
		bad "preset '$EXPORT_PRESET' not found in $PRESETS_CFG" "create it in Project > Export"
	fi
	if deck true 2>/dev/null; then ok "ssh $TARGET (IPv4, key auth)"; else
		bad "cannot ssh to $TARGET non-interactively" "ssh-copy-id $TARGET; check the Deck is on"; printf '\n'; die "$fails check(s) failed"; fi
	if deck "test -x ~/devkit-utils/steam-devkit-rpc && test -x ~/devkit-utils/steam-client-create-shortcut && command -v python3 >/dev/null" 2>/dev/null; then
		ok "devkit tools present in ~/devkit-utils"; else
		bad "~/devkit-utils (or python3) missing on the Deck" "pair the Deck with the SteamOS Devkit Client once (Register)"; fi
	if deck "test -r ~/.steam/steam.pipe && kill -0 \$(cat ~/.steam/steam.pid) 2>/dev/null" 2>/dev/null; then ok "Steam client running on the Deck"; else
		bad "Steam client not running on the Deck" "Deck must be logged into Steam (Game Mode or Desktop Mode both work)"; fi
	if deck "test -d $(sq "$REMOTE_DIR_ABS")" 2>/dev/null; then
		ok "title '$DECK_TITLE' exists on the Deck ($REMOTE_DIR_ABS)"
		local argv; argv="$(deck "cat ~/devkit-game/$DECK_TITLE-argv.json 2>/dev/null" 2>/dev/null | tr -d '\r\n' || true)"
		note "registered argv: ${argv:-<none yet>}"
		local running; running="$(deck "pgrep -f $(sq "$(bin_pattern)") | head -n 1" 2>/dev/null || true)"
		if [ -n "$running" ]; then note "game is running (pid $running)"; else note "game is not running"; fi
	else
		note "title not yet on the Deck; first deploy creates it"
	fi
	if [ "$USE_DEBUGGER" -eq 1 ]; then
		local dhost; dhost="$(resolve_debug_host || true)"
		if [ -n "$dhost" ]; then
			local probe; probe="$(deck "timeout 3 bash -c '</dev/tcp/$dhost/$DEBUG_PORT' 2>/dev/null && echo OPEN || echo CLOSED" 2>/dev/null || echo UNKNOWN)"
			if [ "$probe" = "OPEN" ]; then ok "Deck reaches $dhost:$DEBUG_PORT (editor debug server)"; else
				# Not a failure: the port is only open while the editor is up with
				# Debug > Keep Debug Server Open, which is normal when not debugging.
				warn "Deck cannot reach $dhost:$DEBUG_PORT ($probe) -- editor: Debug > Keep Debug Server Open; Windows firewall: allow Godot on TCP $DEBUG_PORT"; fi
		else
			bad "cannot determine debug host" "pass --debugger=HOST or set DEBUG_HOST"
		fi
	fi
	printf '\n'
	[ "$fails" -eq 0 ] || die "$fails check(s) failed"
	step "All checks passed"
}

# --- Main --------------------------------------------------------------------

main() {
	[ "$DRY_RUN" -eq 1 ] && step "DRY RUN -- nothing below is executed"
	case "$MODE" in
		doctor) doctor; return 0 ;;
		stop)   do_stop; return 0 ;;
		launch)
			require_title_on_deck
			do_stop 1
			do_register
			[ "$DO_CLEAN_CACHE" -eq 1 ] && do_clean_cache
			do_launch; return 0 ;;
	esac

	[ -n "$GODOT_BIN" ] && [ -x "$GODOT_BIN" ] || [ "$DO_EXPORT" -eq 0 ] || die "GODOT_BIN not set/executable (see $ENV_FILE)"

	if [ "$DO_EXPORT" -eq 1 ]; then do_export; else require_build; fi
	do_prepare
	do_stop 1
	do_sync
	do_register
	[ "$DO_CLEAN_CACHE" -eq 1 ] && do_clean_cache
	if [ "$DO_LAUNCH" -eq 0 ]; then step "Done (--no-launch)"; return 0; fi
	do_launch
}

main
