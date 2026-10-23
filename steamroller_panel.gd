@tool
class_name SteamRollerPanel extends Control
## The dock: one tab per NEW_TAB group of the config's steps, one row per step
## (a step with attach_to joins its host's row), the Start Guide last.

@onready var _title: Label = $V/Header/Title
@onready var _version: Label = $V/Header/Version
@onready var _demo: CheckButton = $V/Header/DemoToggle
@onready var _reload: Button = $V/Header/Reload
@onready var _status: Label = $V/Status
@onready var _tabs: TabContainer = $V/Tabs
@onready var _guide: Control = $"V/Tabs/Start Guide"

var runner: SteamRollerStepRunner
var config: SteamRollerConfig
var _pages: Array[Control] = []


func _ready() -> void:
	runner = SteamRollerStepRunner.new()
	runner.name = "Runner"
	add_child(runner)
	runner.variables_changed.connect(_refresh_header)
	runner.reset_requested.connect(_show_first_tab)
	_demo.toggled.connect(_on_demo_toggled)
	_reload.pressed.connect(_load)
	_load()


## (Re)read the config from disk and rebuild every tab. A step still running is
## stopped and abandoned first: Reload is also the way out of a run that can no
## longer finish.
func _load() -> void:
	runner.abandon()
	# Out of the tree now, so the new tabs can take the old tabs' names.
	for page in _pages:
		_tabs.remove_child(page)
		page.queue_free()
	_pages.clear()
	config = _read_config()
	if config == null:
		_status.text = "No config: set application/steamroller/config_path."
		_status.visible = true
		_title.text = "SteamRoller"
		_version.text = ""
		return
	_status.visible = false
	runner.load_config(config)
	_build_tabs()
	_tabs.move_child(_guide, -1)
	runner.refresh_variables()
	_show_first_tab()


func _read_config() -> SteamRollerConfig:
	var path := SteamRollerSettings.config_path()
	if path.is_empty() or not ResourceLoader.exists(path):
		push_warning("[SteamRoller] No config at '%s' (application/steamroller/config_path)." % path)
		return null
	# A fresh copy from disk, kept out of the resource cache. Reloading over a
	# cached copy would keep the old value of every field the file no longer
	# sets, and the editor saves cached resources it thinks were edited (on Play,
	# for one), which could write that stale copy over the file.
	var res := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if res is SteamRollerConfig:
		return res
	push_warning("[SteamRoller] %s is not a SteamRollerConfig." % path)
	return null


func _build_tabs() -> void:
	# The steps attached to each host, in list order.
	var attached: Dictionary[String, Array] = {}
	for s in config.steps:
		if _hosted_elsewhere(s):
			if not attached.has(s.attach_to):
				attached[s.attach_to] = []
			attached[s.attach_to].append(s)
	var list := _new_page(config.first_tab_name)
	var last: SteamRollerStepRow = null
	for s in config.steps:
		if s == null or _hosted_elsewhere(s):
			continue
		if s.action == SteamRollerStep.Action.NEW_TAB:
			list = _new_page(s.tab_name)
			last = null
			continue
		if s.is_optional and s.attach_to.is_empty() and last != null:
			last.attach(s)   # a 0.2 config: an optional step joins the row above
			continue
		var row: SteamRollerStepRow = SteamRollerRenderPanel.new() \
			if s.action == SteamRollerStep.Action.RENDER_QUEUE else SteamRollerStepRow.new()
		list.add_child(row)
		row.setup(s, runner)
		if attached.has(s.id):
			for extra: SteamRollerStep in attached[s.id]:
				row.attach(extra)
		list.add_child(HSeparator.new())
		last = row


## True for a step whose buttons live in another step's row.
func _hosted_elsewhere(s: SteamRollerStep) -> bool:
	if s == null or s.attach_to.is_empty():
		return false
	var host := runner.find_step(s.attach_to)
	return host != null and host != s and host.attach_to.is_empty()


## A new tab: a margin, a scroll area and the list rows go in.
func _new_page(tab_name: String) -> VBoxContainer:
	var page := MarginContainer.new()
	page.name = tab_name if not tab_name.is_empty() else "Tab"
	for side: String in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		page.add_theme_constant_override(side, 6)
	_tabs.add_child(page)
	_pages.append(page)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)
	return list


func _show_first_tab() -> void:
	if not _pages.is_empty():
		_tabs.current_tab = _pages[0].get_index()


func _refresh_header() -> void:
	_title.text = config.config_name if config else "SteamRoller"
	_version.text = "%s %s" % [SteamRollerSettings.text(SteamRollerSettings.APP_NAME),
		SteamRollerSettings.text(SteamRollerSettings.VERSION)]
	_demo.set_pressed_no_signal(SteamRollerSettings.demo_mode())


func _on_demo_toggled(on: bool) -> void:
	SteamRollerSettings.set_demo_mode(on)
	runner.refresh_variables()
