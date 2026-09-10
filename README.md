# SteamRoller

A data-driven build and release checklist for the Godot 4 editor. Define your
workflow as an ordered list of steps in a `.tres` config file; the plugin
renders it as a dockable checklist with per-step consoles and dependency
gating between steps.

Windows-only for now.

## How a step looks

Each step is one `SteamRollerStep` resource with an `action` enum that
determines its behavior. The available actions:

| Action | Behavior |
|---|---|
| `CHECKBOX` | Manual no-op. User ticks it when done. |
| `NEW_TAB` | Divider. Steps after it appear in a new tab named `tab_name`. |
| `INPUT` | LineEdit bound to a project setting. The field is the completion state. |
| `RUN_GDUNIT` | Run all GdUnit4 tests. Disabled if GdUnit isn't installed. |
| `RECORD_MOVIE` | Movie maker + main scene + optional ffmpeg re-encode. |
| `DELETE_FOLDER` | Recursively delete `params.path`. Optionally recreate folders via `params.paths`. |
| `CREATE_FOLDERS` | Create each path in `params.paths`. |
| `ARCHIVE_FOLDER` | Copy `params.source` → `params.destination`. |
| `CLEAR_USER_DATA` | Delete `user://`. |
| `OPEN_IN_EXPLORER` | Reveal `params.path` in the OS file manager. |
| `COPY_TO_CLIPBOARD` | Copy `params.text` to the clipboard. |
| `RESET_AND_INCREMENT` | Reset current tab + bump last numeric segment of version. |
| `RUN_COMMAND` | External process using `executable`, `args`, `working_dir`. Runs without blocking the editor; its captured output is written to a log file and emitted into the step console. |
| `RUN_STEPS` | Run other steps in sequence via `step_ids` (e.g. "Push all"). Output from every child is routed to the console of the row you pressed. |
| `WRITE_VDF_DESC` | Update the `desc` field (and optionally the `setlive` branch) in one or more Valve VDF app-build scripts. `params.files` is an Array of absolute paths; `params.desc` is the string to write; `params.branch` (optional) sets the `setlive` branch. All support variable substitution. |
| `EXPORT_PROJECT` | Export the project headlessly, mirroring the editor's **Export All**: renders an *Export All Debug* and an *Export All Release* button and exports every preset in `export_presets.cfg` to its own `export_path`. Relaunches the current editor binary with `--headless` and `--export-debug`/`--export-release`. `params.debug` (bool) pins one mode and renders a single button; `params.exports` (Array of `{preset, output}`) overrides the preset list. |
| `RUN_COMMAND_ASYNC` | **Deprecated** — `RUN_COMMAND` no longer blocks either, and additionally captures output and honours `working_dir`. Kept for configs relying on this action's exact contract: no shell, `working_dir` ignored, output only via `params.tail_file` (now tailed incrementally while the process runs, rather than dumped at exit). |

In the panel, each step renders as:

```
[✓] Step name
    Optional BBCode description goes here.
              [ Action button ]
    ▶ Console (0)
─────────────────────────────────────────
```

`INPUT` steps swap the checkbox header for `Label + LineEdit`. Actions with
no button (CHECKBOX, NEW_TAB, INPUT) just show the header and description.

## Installation

1. Copy this folder into your project at `res://addons/steamroller/`.
2. Enable in **Project → Project Settings → Plugins**.
3. Copy `addons/steamroller/templates/default_config.tres` somewhere outside
   the addon (e.g. `res://steamroller_config.tres`).
4. In **Project Settings → General**, set
   `application/steamroller/config_path` to your copy.
5. The dock appears bottom-right. Open the **Start Guide** tab for a full
   walkthrough with screenshots (same content as below).

## SteamPipe (steamcmd)

Steam uploads use Valve's SteamPipe ContentBuilder, which can't be bundled
due to Steamworks SDK licensing.

1. Download the Steamworks SDK from <https://partner.steamgames.com/>.

   ![Download the Steamworks SDK](docs/download_sdk.png)

2. Extract it adjacent to your project. The default config expects
   `${PROJECT_DIR}../steamworks_sdk/`; override via the `STEAM_CMD_PATH`
   and `VDF_DIR` variables.
3. Place your app's `.vdf` at
   `steamworks_sdk/tools/ContentBuilder/scripts/app_<APP_ID>.vdf`.
4. Run `steamcmd.exe` once manually to cache login credentials.

