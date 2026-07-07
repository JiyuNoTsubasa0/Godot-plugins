@tool
extends MarginContainer
## Editor dock UI for Project Cleaner.
## The plugin runs in the DESTINATION project (the clean/empty one).
## The user picks a SOURCE project folder to import files from.

const MigrationEngine := preload("res://addons/project_cleaner/migration_engine.gd")

# ── Colours ───────────────────────────────────────────────────────────────────
const CLR_BG_PANEL     := Color(0.15, 0.15, 0.17, 1.0)
const CLR_BG_DARK      := Color(0.11, 0.11, 0.13, 1.0)
const CLR_ACCENT       := Color(0.557, 0.937, 0.592, 1.0)   # #8eef97
const CLR_ACCENT_DIM   := Color(0.35, 0.65, 0.40, 1.0)
const CLR_WARN         := Color(1.0, 0.835, 0.31, 1.0)      # #ffd54f
const CLR_ERROR        := Color(0.957, 0.263, 0.212, 1.0)    # #f44336
const CLR_TEXT          := Color(0.88, 0.88, 0.88, 1.0)
const CLR_TEXT_DIM      := Color(0.55, 0.55, 0.55, 1.0)
const CLR_BTN_MIGRATE  := Color(0.20, 0.50, 0.28, 1.0)
const CLR_BTN_DRY      := Color(0.22, 0.22, 0.26, 1.0)
const CLR_PROGRESS_FG  := Color(0.557, 0.937, 0.592, 0.85)
const CLR_PROGRESS_BG  := Color(0.18, 0.18, 0.20, 1.0)

# ── UI nodes ──────────────────────────────────────────────────────────────────
var _source_edit: LineEdit
var _skip_edit: LineEdit
var _overwrite_check: CheckBox
var _dry_run_btn: Button
var _migrate_btn: Button
var _progress_bar: ProgressBar
var _progress_label: Label
var _log_text: RichTextLabel
var _summary_label: RichTextLabel
var _source_status: Label
var _file_dialog: FileDialog
var _is_running: bool = false

# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	# Root margin
	add_theme_constant_override("margin_left",   8)
	add_theme_constant_override("margin_right",  8)
	add_theme_constant_override("margin_top",    8)
	add_theme_constant_override("margin_bottom", 8)

	var hsplit := HSplitContainer.new()
	hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hsplit.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	hsplit.split_offset = 320
	add_child(hsplit)

	# ── LEFT PANEL: config ────────────────────────────────────────────────
	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_scroll.custom_minimum_size.x = 300
	hsplit.add_child(left_scroll)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 6)
	left_scroll.add_child(left)

	# Title
	var title := RichTextLabel.new()
	title.bbcode_enabled = true
	title.fit_content = true
	title.scroll_active = false
	title.text = "[b][color=#8eef97]PROJECT CLEANER[/color][/b]"
	title.add_theme_font_size_override("normal_font_size", 18)
	left.add_child(title)

	var desc := Label.new()
	desc.text = "Import only the files your source\nproject actually uses into this\nclean project."
	desc.add_theme_color_override("font_color", CLR_TEXT_DIM)
	desc.add_theme_font_size_override("font_size", 12)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(desc)

	left.add_child(_sep())

	# ── Source project folder ──
	var source_label := Label.new()
	source_label.text = "Source Project Folder"
	source_label.add_theme_font_size_override("font_size", 13)
	source_label.add_theme_color_override("font_color", CLR_ACCENT)
	left.add_child(source_label)

	var source_hint := Label.new()
	source_hint.text = "Select the Godot project you want\nto clean/import from."
	source_hint.add_theme_color_override("font_color", CLR_TEXT_DIM)
	source_hint.add_theme_font_size_override("font_size", 11)
	source_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(source_hint)

	var source_row := HBoxContainer.new()
	source_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(source_row)

	_source_edit = LineEdit.new()
	_source_edit.placeholder_text = "Choose source project folder…"
	_source_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_source_edit.add_theme_font_size_override("font_size", 12)
	_source_edit.text_changed.connect(_on_source_path_changed)
	source_row.add_child(_source_edit)

	var browse_btn := Button.new()
	browse_btn.text = " Browse "
	browse_btn.pressed.connect(_on_browse_pressed)
	browse_btn.add_theme_font_size_override("font_size", 12)
	source_row.add_child(browse_btn)

	# Source validation status
	_source_status = Label.new()
	_source_status.text = ""
	_source_status.add_theme_font_size_override("font_size", 11)
	left.add_child(_source_status)

	left.add_child(_spacer(2))

	# ── Destination info (read-only) ──
	var dest_label := Label.new()
	dest_label.text = "Destination (this project)"
	dest_label.add_theme_font_size_override("font_size", 13)
	dest_label.add_theme_color_override("font_color", CLR_ACCENT)
	left.add_child(dest_label)

	var dest_path := Label.new()
	dest_path.text = ProjectSettings.globalize_path("res://")
	dest_path.add_theme_color_override("font_color", CLR_TEXT_DIM)
	dest_path.add_theme_font_size_override("font_size", 11)
	dest_path.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	left.add_child(dest_path)

	left.add_child(_sep())

	# ── Skip patterns ──
	var skip_label := Label.new()
	skip_label.text = "Skip Patterns (comma-separated)"
	skip_label.add_theme_font_size_override("font_size", 13)
	skip_label.add_theme_color_override("font_color", CLR_ACCENT)
	left.add_child(skip_label)

	_skip_edit = LineEdit.new()
	_skip_edit.text = ".mp4, .zip, .blend, .tmp"
	_skip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skip_edit.add_theme_font_size_override("font_size", 12)
	left.add_child(_skip_edit)

	left.add_child(_spacer(4))

	# ── Overwrite checkbox ──
	_overwrite_check = CheckBox.new()
	_overwrite_check.text = " Overwrite existing files"
	_overwrite_check.add_theme_font_size_override("font_size", 12)
	_overwrite_check.add_theme_color_override("font_color", CLR_TEXT)
	left.add_child(_overwrite_check)

	left.add_child(_sep())

	# ── Buttons ──
	_dry_run_btn = Button.new()
	_dry_run_btn.text = "  Dry Run (Preview)  "
	_dry_run_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dry_run_btn.custom_minimum_size.y = 34
	_dry_run_btn.add_theme_font_size_override("font_size", 14)
	_dry_run_btn.pressed.connect(_on_dry_run_pressed)
	_style_button(_dry_run_btn, CLR_BTN_DRY)
	left.add_child(_dry_run_btn)

	left.add_child(_spacer(4))

	_migrate_btn = Button.new()
	_migrate_btn.text = "  Import Clean Project  "
	_migrate_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_migrate_btn.custom_minimum_size.y = 34
	_migrate_btn.add_theme_font_size_override("font_size", 14)
	_migrate_btn.pressed.connect(_on_migrate_pressed)
	_style_button(_migrate_btn, CLR_BTN_MIGRATE)
	left.add_child(_migrate_btn)

	left.add_child(_spacer(6))

	# ── Helpful note ──
	var note := Label.new()
	note.text = "Tip: project.godot is always copied\nverbatim, preserving all input maps,\nautoloads, and engine settings."
	note.add_theme_color_override("font_color", CLR_TEXT_DIM)
	note.add_theme_font_size_override("font_size", 11)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(note)

	# ── RIGHT PANEL: output ──────────────────────────────────────────────
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 4)
	hsplit.add_child(right)

	# Log label
	var log_label := Label.new()
	log_label.text = "Log Output"
	log_label.add_theme_font_size_override("font_size", 13)
	log_label.add_theme_color_override("font_color", CLR_ACCENT)
	right.add_child(log_label)

	# Log
	_log_text = RichTextLabel.new()
	_log_text.bbcode_enabled = true
	_log_text.scroll_following = true
	_log_text.selection_enabled = true
	_log_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_text.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_log_text.add_theme_font_size_override("normal_font_size", 12)
	_log_text.add_theme_font_size_override("bold_font_size", 12)
	var log_bg := StyleBoxFlat.new()
	log_bg.bg_color = CLR_BG_DARK
	log_bg.corner_radius_top_left = 4
	log_bg.corner_radius_top_right = 4
	log_bg.corner_radius_bottom_left = 4
	log_bg.corner_radius_bottom_right = 4
	log_bg.content_margin_left = 8
	log_bg.content_margin_right = 8
	log_bg.content_margin_top = 6
	log_bg.content_margin_bottom = 6
	_log_text.add_theme_stylebox_override("normal", log_bg)
	right.add_child(_log_text)

	_append_log("[color=#8eef97]Ready.[/color]  Select a source project folder and click [b]Dry Run[/b] to preview.")

	# Progress bar
	_progress_bar = ProgressBar.new()
	_progress_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress_bar.custom_minimum_size.y = 20
	_progress_bar.value = 0
	_progress_bar.show_percentage = false
	_progress_bar.visible = false
	var pb_bg := StyleBoxFlat.new()
	pb_bg.bg_color = CLR_PROGRESS_BG
	pb_bg.corner_radius_top_left = 3
	pb_bg.corner_radius_top_right = 3
	pb_bg.corner_radius_bottom_left = 3
	pb_bg.corner_radius_bottom_right = 3
	_progress_bar.add_theme_stylebox_override("background", pb_bg)
	var pb_fg := StyleBoxFlat.new()
	pb_fg.bg_color = CLR_PROGRESS_FG
	pb_fg.corner_radius_top_left = 3
	pb_fg.corner_radius_top_right = 3
	pb_fg.corner_radius_bottom_left = 3
	pb_fg.corner_radius_bottom_right = 3
	_progress_bar.add_theme_stylebox_override("fill", pb_fg)
	right.add_child(_progress_bar)

	# Progress label
	_progress_label = Label.new()
	_progress_label.text = ""
	_progress_label.add_theme_font_size_override("font_size", 11)
	_progress_label.add_theme_color_override("font_color", CLR_TEXT_DIM)
	_progress_label.visible = false
	right.add_child(_progress_label)

	# Summary
	var summary_label_title := Label.new()
	summary_label_title.text = "Summary"
	summary_label_title.add_theme_font_size_override("font_size", 13)
	summary_label_title.add_theme_color_override("font_color", CLR_ACCENT)
	right.add_child(summary_label_title)

	_summary_label = RichTextLabel.new()
	_summary_label.bbcode_enabled = true
	_summary_label.fit_content = true
	_summary_label.scroll_active = false
	_summary_label.add_theme_font_size_override("normal_font_size", 12)
	_summary_label.add_theme_font_size_override("bold_font_size", 12)
	_summary_label.text = "[color=#888888]No scan performed yet.[/color]"
	right.add_child(_summary_label)

	# ── File dialog (native OS dialog for full filesystem access) ──
	call_deferred("_setup_file_dialog")


