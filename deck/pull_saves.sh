#!/usr/bin/env bash
#
# pull_saves.sh -- merge a game's save folders from this machine and the Steam
# Deck into one destination (SteamRoller's "Copy saves").
#
#   pull_saves.sh --dest DIR [--local DIR]... [--deck auto|DIR]...
#                 [--require-deck] [--dry-run] [--env FILE] -- SUBDIR...
#
# Each SUBDIR (say sunsets and photos) of every source folder is merged into
# DEST/SUBDIR. A file is copied when DEST lacks it or the source's copy is newer;
# a newer file already in DEST is kept. Sources are never changed. With several
# sources holding the same file, the newest copy wins whichever machine wrote it.
#
#   --local DIR     a user data folder on this machine (repeatable; an empty
#                   value is skipped, so an unset variable is harmless)
#   --deck auto     the Deck's user data folders, found as deploy.sh finds them:
#                   DECK_USER_DIR from deck.env, else ~/.local/share/<the
#                   project's custom_user_dir_name> (or godot/app_userdata/
#                   <config/name>); plus the demo export's own folder when
#                   project.godot names one (custom_user_dir_name.demo)
#   --deck DIR      one Deck-side folder ($HOME expands on the Deck)
#   --require-deck  fail when the Deck cannot be reached (default: warn and
#                   copy this machine's folders only)
#   --dry-run       count what would be copied; copy nothing
#   --env FILE      the Deck's settings (default <project>/data/deck.env:
#                   DECK_HOST, DECK_USER, DECK_USER_DIR; the environment wins)
#
# Exit 0 when done (an unreachable Deck included, unless --require-deck), 1 on
# an error. Runs from Git Bash on Windows, or any bash with ssh and tar.

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
warn() { printf 'WARN  %s\n' "$*" >&2; }
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
		--require-deck) REQUIRE_DECK=1; shift ;;
		--dry-run)      DRY=1; shift ;;
		--env)          ENV_FILE="${2-}"; shift 2 ;;
		--env=*)        ENV_FILE="${1#*=}"; shift ;;
		-h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
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

COPIED=0; SAME=0; NEWER=0
# merge ROOT SUBDIR: ROOT/SUBDIR into DEST/SUBDIR, file by file, newest wins.
merge() {
	local root="$1" sub="$2" f rel dst
	[ -d "$root/$sub" ] || return 0
	while IFS= read -r -d '' f; do
		rel="${f#"$root"/}"
		dst="$DEST/$rel"
		if [ ! -e "$dst" ] || [ "$f" -nt "$dst" ]; then
			if [ "$DRY" -eq 0 ]; then
				mkdir -p "$(dirname "$dst")"
				cp -p "$f" "$dst"
			fi
			COPIED=$((COPIED + 1))
		elif [ "$dst" -nt "$f" ]; then
			NEWER=$((NEWER + 1))
		else
			SAME=$((SAME + 1))
		fi
	done < <(find "$root/$sub" -type f -print0)
}

summary() {   # summary LABEL
	local verb="copied"
	[ "$DRY" -eq 1 ] && verb="to copy"
	step "$1: $COPIED $verb, $SAME already there, $NEWER newer in the destination"
	COPIED=0; SAME=0; NEWER=0
}

step "Copying ${SUBDIRS[*]} into $DEST$([ "$DRY" -eq 1 ] && printf ' (dry run)')"

# --- This machine --------------------------------------------------------------

for dir in "${LOCALS[@]}"; do
	[ -n "$dir" ] || continue
	root="$(to_posix "$dir")"
	root="${root%/}"
	if [ ! -d "$root" ]; then
		info "This PC: no folder $dir, skipped"
		continue
	fi
	for sub in "${SUBDIRS[@]}"; do merge "$root" "$sub"; done
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
				if [ "${#present[@]}" -eq 0 ]; then
					info "Deck: nothing to copy in $rdir"
					continue
				fi
				n=$((n + 1))
				work="$TMP/deck$n"
				mkdir -p "$work"
				# tar keeps the Deck's file times, which the newest-wins rule reads.
				deck "tar -C \"$rdir\" -cf - ${present[*]}" | tar -C "$work" -xf -
				for sub in "${present[@]}"; do merge "$work" "$sub"; done
				summary "Deck, ${rdir/\$HOME/\~}"
			done
		done
	fi
fi
step "Done."
