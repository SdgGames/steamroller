#!/usr/bin/env bash
#
# bench.sh -- run an exported build with --bench three ways and print the
# average frame time of each: Windows Vulkan, Windows D3D12 (one after the
# other, a smoke test) and the Steam Deck (in parallel, the number that matters).
#
#   bench.sh <windows exe> [linux preset] [results file]
#     preset default Linux_Final; results file default <exe dir>/../benchmark.txt
#     (i.e. builds/latest/benchmark.txt: archived with the build, not in the depot)
#
# Contract with the game: started with `--bench` it prints one line starting
# with "BENCHMARK" (whatever fields it likes) and quits. `--benchmark` is taken
# by the engine itself, hence the short name.
#
# The Deck side is deploy.sh: the preset's export folder is pushed as-is
# (--no-export), the game is launched through Steam with --bench, and its
# user://logs/godot.log is followed until it exits. Config: data/deck.env.
#
# Windows output is captured from stdout; a GUI Godot exe writes to an
# inherited redirect. Every run is wrapped in `timeout` so a hung game cannot
# hold the SteamRoller dock forever.
#
# Every run APPENDS a block to the results file: a `# <date> version=<v>`
# header, then one `<label> key=value ...` line per run (FAILED when there was
# no result). Plain text, but regular enough to turn into a CSV later.

set -Eeuo pipefail

# No console under the SteamRoller dock; give coreutils a real fd 0.
[ -t 0 ] || exec </dev/null

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"; done
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
DEPLOY="$SCRIPT_DIR/deploy.sh"
# deck/ -> steamroller/ -> addons/ -> the project (same as deploy.sh).
PROJECT_GODOT="$SCRIPT_DIR/../../../project.godot"

WIN_EXE="${1:-}"
PRESET="${2:-Linux_Final}"
RESULTS="${3:-}"
TIMEOUT="${BENCH_TIMEOUT:-300}"
MARKER="BENCHMARK"
GAME_FLAG="--bench"

# --- Output ----------------------------------------------------------------

if [ -t 1 ]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'
else
	C_RESET=""; C_BOLD=""; C_RED=""; C_YELLOW=""; C_DIM=""
fi
step() { printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
info() { printf '      %s\n' "$*"; }
warn() { printf '%sWARN%s  %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
trap 'rc=$?; printf "%sERROR%s command failed (exit %s) at line %s: %s\n" "$C_RED" "$C_RESET" "$rc" "$LINENO" "$BASH_COMMAND" >&2; exit "$rc"' ERR

[ -n "$WIN_EXE" ] || die "usage: bench.sh <windows exe> [linux preset] [results file]"
[ -x "$WIN_EXE" ] || die "no Windows build at $WIN_EXE -- export first"
[ -f "$DEPLOY" ] || die "deploy.sh not found next to bench.sh ($DEPLOY)"
[ -n "$RESULTS" ] || RESULTS="$(cd -- "$(dirname -- "$WIN_EXE")/.." && pwd)/benchmark.txt"
VERSION="$(sed -n 's|^config/version=||p' "$PROJECT_GODOT" 2>/dev/null | head -n 1 | tr -d '"\r')"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Deck, in the background -------------------------------------------------

step "Deck: pushing '$PRESET' and running with $GAME_FLAG (in the background)"
(
	EXPORT_PRESET="$PRESET" timeout -k 10 "$TIMEOUT" \
		bash "$DEPLOY" --no-export --tail --run "$GAME_FLAG"
) > "$TMP/deck.log" 2>&1 &
DECK_JOB=$!

# --- Windows, one at a time --------------------------------------------------

run_windows() { # <name> [engine args...]
	local name="$1"; shift
	step "Windows ($name): $(basename "$WIN_EXE") $* $GAME_FLAG"
	local rc=0
	timeout -k 10 "$TIMEOUT" "$WIN_EXE" "$@" "$GAME_FLAG" > "$TMP/$name.log" 2>&1 || rc=$?
	if [ "$rc" -eq 0 ]; then info "exited 0"; else warn "windows/$name exited $rc"; fi
}
run_windows vulkan
run_windows d3d12 --rendering-driver d3d12

# --- Collect ---------------------------------------------------------------

step "Waiting for the Deck run"
DECK_RC=0
wait "$DECK_JOB" || DECK_RC=$?
# deploy.sh's own step lines (==> / indented) on success; the whole thing,
# game log included, when the run failed, so the dock console shows why.
if [ "$DECK_RC" -eq 0 ] && grep -q "^$MARKER" "$TMP/deck.log"; then
	grep -E '^(==>|      )' "$TMP/deck.log" | sed "s/^/      $C_DIM/; s/\$/$C_RESET/"
else
	sed "s/^/      $C_DIM/; s/\$/$C_RESET/" "$TMP/deck.log"
	warn "deck run exited $DECK_RC"
fi

step "Results"
# One dated block per run, appended; a blank line separates blocks.
{
	[ -s "$RESULTS" ] && printf '\n'
	printf '# %s version=%s build=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${VERSION:-?}" "$(dirname -- "$WIN_EXE")"
} >> "$RESULTS" || die "cannot write $RESULTS"

fails=0
result() { # <label> <log>
	local line
	line="$(grep "^$MARKER" "$2" 2>/dev/null | tail -n 1 | tr -d '\r' || true)"
	if [ -n "$line" ]; then
		printf '      %-16s %s\n' "$1" "${line#"$MARKER"}"
		printf '%-16s%s\n' "$1" "${line#"$MARKER"}" >> "$RESULTS"
	else
		printf '      %-16s %sFAILED%s (no %s line)\n' "$1" "$C_RED" "$C_RESET" "$MARKER"
		printf '%-16s FAILED\n' "$1" >> "$RESULTS"
		fails=$((fails + 1))
		# The Windows logs are otherwise never shown; the tail is the diagnosis.
		if [ "$2" != "$TMP/deck.log" ] && [ -s "$2" ]; then
			tail -n 15 "$2" | tr -d '\r' | sed "s/^/          $C_DIM/; s/\$/$C_RESET/"
		fi
	fi
}
result windows/vulkan "$TMP/vulkan.log"
result windows/d3d12  "$TMP/d3d12.log"
result deck           "$TMP/deck.log"
info "appended to $RESULTS"

[ "$fails" -eq 0 ] || die "$fails run(s) produced no $MARKER line"
step "Done"