func _setup_file_dialog() -> void:
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.title = "Select Source Godot Project Folder"
	_file_dialog.use_native_dialog = true
	_file_dialog.dir_selected.connect(_on_dir_selected)
	add_child(_file_dialog)

# ─────────────────────────────────────────────────────────────────────────────
# Source path validation
# ─────────────────────────────────────────────────────────────────────────────

func _on_source_path_changed(_new_text: String) -> void:
	_validate_source_path()


func _validate_source_path() -> bool:
	var path := _source_edit.text.strip_edges()
	if path.is_empty():
		_source_status.text = ""
		return false

	if not DirAccess.dir_exists_absolute(path):
		_source_status.text = "✖ Folder not found"
		_source_status.add_theme_color_override("font_color", CLR_ERROR)
		return false

	var proj_file := path.path_join("project.godot")
	if not FileAccess.file_exists(proj_file):
		_source_status.text = "✖ No project.godot found in this folder"
		_source_status.add_theme_color_override("font_color", CLR_ERROR)
		return false

	# Read project name for display
	var f := FileAccess.open(proj_file, FileAccess.READ)
	var project_name := "Unknown"
	if f != null:
		var content := f.get_as_text()
		f.close()
		var name_re := RegEx.new()
		name_re.compile('config/name="([^"]+)"')
		var m := name_re.search(content)
		if m != null:
			project_name = m.get_string(1)

	_source_status.text = "✓ Valid Godot project: %s" % project_name
	_source_status.add_theme_color_override("font_color", CLR_ACCENT)
	return true

