#!/usr/bin/env bash
#
# pull_saves.sh -- merge a game's save folders from this machine and the Steam
# Deck into one destination (SteamRoller's "Copy saves").
#
#   pull_saves.sh --dest DIR [--local DIR]... [--deck auto|DIR]... [--exclude PATTERN]...
#                 [--require-deck] [--dry-run] [--env FILE] -- SUBDIR...
#
# Each SUBDIR (say sunsets and photos) of every source folder is merged into
# DEST/SUBDIR, file by file. A file is copied when DEST lacks it or the source's
# copy is newer; a file with the same contents is left alone, whatever its date.
# Sources are never changed.
#
# A conflict is two sources holding different contents under one name in the
# same run (a save edited on both machines between two syncs): the newer copy is
# kept and a "conflict:" line names the file and both sources. A file already in
# DEST from an earlier copy that a source has since changed is an update, not a
# conflict.
#
#   --local DIR       a user data folder on this machine (repeatable; an empty
#                     value is skipped, so an unset variable is harmless, and a
#                     folder given twice is read once)
#   --deck auto       the Deck's user data folders, found as deploy.sh finds them:
#                     DECK_USER_DIR from deck.env, else ~/.local/share/<the
#                     project's custom_user_dir_name> (or godot/app_userdata/
#                     <config/name>); plus the demo export's own folder when
#                     project.godot names one (custom_user_dir_name.demo)
#   --deck DIR        one Deck-side folder ($HOME expands on the Deck)
#   --exclude PATTERN a file name never copied (a shell pattern; repeatable).
#                     Always excluded: steam_autocloud.vdf (Steam Cloud's marker in
#                     every synced folder, not save data) and *.tmp (a save being
#                     written)
#   --require-deck    fail when the Deck cannot be reached (default: warn and copy
#                     this machine's folders only)
#   --dry-run         count what would be copied, conflicts included; copy nothing
#   --env FILE        the Deck's settings (default <project>/data/deck.env:
#                     DECK_HOST, DECK_USER, DECK_USER_DIR; the environment wins)
#
# Exit 0 when done (conflicts and an unreachable Deck included, unless
# --require-deck), 1 on an error. Runs from Git Bash on Windows, or any bash with
# ssh, tar and cmp.

set -Eeuo pipefail
# No console under the SteamRoller dock; give coreutils a real fd 0.
[ -t 0 ] || exec </dev/null

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"; done
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
# deck/ -> steamroller/ -> addons/ -> the project (as deploy.sh).
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
PROJECT_GODOT="$PROJECT_DIR/project.godot"
ENV_FILE="$PROJECT_DIR/data/deck.env"

step() { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
die()  { printf 'ERROR %s\n' "$*" >&2; exit 1; }

# A setting as project.godot writes it (`key="value"`), quotes stripped. The key
# is a sed pattern: escape a literal dot.
project_setting() {
	local v; v="$(sed -n "s|^$1=||p" "$PROJECT_GODOT" 2>/dev/null | head -n 1 | tr -d '\r')"
	v="${v#\"}"; v="${v%\"}"; printf '%s' "$v"
}

# A Windows path (C:/... or C:\...) as Git Bash sees it; other paths unchanged.
to_posix() {
	if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
}

DEST=""
LOCALS=()
DECKS=()
SUBDIRS=()
EXCLUDES=("steam_autocloud.vdf" "*.tmp")
REQUIRE_DECK=0
DRY=0
while [ $# -gt 0 ]; do
	case "$1" in
		--dest)         DEST="${2-}"; shift 2 ;;
		--dest=*)       DEST="${1#*=}"; shift ;;
		--local)        LOCALS+=("${2-}"); shift 2 ;;
		--local=*)      LOCALS+=("${1#*=}"); shift ;;
		--deck)         DECKS+=("${2-}"); shift 2 ;;
		--deck=*)       DECKS+=("${1#*=}"); shift ;;
		--exclude)      EXCLUDES+=("${2-}"); shift 2 ;;
		--exclude=*)    EXCLUDES+=("${1#*=}"); shift ;;
		--require-deck) REQUIRE_DECK=1; shift ;;
		--dry-run)      DRY=1; shift ;;
		--env)          ENV_FILE="${2-}"; shift 2 ;;
		--env=*)        ENV_FILE="${1#*=}"; shift ;;
		-h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
		--)             shift; SUBDIRS=("$@"); break ;;
		*)              die "unknown argument: $1 (--help)" ;;
	esac
