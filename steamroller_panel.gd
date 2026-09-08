@tool
class_name SteamRollerPanel extends Control
## Main editor dock.
##
## Walks the active config's step list, splits on NEW_TAB entries, and builds
## one TabContainer page per group. Each step gets a SteamRollerStepRow plus
## an HSeparator between rows.

const CONFIG_PATH_SETTING := "application/steamroller/config_path"

@onready var title_label: Label = $V/Header/Title
@onready var version_label: Label = $V/Header/Version
@onready var demo_toggle: CheckButton = $V/Header/DemoToggle
@onready var status_label: Label = $V/Status
@onready var tabs: TabContainer = $V/Tabs
@onready var instructions_page: Control = $"V/Tabs/Start Guide"

var runner: SteamRollerRunner
var config: SteamRollerConfig


func _ready() -> void:
	runner = SteamRollerRunner.new()
	runner.name = "Runner"
	add_child(runner)

	demo_toggle.toggled.connect(_on_demo_toggled)
	_clear_tabs()
	config = _load_config()
	if config == null:
		status_label.text = "No config loaded. Set application/steamroller/config_path."
		status_label.visible = true
		title_label.text = "SteamRoller"
		version_label.text = ""
		_pin_instructions_tab()
		return
	status_label.visible = false
	runner.load_config(config)
	runner.variables_changed.connect(_refresh_header)
	runner.tab_switch_requested.connect(func(idx: int) -> void: tabs.current_tab = idx)
	_refresh_header()
	_build_tabs()
	_pin_instructions_tab()
	tabs.current_tab = 0


func _load_config() -> SteamRollerConfig:
	var path := str(ProjectSettings.get_setting(CONFIG_PATH_SETTING, ""))
	if path.is_empty():
		push_warning("[SteamRoller] No config_path set.")
		return null
	if not ResourceLoader.exists(path):
		push_warning("[SteamRoller] Config not found at %s" % path)
		return null
	var res := load(path)
	if res is SteamRollerConfig:
		return res
	push_warning("[SteamRoller] Resource at %s is not a SteamRollerConfig." % path)
	return null


func _refresh_header() -> void:
	title_label.text = config.config_name if config else "SteamRoller"
	var name_part := str(ProjectSettings.get_setting("application/config/name", ""))
	var version_part := str(ProjectSettings.get_setting("application/config/version", ""))
	version_label.text = "%s %s" % [name_part, version_part]
	if ProjectSettings.has_setting("application/steamroller/demo_mode"):
		demo_toggle.set_pressed_no_signal(
			bool(ProjectSettings.get_setting("application/steamroller/demo_mode", false))
		)


func _clear_tabs() -> void:
	for child in tabs.get_children():
		if child == instructions_page:
			continue
		child.queue_free()


func _pin_instructions_tab() -> void:
	if instructions_page.get_index() != tabs.get_child_count() - 1:
		tabs.move_child(instructions_page, -1)


func _build_tabs() -> void:
	var current_list := _make_tab_page(config.first_tab_name)
	var last_row: SteamRollerStepRow = null
	for step in config.steps:
		if step == null:
			continue
		if step.action == SteamRollerStep.Action.NEW_TAB:
			current_list = _make_tab_page(step.tab_name)
			last_row = null
			continue
		if step.is_optional:
			if last_row != null and last_row.has_button_flow():
				if step.new_button_row:
					# Start a fresh HFlowContainer inside the existing row —
					# no separator added to the list.
					last_row.attach_new_button_line(step)
				else:
					last_row.attach_optional_button(step)
				continue
			# No suitable previous row — create an orphan button-only row.
			# This handles the "first step in a tab is optional" case and
			# the "previous step has no button" case.
			var orphan := SteamRollerStepRow.new()
			current_list.add_child(orphan)
			orphan.setup(step, runner)
			# Treat orphan as the new "last row" so subsequent optional steps
			# can attach to it.
			last_row = orphan
			current_list.add_child(HSeparator.new())
			continue
		# Standard step row + separator.
		var row := SteamRollerStepRow.new()
		current_list.add_child(row)
		row.setup(step, runner)
		current_list.add_child(HSeparator.new())
		last_row = row


## Create a new tab page (MarginContainer > ScrollContainer > VBoxContainer)
## and return the VBoxContainer that rows should be added to.
func _make_tab_page(tab_name: String) -> VBoxContainer:
	var page := MarginContainer.new()
	page.name = tab_name if not tab_name.is_empty() else "Tab"
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		page.add_theme_constant_override(side, 6)
	tabs.add_child(page)

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


func _on_demo_toggled(value: bool) -> void:
	ProjectSettings.set_setting("application/steamroller/demo_mode", value)
	ProjectSettings.save()
	runner.rebuild_variables()
	_refresh_header()
