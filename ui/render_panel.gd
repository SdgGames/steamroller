@tool
class_name SteamRollerRenderPanel extends SteamRollerStepRow
## A RENDER_QUEUE step's row: a source folder, the inputs found in it (select
## any number, Ctrl/Shift-click), and a checkbox per job. Its button runs every
## selected input through every ticked job (SteamRollerRenderQueue).

var _sources: OptionButton
var _list: ItemList
var _summary: Label
var _jobs: Dictionary[String, CheckBox] = {}
var _source_paths := PackedStringArray()
var _input_paths := PackedStringArray()


func _build_body() -> void:
	var source_row := HBoxContainer.new()
	add_child(source_row)
	var label := Label.new()
	label.text = "Source"
	source_row.add_child(label)
	_sources = OptionButton.new()
	_sources.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sources.clip_text = true
	_sources.item_selected.connect(func(_i: int) -> void: _fill_inputs())
	source_row.add_child(_sources)
	var rescan := Button.new()
	rescan.text = "Refresh"
	rescan.tooltip_text = "Look again for folders and files"
	rescan.pressed.connect(_fill_sources)
	source_row.add_child(rescan)

	_list = ItemList.new()
	_list.select_mode = ItemList.SELECT_MULTI
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var rows := runner.config.render_list_rows if runner.config else 8
	var font := get_theme_default_font()
	var line_h := font.get_height(get_theme_default_font_size()) if font else 18.0
	_list.custom_minimum_size = Vector2(0, (line_h + 6.0) * rows)
	_list.multi_selected.connect(func(_i: int, _on: bool) -> void: _update_summary())
	add_child(_list)

	for job in step.render_jobs:
		if job == null:
			continue
		var tick := CheckBox.new()
		tick.text = job.label if not job.label.is_empty() else job.id
		tick.tooltip_text = job.description
		tick.button_pressed = job.checked
		tick.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tick.toggled.connect(func(_on: bool) -> void: _update_summary())
		add_child(tick)
		_jobs[job.id] = tick

	_summary = Label.new()
	_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_summary)
	_fill_sources()


func _overrides_for(e: ButtonEntry) -> Dictionary:
	if e.step != step:
		return {}
	return {"inputs": Array(_selected_inputs()), "jobs": Array(_ticked_jobs())}


func _can_run(e: ButtonEntry) -> bool:
	return e.step != step or (not _selected_inputs().is_empty() and not _ticked_jobs().is_empty())


func _fill_sources() -> void:
	var keep := _source_paths[_sources.selected] if _sources.selected >= 0 else ""
	_sources.clear()
	_source_paths.clear()
	for src in SteamRollerRenderQueue.list_sources(step, runner.vars):
		_sources.add_item(str(src["label"]))
		_source_paths.append(str(src["path"]))
	if not _source_paths.is_empty():
		_sources.select(maxi(_source_paths.find(keep), 0))
	_fill_inputs()


func _fill_inputs() -> void:
	var keep := _selected_inputs()
	_list.clear()
	_input_paths.clear()
	if _sources.selected >= 0:
		var source := _source_paths[_sources.selected]
		var bias_s := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
		for item in SteamRollerRenderQueue.list_inputs(step, runner.vars, source):
			var path := str(item["path"])
			var when := Time.get_datetime_string_from_unix_time(int(item["modified"]) + bias_s, true)
			var seconds := float(item["seconds"])
			var length := "" if seconds < 0.0 else \
				"   " + SteamRollerShell.format_duration(roundi(seconds * 1000.0))
			var i := _list.add_item("%s%s   %s   %s" % [item["label"], length,
				String.humanize_size(int(item["bytes"])), when.substr(5, 11)])
			_list.set_item_tooltip(i, path)
			_input_paths.append(path)
			if keep.has(path):
				_list.select(i, false)
	_update_summary()


func _selected_inputs() -> PackedStringArray:
	var out := PackedStringArray()
	if _list:
		for i in _list.get_selected_items():
			out.append(_input_paths[i])
	return out


func _ticked_jobs() -> PackedStringArray:
	var out := PackedStringArray()
	for job_id: String in _jobs:
		if _jobs[job_id].button_pressed:
			out.append(job_id)
	return out


func _update_summary() -> void:
	var inputs := _selected_inputs().size()
	var jobs := _ticked_jobs().size()
	if _input_paths.is_empty():
		_summary.text = "Nothing to render in this folder."
	elif inputs == 0 or jobs == 0:
		_summary.text = "Select inputs and tick renders."
	else:
		_summary.text = "%d selected × %d render(s) = %d to make" % [inputs, jobs, inputs * jobs]
	_refresh()