done
[ -n "$DEST" ] || die "--dest is required (--help)"
[ "${#SUBDIRS[@]}" -gt 0 ] || die "name the folders to copy after --, e.g. -- sunsets photos"
DEST="$(to_posix "$DEST")"
DEST="${DEST%/}"

# The Deck: environment > deck.env > defaults (deploy.sh's precedence).
declare -A _env=()
for _v in DECK_HOST DECK_USER DECK_USER_DIR; do [ -n "${!_v+x}" ] && _env[$_v]="${!_v}"; done
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
for _v in "${!_env[@]}"; do printf -v "$_v" '%s' "${_env[$_v]}"; done
TARGET="${DECK_USER:-deck}@${DECK_HOST:-steamdeck.local}"
SSH_OPTS=(-4 -o BatchMode=yes -o ConnectTimeout=8)
# MSYS_NO_PATHCONV keeps Git Bash from rewriting /home/... in the remote command.
deck() { MSYS_NO_PATHCONV=1 ssh "${SSH_OPTS[@]}" "$TARGET" "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# This run's writes: destination file -> the source file it came from, and that
# source's name. A later source holding different contents is a conflict.
declare -A FROM=()
declare -A FROM_LABEL=()
COPIED=0; SAME=0; NEWER=0; SKIPPED=0; CONFLICTS=0; ALL_CONFLICTS=0

excluded() {
	local pattern
	for pattern in "${EXCLUDES[@]}"; do
		# shellcheck disable=SC2254
		case "$1" in $pattern) return 0 ;; esac
	done
	return 1
}

# Take `src` as the copy of `dst` this run (copied unless --dry-run, or unless
# the destination already holds the same contents).
take() {
	local src="$1" dst="$2" label="$3"
	FROM["$dst"]="$src"
	FROM_LABEL["$dst"]="$label"
	if [ -e "$dst" ] && cmp -s "$src" "$dst"; then
		SAME=$((SAME + 1))
		return
	fi
	if [ "$DRY" -eq 0 ]; then
		mkdir -p "$(dirname "$dst")"
		cp -p "$src" "$dst"
	fi
	COPIED=$((COPIED + 1))
}

# merge ROOT SUBDIR LABEL: ROOT/SUBDIR into DEST/SUBDIR, file by file.
merge() {
	local root="$1" sub="$2" label="$3" f rel dst earlier
	[ -d "$root/$sub" ] || return 0
	while IFS= read -r -d '' f; do
		rel="${f#"$root"/}"
		if excluded "${rel##*/}"; then
			SKIPPED=$((SKIPPED + 1))
			continue
		fi
		dst="$DEST/$rel"
		earlier="${FROM[$dst]:-}"
		if [ -n "$earlier" ]; then
			# Another source gave this file earlier in the run.
			if cmp -s "$f" "$earlier"; then
				SAME=$((SAME + 1))
			elif [ "$f" -nt "$earlier" ]; then
				warn "conflict: $rel differs between ${FROM_LABEL[$dst]} and $label; kept the newer, from $label"
				CONFLICTS=$((CONFLICTS + 1))
				take "$f" "$dst" "$label"
			else
				warn "conflict: $rel differs between ${FROM_LABEL[$dst]} and $label; kept the newer, from ${FROM_LABEL[$dst]}"
				CONFLICTS=$((CONFLICTS + 1))
			fi
		elif [ ! -e "$dst" ]; then
			take "$f" "$dst" "$label"
		elif cmp -s "$f" "$dst"; then
			SAME=$((SAME + 1))
			FROM["$dst"]="$f"
			FROM_LABEL["$dst"]="$label"
		elif [ "$f" -nt "$dst" ]; then
			take "$f" "$dst" "$label"   # changed since an earlier copy: an update
		else
			# Kept; and remembered, so a later source that disagrees with this one
			# is reported as the conflict it is.
			NEWER=$((NEWER + 1))
			FROM["$dst"]="$f"
			FROM_LABEL["$dst"]="$label"
		fi
	done < <(find "$root/$sub" -type f -print0)
}