# ─────────────────────────────────────────────────────────────────────────────
# Button callbacks
# ─────────────────────────────────────────────────────────────────────────────

func _on_browse_pressed() -> void:
	if _file_dialog != null:
		# Set initial directory to Documents for convenience
		var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
		_file_dialog.current_dir = docs
		_file_dialog.popup_centered_ratio(0.55)


func _on_dir_selected(path: String) -> void:
	_source_edit.text = path
	_validate_source_path()


func _on_dry_run_pressed() -> void:
	if _is_running:
		return
	if not _validate_source_path():
		_clear_log()
		_append_log("[color=#f44336]✖ Please select a valid source project folder first.[/color]")
		return
	_clear_log()
	_append_log("[b][color=#8eef97]─── DRY RUN ───[/color][/b]")
	_append_log("[color=#cccccc]  Source: %s[/color]" % _source_edit.text.strip_edges())
	_append_log("[color=#cccccc]  Destination: %s[/color]" % ProjectSettings.globalize_path("res://"))
	_run_migration(true)


func _on_migrate_pressed() -> void:
	if _is_running:
		return
	if not _validate_source_path():
		_clear_log()
		_append_log("[color=#f44336]✖ Please select a valid source project folder first.[/color]")
		return
	_clear_log()
	_append_log("[b][color=#8eef97]─── IMPORTING CLEAN PROJECT ───[/color][/b]")
	_append_log("[color=#cccccc]  Source: %s[/color]" % _source_edit.text.strip_edges())
	_append_log("[color=#cccccc]  Destination: %s[/color]" % ProjectSettings.globalize_path("res://"))
	_run_migration(false)

# ─────────────────────────────────────────────────────────────────────────────
# Migration orchestration
# ─────────────────────────────────────────────────────────────────────────────

func _run_migration(dry_run: bool) -> void:
	_is_running = true
	_dry_run_btn.disabled = true
	_migrate_btn.disabled = true
	_progress_bar.visible = !dry_run
	_progress_label.visible = !dry_run
	_progress_bar.value = 0

	var engine := MigrationEngine.new()
	engine.source_root = _source_edit.text.strip_edges()
	# destination is auto-set to the current project in engine._init()
	engine.overwrite_existing = _overwrite_check.button_pressed
	engine.skip_patterns = _parse_skip_patterns()

	# Connect signals
	engine.log_message.connect(_on_engine_log)
	engine.progress_updated.connect(_on_engine_progress)

	if dry_run:
		engine.scan()
	else:
		engine.execute_migration()

	# Show summary
	_display_summary(engine.get_summary(), dry_run)

	_progress_bar.visible = false
	_progress_label.visible = false
	_is_running = false
	_dry_run_btn.disabled = false
	_migrate_btn.disabled = false


func _parse_skip_patterns() -> PackedStringArray:
	var raw := _skip_edit.text.strip_edges()
	if raw.is_empty():
		return PackedStringArray()
	var parts: PackedStringArray = []
	for p in raw.split(","):
		var trimmed := p.strip_edges()
		if not trimmed.is_empty():
			parts.append(trimmed)
	return parts

# ─────────────────────────────────────────────────────────────────────────────
# Engine signal handlers
# ─────────────────────────────────────────────────────────────────────────────

func _on_engine_log(text: String, level: int) -> void:
	match level:
		0:
			_append_log("[color=#cccccc]  %s[/color]" % text)
		1:
			_append_log("[color=#ffd54f]⚠ %s[/color]" % text)
		2:
			_append_log("[color=#f44336]✖ %s[/color]" % text)


