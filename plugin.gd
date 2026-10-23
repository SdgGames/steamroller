@tool
extends EditorPlugin
## SteamRoller's entry point: registers its project settings and docks the panel.

# Loaded by path when the plugin starts, never preloaded: if a freshly updated
# addon has a script the editor has not scanned yet, the panel fails to load
# with an error, instead of the editor disabling the whole plugin.
const SETTINGS_SCRIPT := "res://addons/steamroller/steamroller_settings.gd"
const RENDER_QUEUE_SCRIPT := "res://addons/steamroller/runtime/render_queue.gd"
const PANEL_SCENE := "res://addons/steamroller/steamroller_panel.tscn"

var _dock: Control = null


func _enter_tree() -> void:
	var settings: GDScript = load(SETTINGS_SCRIPT)
	if settings:
		settings.call("register")
	var queue: GDScript = load(RENDER_QUEUE_SCRIPT)
	if queue:
		queue.call("remove_stale_override")
	var scene: PackedScene = load(PANEL_SCENE)
	if scene == null:
		push_error("[SteamRoller] Could not load %s." % PANEL_SCENE)
		return
	_dock = scene.instantiate()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BR, _dock)


func _exit_tree() -> void:
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