summary() {   # summary LABEL
	local verb="copied"
	[ "$DRY" -eq 1 ] && verb="to copy"
	step "$1: $COPIED $verb, $SAME already there, $NEWER newer in the destination$([ "$CONFLICTS" -gt 0 ] && printf ', %d conflict(s)' "$CONFLICTS")$([ "$SKIPPED" -gt 0 ] && printf ', %d skipped' "$SKIPPED")"
	ALL_CONFLICTS=$((ALL_CONFLICTS + CONFLICTS))
	COPIED=0; SAME=0; NEWER=0; SKIPPED=0; CONFLICTS=0
}

step "Copying ${SUBDIRS[*]} into $DEST$([ "$DRY" -eq 1 ] && printf ' (dry run)')"

# --- This machine --------------------------------------------------------------

declare -A LOCAL_SEEN=()
for dir in "${LOCALS[@]}"; do
	[ -n "$dir" ] || continue
	root="$(to_posix "$dir")"
	root="${root%/}"
	[ -z "${LOCAL_SEEN[$root]:-}" ] || continue   # the same folder twice: once
	LOCAL_SEEN["$root"]=1
	if [ ! -d "$root" ]; then
		info "This PC: no folder $dir, skipped"
		continue
	fi
	label="this PC's $(basename "$root")"
	for sub in "${SUBDIRS[@]}"; do merge "$root" "$sub" "$label"; done
	summary "This PC, $(basename "$root")"
done

# --- The Deck ------------------------------------------------------------------

# The Deck-side folders --deck auto stands for, one per line ($HOME literal).
deck_auto_dirs() {
	local custom demo
	if [ -n "${DECK_USER_DIR:-}" ]; then
		printf '%s\n' "$DECK_USER_DIR"
	elif [ "$(project_setting config/use_custom_user_dir)" = "true" ] \
			&& custom="$(project_setting config/custom_user_dir_name)" && [ -n "$custom" ]; then
		printf '%s\n' "\$HOME/.local/share/$custom"
	else
		printf '%s\n' "\$HOME/.local/share/godot/app_userdata/$(project_setting config/name)"
	fi
	demo="$(project_setting 'config/custom_user_dir_name\.demo')"
	if [ -n "$demo" ]; then printf '%s\n' "\$HOME/.local/share/$demo"; fi
}

if [ "${#DECKS[@]}" -gt 0 ]; then
	if ! deck true 2>"$TMP/ssh.err"; then
		reason="$(head -n 1 "$TMP/ssh.err" | tr -d '\r')"
		[ "$REQUIRE_DECK" -eq 1 ] && die "cannot reach the Deck ($TARGET): ${reason:-ssh failed}"
		warn "cannot reach the Deck ($TARGET): ${reason:-ssh failed}. Copied this PC's saves only."
	else
		n=0
		for spec in "${DECKS[@]}"; do
			[ -n "$spec" ] || continue
			if [ "$spec" = "auto" ]; then mapfile -t dirs < <(deck_auto_dirs); else dirs=("$spec"); fi
			for rdir in "${dirs[@]}"; do
				present=()
				for sub in "${SUBDIRS[@]}"; do
					if deck "[ -d \"$rdir/$sub\" ]"; then present+=("$sub"); fi
				done
				shown="${rdir/\$HOME/\~}"
				if [ "${#present[@]}" -eq 0 ]; then
					info "Deck: nothing to copy in $shown"
					continue
				fi
				n=$((n + 1))
				work="$TMP/deck$n"
				mkdir -p "$work"
				# tar keeps the Deck's file times, which the newest-wins rule reads.
				deck "tar -C \"$rdir\" -cf - ${present[*]}" | tar -C "$work" -xf -
				for sub in "${present[@]}"; do merge "$work" "$sub" "the Deck's $(basename "$shown")"; done
				summary "Deck, $shown"
			done
		done
	fi
fi
if [ "$ALL_CONFLICTS" -gt 0 ]; then
	warn "$ALL_CONFLICTS file(s) differed between sources (named above): the newer copy of each was kept."
fi
step "Done."