func _on_engine_progress(current: int, total: int, file_path: String) -> void:
	if total > 0:
		_progress_bar.value = float(current) / float(total) * 100.0
	_progress_label.text = "%d / %d  —  %s" % [current, total, file_path.get_file()]

# ─────────────────────────────────────────────────────────────────────────────
# Summary display
# ─────────────────────────────────────────────────────────────────────────────

func _display_summary(summary: Dictionary, dry_run: bool) -> void:
	var cats: Dictionary = summary.get("categories", {})
	var total: int = summary.get("total_files", 0)
	var copied: int = summary.get("copied_count", total)

	_append_log("")
	if dry_run:
		_append_log("[b][color=#8eef97]─── DRY-RUN COMPLETE ───[/color][/b]")
		_append_log("[color=#cccccc]  %d files would be imported.[/color]" % total)
	else:
		_append_log("[b][color=#8eef97]─── IMPORT COMPLETE ───[/color][/b]")
		_append_log("[color=#cccccc]  Imported %d / %d files.[/color]" % [copied, total])

	# Category breakdown as BBCode
	var bb := ""
	var order := ["Scenes", "Scripts", "Shaders", "Resources", "Textures",
				  "3D Models", "Audio", "Fonts", "Metadata", "Config", "Other"]
	for cat in order:
		if cats.has(cat):
			var files: Array = cats[cat]
			bb += "[color=#8eef97]%s:[/color]  [b]%d[/b]    " % [cat, files.size()]
	bb += "\n[color=#8eef97]Total:[/color]  [b]%d[/b] files" % total

	# Warnings
	var warns: Array = summary.get("warnings", [])
	var missing: Array = summary.get("missing_files", [])
	var unresolved: Array = summary.get("unresolved_uids", [])

	if not warns.is_empty():
		bb += "\n\n[color=#ffd54f]Warnings (%d):[/color]" % warns.size()
		for i in mini(warns.size(), 8):
			bb += "\n  • %s" % warns[i]
		if warns.size() > 8:
			bb += "\n  … and %d more" % (warns.size() - 8)

	if not missing.is_empty():
		bb += "\n\n[color=#ffd54f]Referenced but not found (%d):[/color]" % missing.size()
		for i in mini(missing.size(), 8):
			bb += "\n  • res://%s" % missing[i]
		if missing.size() > 8:
			bb += "\n  … and %d more" % (missing.size() - 8)

	if not unresolved.is_empty():
		bb += "\n\n[color=#ffd54f]Unresolved UIDs (%d):[/color]" % unresolved.size()
		for i in mini(unresolved.size(), 5):
			bb += "\n  • %s" % unresolved[i]
		if unresolved.size() > 5:
			bb += "\n  … and %d more" % (unresolved.size() - 5)

	_summary_label.text = bb

# ─────────────────────────────────────────────────────────────────────────────
# Log helpers
# ─────────────────────────────────────────────────────────────────────────────

func _append_log(bbcode: String) -> void:
	if _log_text != null:
		_log_text.append_text(bbcode + "\n")


func _clear_log() -> void:
	if _log_text != null:
		_log_text.clear()

# ─────────────────────────────────────────────────────────────────────────────
# UI construction helpers
# ─────────────────────────────────────────────────────────────────────────────

func _sep() -> HSeparator:
	var s := HSeparator.new()
	s.add_theme_constant_override("separation", 8)
	return s


func _spacer(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = height
	return c


func _style_button(btn: Button, bg_color: Color) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = bg_color
	normal.corner_radius_top_left = 4
	normal.corner_radius_top_right = 4
	normal.corner_radius_bottom_left = 4
	normal.corner_radius_bottom_right = 4
	normal.content_margin_left = 12
	normal.content_margin_right = 12
	normal.content_margin_top = 6
	normal.content_margin_bottom = 6
	btn.add_theme_stylebox_override("normal", normal)

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = bg_color.lightened(0.15)
	btn.add_theme_stylebox_override("hover", hover)

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = bg_color.darkened(0.1)
	btn.add_theme_stylebox_override("pressed", pressed)

	btn.add_theme_color_override("font_color", CLR_TEXT)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