The `WRITE_VDF_DESC` step automatically updates the `desc` field before each push,
so the Steam build history is labelled with the correct version and message. Pass
`params.branch` to also set the `setlive` branch (the release branch builds go live on).
Add it before your push steps with `params = {"files": ["${VDF_DIR}/app_${STEAM_APP_ID_FULL}.vdf", ...], "desc": "(${VERSION}) ${COMMIT_MESSAGE}", "branch": "${STEAM_BRANCH}"}`.

The branch comes from a persisted text input bound to the
`application/steamroller/steam_branch` setting and exposed as the `${STEAM_BRANCH}`
variable, so the default (e.g. `beta`) carries across builds and can be edited per release.

### Automated export

The `EXPORT_PROJECT` step mirrors the editor's **Export All** button. It renders
two buttons — **Export All Debug** and **Export All Release** — and each
relaunches the current Godot editor binary with `--headless` plus
`--export-debug` or `--export-release`, once per preset, in sequence. This
requires export templates to be installed.

By default it needs no configuration at all: every preset in
`export_presets.cfg` is exported to its own `export_path`, in file order.
Missing output folders are created. Note that Debug and Release share those
paths, so the last export you ran is the one on disk.

To pin a single mode (one button instead of two), or to export a hand-picked
list to paths of your own:

```gdscript
params = {
  "debug": false,                 # optional: one button, always Release
  "exports": [                    # optional: overrides export_presets.cfg
    {"preset": "Windows Desktop", "output": "${BUILDS_DIR}/latest/game_depot/game.exe"},
    {"preset": "Linux/X11",       "output": "${BUILDS_DIR}/latest/game_depot/game.x86_64"},
  ],
}
```

Once an export completes, both buttons stay disabled until **Reset and
increment version** restarts the checklist.

The default config ships with `STEAM_APP_ID_DEMO` and `STEAM_APP_ID_FULL`
both set to `480` (Valve's public SpaceWar test app) so you can dry-run
without a real product on Steam.

## First push to Steam

After your first upload, SteamPipe may report a failure because the `beta`
branch does not exist yet. Set one build to the default branch, then create
the `beta` branch from the Steamworks dashboard:

![Creating a Steam branch](docs/creating_branches.png)

Before players can install the game, add launch options for Windows and Linux
under **Installation → General Installation** (names should match your depot
output, e.g. `builds/latest/game_depot`):

![Setting launch options](docs/launch_options.png)

## Itch (butler)

`butler.exe` ships bundled at `addons/steamroller/butler-windows-amd64/`.
Run `butler login` once from a terminal, then uploads work.

## Steam Deck (devkit)

`deck/deploy.sh` takes the project from an edit to a running build on a Steam
Deck, in Game Mode, through the SteamOS devkit's device-side tools
(`~/devkit-utils`, installed when the Deck is paired with the SteamOS Devkit
Client once; after that the whole loop is ssh):

| step | what runs | where |
|---|---|---|
| export | `godot --headless --export-debug <preset>` | workstation |
| prepare | `steamos-prepare-upload --gameid <title>` | Deck |
| stop | `pkill` the running title | Deck |
| sync | `sha256sum` both ends, `scp` only what differs, prune extras | both |
| register | `steam-client-create-shortcut` (argv + compat tool) | Deck |
| launch | `steam-devkit-rpc run-game` | Deck |

Setup, once per machine:

```bash
cp addons/steamroller/templates/deck.env.example data/deck.env   # fill in DECK_HOST, GODOT_BIN
bash addons/steamroller/deck/deploy.sh --doctor
```

`data/deck.env` holds the Deck's address and the Godot binary; gitignore it in
your project. Everything else is derived: the devkit title from
`application/config/name`, the Deck-side `user://` folder from the same name,
the export folder from the preset's `export_path` (default preset
`Deck_Testing`; keep it out of the depot folders), and the wipe guard from
`BUILDS_DIR` (default `<project>/../builds`). Each can be overridden in
`deck.env`; the example lists every key. `--env FILE` reads a different file.

Flags: `--release`, `--no-export`, `--no-launch`, `--launch` (re-register and
run what is on the Deck), `--stop`, `--debugger[=HOST]` (appends
`--remote-debug tcp://HOST:6007`; the editor needs *Debug > Keep Debug Server
Open*), `--clean-cache` (wipe `user://` on the Deck first), `--tail`,
`--run ARGS...`, `--doctor`, `--dry-run`. Every failure prints an `ERROR` line
and exits 1.

The template config wires it up as the optional **Build + run on Deck** button
(`RUN_COMMAND` through `${BASH_EXE}` with `${DECK_SCRIPT} --clean-cache`).
`BASH_EXE` defaults to Git for Windows' `bash.exe`; the script also runs from a
Git Bash terminal directly. Note that the dock only shows the script's output
once it exits (see *Logs* below); the run itself takes about twenty seconds
and returns as soon as the Deck reports the game's pid.

## Variables

User-defined variables live in `config.variables`. Built-ins always available:

- `${VERSION}` — `application/config/version`
- `${APP_NAME}` — `application/config/name`
- `${COMMIT_MESSAGE}` — `application/config/commit_message` (raw, with spaces — use in git commit messages and VDF descriptions)
- `${COMMIT_MESSAGE_SLUG}` — same value with spaces replaced by underscores (use in folder/archive names)
- `${STEAM_BRANCH}` — `application/steamroller/steam_branch` (the `setlive` branch for VDF pushes)
- `${DEMO_MODE}` — `"true"` or `"false"`
- `${USER_DIR}` — globalized `user://`
- `${PROJECT_DIR}` — globalized `res://` (trailing slash included)
- `${PLATFORM}` — `OS.get_name()`

Undefined variables emit a warning and remain as literal `${TOKEN}` in the
rendered command, so misconfigurations show up immediately in the console.

## Version increment

`RESET_AND_INCREMENT` finds the last numeric segment of
`application/config/version` and increments it by one. Works for any segment
count:

- `1.2.3.4` → `1.2.3.5`
- `0.1` → `0.2`
- `2.345` → `2.346`

Use whatever your platform needs (Windows resource versions want 4 segments,
others can use fewer).

## Push builds section

The template config demonstrates separate **demo** and **full** exports
(`Windows_Demo` / `Linux_Demo` → `builds/latest/demo_depot`, `Windows_Final` /
`Linux_Final` → `game_depot`, `Web` → `web`). In the Release tab, a
`CHECKBOX` header step (`push_builds`) introduces the section; individual
push endpoints and aggregate buttons are marked `is_optional = true` so they
share one button row:

- **Push all** — runs every endpoint step in order (`RUN_STEPS` + `step_ids`)
- **Push all demo** — demo Steam + demo Itch
- **Push all release** — game Steam + web Itch + game Itch
- Per-endpoint buttons — each `RUN_COMMAND` step with its own `id`

Define endpoint steps once, then reference their IDs from aggregate steps:

```gdscript
# RUN_STEPS aggregate (is_optional = true, button_label = "Push all")
step_ids = ["push_demo_steam", "push_game_steam", "push_demo_itch", ...]
```

`push_all_demo` and `push_all_release` are normal checklist rows (not
optional): they gate on `build_complete` and tick their own checkbox when
their button finishes. The optional **Push all** shortcut runs every ID in
its `step_ids` list and marks each child step complete on success — so a
minimal config with only two non-optional `RUN_COMMAND` endpoints plus
**Push all** still runs and checks off both from one click.

Optional per-endpoint push buttons are always enabled. Their output is routed
to the console of the row they are attached to, as well as the Godot Output
panel.

## Logs and the non-blocking shell

Every external process runs through one helper: `create_process` plus a polled
`await`, with stdout and stderr redirected to a log file. The editor stays
interactive for the whole run — a `steamcmd` or `butler` upload no longer
freezes it — and while any step is running every action button is disabled, so
a second export or upload cannot be launched on top of the first.

While a command runs the console shows a heartbeat (`… still running (30s)`);
the captured output is emitted when the process exits. It generally cannot be
shown sooner: on Windows, `FileAccess.open()` fails with `ERR_FILE_CANT_OPEN`
for as long as `cmd.exe` holds the redirect target open, even though other
processes can read that file. The tail is written incrementally anyway, both
because it picks output up early wherever the file *is* readable and because
`RUN_COMMAND_ASYNC` points it at a `tail_file` written by a third-party tool.
Genuinely live output would need `OS.execute_with_pipe` plus a reader thread,
and even that only helps for tools that do not buffer stdout when it is not a
console (`ping` and `steamcmd` buffer; Go tools like `butler` do not).

Log files are written to `<OS cache dir>/steamroller_logs/<project name>/`,
named `<timestamp>_<seq>_<step>.log` — timestamp first, so a plain name sort is
chronological. They are kept on success as well as failure — a failed
`steamcmd` push is far easier to diagnose from the full file than from the
console tail — and the newest 30 are retained. The directory is deliberately
outside `user://`, which the `CLEAR_USER_DATA` step deletes.
