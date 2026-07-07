@tool
extends RefCounted
## Core migration engine for Project Cleaner.
## Scans an EXTERNAL source project's dependency tree and copies only the files
## that are actually used into the CURRENT project folder.  Preserves
## project.godot verbatim so input mappings, autoloads, display settings, etc.
## survive the migration.

# ── Signals ───────────────────────────────────────────────────────────────────

signal log_message(text: String, level: int)        # 0=info, 1=warning, 2=error
signal progress_updated(current: int, total: int, file_path: String)
signal migration_completed(summary: Dictionary)

# ── Constants ─────────────────────────────────────────────────────────────────

const TEXT_EXTENSIONS := [".tscn", ".tres", ".gd", ".gdshader", ".godot", ".cfg"]
const MODEL_EXTENSIONS := [".glb", ".gltf", ".fbx", ".obj"]
const TEXTURE_EXTENSIONS := [".png", ".jpg", ".jpeg"]
const INFRA_FILES := [
	"project.godot", "icon.svg", "icon.svg.import",
	"default_bus_layout.tres", ".gitignore", ".gitattributes", ".editorconfig",
]
const DEFAULT_SKIP_PATTERNS := [".mp4", ".zip", ".blend", ".tmp"]

# ── Configuration ─────────────────────────────────────────────────────────────

var source_root: String           ## Absolute path to the SOURCE project to scan.
var destination: String           ## Absolute path to the CURRENT project (auto-set).
var skip_patterns: PackedStringArray = PackedStringArray(DEFAULT_SKIP_PATTERNS)
var overwrite_existing: bool = false

# ── Internal State ────────────────────────────────────────────────────────────

var _uid_to_path: Dictionary = {}       # uid://xxx  → relative path
var _class_to_path: Dictionary = {}     # ClassName   → relative path
var _class_re: RegEx = null             # Compiled alternation of class names
var _copied_files: Dictionary = {}      # rel_path   → true  (set)
var _scanned_files: Dictionary = {}     # rel_path   → true  (set)
var _missing_files: Array[String] = []
var _unresolved_uids: Array[String] = []
var _warnings: Array[String] = []
var _file_categories: Dictionary = {}   # category   → Array[String]

# ── Regex (compiled once in _init) ────────────────────────────────────────────

var _res_quoted_re: RegEx     # res:// up to closing quote (handles spaces)
var _res_unquoted_re: RegEx   # res:// up to whitespace / delimiter
var _uid_re: RegEx            # uid://...
var _uid_path_re: RegEx       # uid="..." path="res://..."
var _header_uid_re: RegEx     # [gd_scene/gd_resource ... uid="..."]
var _addon_re: RegEx          # res://addons/<name>

# ─────────────────────────────────────────────────────────────────────────────
# Initialisation
# ─────────────────────────────────────────────────────────────────────────────

func _init() -> void:
	# Destination = current project (where the plugin is running).
	# Source = set by the user before calling scan() / execute_migration().
	destination = ProjectSettings.globalize_path("res://").rstrip("/").rstrip("\\")
	source_root = ""

	_res_quoted_re = RegEx.new()
	_res_quoted_re.compile("res://([^\"\\n\\r]+?)(?=[\"'])")

	_res_unquoted_re = RegEx.new()
	_res_unquoted_re.compile("res://([^\\s\"'\\n\\r\\t>),\\]]+)")

	_uid_re = RegEx.new()
	_uid_re.compile("(uid://[a-zA-Z0-9_]+)")

	_uid_path_re = RegEx.new()
	_uid_path_re.compile("uid=\"(uid://[^\"]+)\"\\s+path=\"res://([^\"]+)\"")

	_header_uid_re = RegEx.new()
	_header_uid_re.compile("\\[gd_(?:scene|resource)[^\\]]*uid=\"(uid://[^\"]+)\"")

	_addon_re = RegEx.new()
	_addon_re.compile("res://addons/([^/\"]+)")


func reset() -> void:
	_uid_to_path.clear()
	_class_to_path.clear()
	_class_re = null
	_copied_files.clear()
	_scanned_files.clear()
	_missing_files.clear()
	_unresolved_uids.clear()
	_warnings.clear()
	_file_categories.clear()

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

## Run Phase 1 + 2 + 3 (scan only, no copying).
func scan() -> void:
	reset()
	_phase1_build_uid_map()
	_phase2_scan_dependencies()
	_phase3_register_infrastructure()
	_log("Scan complete. %d files to copy." % _copied_files.size())


## Run full migration: scan → copy.  Returns the summary dictionary.
func execute_migration() -> Dictionary:
	scan()

	if source_root.is_empty():
		_log("No source project folder set!", 2)
		return get_summary()

	_log("Copying %d files to: %s" % [_copied_files.size(), destination])
	var copied := _copy_all_files()
	_log("Migration complete! Copied %d / %d files." % [copied, _copied_files.size()])

	_apply_source_project_settings()

	var summary := get_summary()
	summary["copied_count"] = copied
	migration_completed.emit(summary)
	return summary


## Return a categorised summary of the current scan state.
func get_summary() -> Dictionary:
	return {
		"total_files": _copied_files.size(),
		"categories": _file_categories.duplicate(true),
		"missing_files": _missing_files.duplicate(),
		"unresolved_uids": _unresolved_uids.duplicate(),
		"warnings": _warnings.duplicate(),
		"uid_count": _uid_to_path.size(),
		"class_count": _class_to_path.size(),
	}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1 — Build UID → Path mapping
# ─────────────────────────────────────────────────────────────────────────────

func _phase1_build_uid_map() -> void:
	_log("Phase 1: Building UID → Path mapping…")

	# 1a — .uid companion files (each contains a single uid:// string)
	var uid_files := _find_files_with_ext(source_root, ".uid")
	for abs_path in uid_files:
		var rel := _make_relative(abs_path)
		if rel.begins_with(".godot"):
			continue
		var f := FileAccess.open(abs_path, FileAccess.READ)
		if f == null:
			continue
		var uid_str := f.get_as_text().strip_edges()
		f.close()
		if uid_str.begins_with("uid://"):
			var resource_rel := rel.left(rel.length() - 4)   # strip ".uid"
			if not _uid_to_path.has(uid_str):
				_uid_to_path[uid_str] = resource_rel

	# 1b — .tscn / .tres headers  (ext_resource uid+path pairs & scene UID)
	for ext in [".tscn", ".tres"]:
		for abs_path in _find_files_with_ext(source_root, ext):
			var rel := _make_relative(abs_path)
			if rel.begins_with(".godot"):
				continue
			var f := FileAccess.open(abs_path, FileAccess.READ)
			if f == null:
				continue
			var content := f.get_as_text()
			f.close()
			for m in _uid_path_re.search_all(content):
				var uid_str := m.get_string(1)
				var res_path := m.get_string(2)
				if not _uid_to_path.has(uid_str):
					_uid_to_path[uid_str] = res_path
			for m in _header_uid_re.search_all(content):
				var uid_str := m.get_string(1)
				if not _uid_to_path.has(uid_str):
					_uid_to_path[uid_str] = rel

	# 1c — Global script class cache → class name → path
	_scan_class_cache()

	_log("  %d UID mappings,  %d class mappings." % [_uid_to_path.size(), _class_to_path.size()])


func _scan_class_cache() -> void:
	var cache_path := source_root.path_join(".godot/global_script_class_cache.cfg")
	if not FileAccess.file_exists(cache_path):
		return
	var f := FileAccess.open(cache_path, FileAccess.READ)
	if f == null:
		return
	var content := f.get_as_text()
	f.close()

	var c_re := RegEx.new()
	c_re.compile("\"class\":\\s*&?\"([^\"]+)\"")
	var p_re := RegEx.new()
	p_re.compile("\"path\":\\s*\"res://([^\"]+)\"")

	for block in content.split("}"):
		var cm := c_re.search(block)
		var pm := p_re.search(block)
		if cm != null and pm != null:
			_class_to_path[cm.get_string(1)] = pm.get_string(1)

	if _class_to_path.is_empty():
		return
	var parts: PackedStringArray = []
	for key in _class_to_path:
		parts.append(key as String)
	_class_re = RegEx.new()
	_class_re.compile("\\b(" + "|".join(parts) + ")\\b")

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2 — Recursive dependency scan
# ─────────────────────────────────────────────────────────────────────────────

func _phase2_scan_dependencies() -> void:
	_log("Phase 2: Scanning dependencies…")
	_deep_scan("project.godot")

	# Addon directories referenced in project.godot
	var proj_abs := source_root.path_join("project.godot")
	if FileAccess.file_exists(proj_abs):
		var f := FileAccess.open(proj_abs, FileAccess.READ)
		if f != null:
			var content := f.get_as_text()
			f.close()
			var seen_addons: Dictionary = {}
			for m in _addon_re.search_all(content):
				var addon_name := m.get_string(1)
				if not seen_addons.has(addon_name):
					seen_addons[addon_name] = true
					_register_addon_directory("addons/" + addon_name)

	_log("  %d dependencies found." % _copied_files.size())


func _deep_scan(rel_path: String) -> void:
	rel_path = _norm_rel(rel_path)
	if _scanned_files.has(rel_path):
		return
	_scanned_files[rel_path] = true

	if not _copy_file_with_companions(rel_path):
		if "." in rel_path.get_file() and not _missing_files.has(rel_path):
			_missing_files.append(rel_path)
		return

	var ext := ("." + rel_path.get_extension()).to_lower()
	if not TEXT_EXTENSIONS.has(ext):
		return

	var abs_path := source_root.path_join(rel_path)
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		_warnings.append("Could not read: %s" % rel_path)
		return
	var content := f.get_as_text()
	f.close()

	for dep in _extract_dependencies(content):
		dep = _norm_rel(dep)
		if not _scanned_files.has(dep):
			_deep_scan(dep)


func _extract_dependencies(content: String) -> PackedStringArray:
	var deps: PackedStringArray = []
	var seen: Dictionary = {}

	# res:// paths inside quotes (handles spaces in paths like "Intro scene/")
	for m in _res_quoted_re.search_all(content):
		var p := m.get_string(1).strip_edges().rstrip(",").rstrip(")").rstrip("\\").rstrip("/")
		if not p.is_empty() and not seen.has(p):
			seen[p] = true
			deps.append(p)

	# res:// paths not inside quotes
	for m in _res_unquoted_re.search_all(content):
		var p := m.get_string(1).strip_edges().rstrip(",").rstrip(")").rstrip("\\").rstrip("/")
		if not p.is_empty() and not seen.has(p):
			seen[p] = true
			deps.append(p)

	# uid:// references → resolve to file paths
	for m in _uid_re.search_all(content):
		var uid_str := m.get_string(1)
		var resolved := _resolve_uid(uid_str)
		if not resolved.is_empty():
			if not seen.has(resolved):
				seen[resolved] = true
				deps.append(resolved)
		else:
			if not _unresolved_uids.has(uid_str):
				_unresolved_uids.append(uid_str)

	# Global class name references
	if _class_re != null:
		for m in _class_re.search_all(content):
			var cname := m.get_string(1)
			if _class_to_path.has(cname):
				var cpath: String = _class_to_path[cname]
				if not seen.has(cpath):
					seen[cpath] = true
					deps.append(cpath)

	return deps


func _resolve_uid(uid_str: String) -> String:
	uid_str = uid_str.strip_edges()
	if _uid_to_path.has(uid_str):
		return _uid_to_path[uid_str]
	var clean := uid_str.lstrip("*")
	if _uid_to_path.has(clean):
		return _uid_to_path[clean]
	return ""

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3 — Infrastructure files
# ─────────────────────────────────────────────────────────────────────────────

func _phase3_register_infrastructure() -> void:
	_log("Phase 3: Registering infrastructure files…")
	for infra in INFRA_FILES:
		_register_file(infra)

# ─────────────────────────────────────────────────────────────────────────────
# File registration (scan-time bookkeeping — no disk writes)
# ─────────────────────────────────────────────────────────────────────────────

func _register_file(rel_path: String) -> bool:
	rel_path = _norm_rel(rel_path)
	if _copied_files.has(rel_path):
		return true
	if _should_skip(rel_path):
		return true

	var abs := source_root.path_join(rel_path)
	if not FileAccess.file_exists(abs):
		return false

	_copied_files[rel_path] = true
	_categorize_file(rel_path)
	return true


func _copy_file_with_companions(rel_path: String) -> bool:
	rel_path = _norm_rel(rel_path)
	if not _register_file(rel_path):
		return false

	# .import / .uid sidecars
	_register_file(rel_path + ".import")
	_register_file(rel_path + ".uid")

	var ext := ("." + rel_path.get_extension()).to_lower()
	var stem := rel_path.get_file().get_basename()
	var parent := rel_path.get_base_dir()

	# .bin sidecar for .gltf
	if ext == ".gltf":
		_find_companions_by_prefix(parent, stem, [".bin"])

	# .mtl sidecar for .obj
	if ext == ".obj":
		var mtl := rel_path.get_basename() + ".mtl"
		_register_file(mtl)

	# Texture companions for 3-D models  (Model_0.png, Model_1.jpg, …)
	if MODEL_EXTENSIONS.has(ext):
		_find_model_texture_companions(parent, stem)

	return true


func _register_addon_directory(addon_rel: String) -> void:
	var abs_dir := source_root.path_join(addon_rel)
	if not DirAccess.dir_exists_absolute(abs_dir):
		_warnings.append("Addon directory not found: %s" % addon_rel)
		return
	_log("  + addon: %s/" % addon_rel)
	_walk_and_register_all(abs_dir)


func _walk_and_register_all(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			if name != ".godot" and name != ".git":
				_walk_and_register_all(full)
		else:
			_register_file(_make_relative(full))
		name = dir.get_next()
	dir.list_dir_end()

# ─────────────────────────────────────────────────────────────────────────────
# Companion-file helpers
# ─────────────────────────────────────────────────────────────────────────────

func _find_companions_by_prefix(parent_rel: String, stem: String, extensions: Array) -> void:
	var abs_dir := source_root.path_join(parent_rel) if not parent_rel.is_empty() else source_root
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			var fext := ("." + name.get_extension()).to_lower()
			if extensions.has(fext) and name.begins_with(stem):
				var rel := parent_rel.path_join(name) if not parent_rel.is_empty() else name
				_register_file(rel)
		name = dir.get_next()
	dir.list_dir_end()


func _find_model_texture_companions(parent_rel: String, stem: String) -> void:
	var abs_dir := source_root.path_join(parent_rel) if not parent_rel.is_empty() else source_root
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			var fext := ("." + name.get_extension()).to_lower()
			if TEXTURE_EXTENSIONS.has(fext):
				if name.begins_with(stem + "_") or name.begins_with(stem + " ("):
					var rel := parent_rel.path_join(name) if not parent_rel.is_empty() else name
					_register_file(rel)
					_register_file(rel + ".import")
		name = dir.get_next()
	dir.list_dir_end()

# ─────────────────────────────────────────────────────────────────────────────
# Copy phase (called only during execute_migration)
# ─────────────────────────────────────────────────────────────────────────────

func _copy_all_files() -> int:
	var count := 0
	var total := _copied_files.size()
	var idx := 0

	for rel_path in _copied_files:
		idx += 1
		var src := source_root.path_join(rel_path)
		var dst := destination.path_join(rel_path)

		# Create parent directories
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())

		# Skip if destination exists and overwrite is off
		if FileAccess.file_exists(dst) and not overwrite_existing:
			progress_updated.emit(idx, total, rel_path)
			continue

		var err := DirAccess.copy_absolute(src, dst)
		if err == OK:
			count += 1
		else:
			_log("  Copy failed: %s (error %d)" % [rel_path, err], 2)

		progress_updated.emit(idx, total, rel_path)

	return count

# ─────────────────────────────────────────────────────────────────────────────
# Utility helpers
# ─────────────────────────────────────────────────────────────────────────────

func _norm_rel(path: String) -> String:
	return path.replace("\\", "/").lstrip("/").strip_edges()


func _make_relative(abs_path: String) -> String:
	abs_path = abs_path.replace("\\", "/")
	var root := source_root.replace("\\", "/")
	if not root.ends_with("/"):
		root += "/"
	if abs_path.begins_with(root):
		return abs_path.substr(root.length())
	return abs_path


func _should_skip(rel_path: String) -> bool:
	var bname := rel_path.get_file()
	for pattern in skip_patterns:
		if bname.contains(pattern):
			return true
	return false


func _categorize_file(rel_path: String) -> void:
	var ext := ("." + rel_path.get_extension()).to_lower()
	var category := "Other"
	if ext == ".tscn":
		category = "Scenes"
	elif ext == ".gd":
		category = "Scripts"
	elif ext == ".gdshader":
		category = "Shaders"
	elif ext == ".tres" or ext == ".res":
		category = "Resources"
	elif ext == ".png" or ext == ".jpg" or ext == ".jpeg" or ext == ".svg":
		category = "Textures"
	elif MODEL_EXTENSIONS.has(ext) or ext == ".bin" or ext == ".mtl":
		category = "3D Models"
	elif ext == ".ogg" or ext == ".mp3" or ext == ".wav" or ext == ".ogv":
		category = "Audio"
	elif ext == ".otf" or ext == ".ttf":
		category = "Fonts"
	elif ext == ".import" or ext == ".uid":
		category = "Metadata"
	elif ext == ".godot" or ext == ".cfg":
		category = "Config"

	if not _file_categories.has(category):
		_file_categories[category] = []
	_file_categories[category].append(rel_path)


func _log(text: String, level: int = 0) -> void:
	log_message.emit(text, level)


func _find_files_with_ext(base_path: String, extension: String) -> PackedStringArray:
	var results: PackedStringArray = []
	_walk_for_ext(base_path, extension, results)
	return results


func _walk_for_ext(path: String, extension: String, results: PackedStringArray) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir():
			if name != ".godot" and name != ".git":
				_walk_for_ext(path.path_join(name), extension, results)
		elif name.to_lower().ends_with(extension):
			results.append(path.path_join(name))
		name = dir.get_next()
	dir.list_dir_end()


func _apply_source_project_settings() -> void:
	var src_godot := source_root.path_join("project.godot")
	if not FileAccess.file_exists(src_godot):
		return

	var config := ConfigFile.new()
	var err := config.load(src_godot)
	if err != OK:
		_log("Failed to load source project.godot as ConfigFile (error %d)" % err, 2)
		return

	_log("Applying source project settings to current project...")

	# We want to load settings, but preserve editor_plugins/enabled of current project
	var current_plugins: PackedStringArray = []
	if ProjectSettings.has_setting("editor_plugins/enabled"):
		current_plugins = ProjectSettings.get_setting("editor_plugins/enabled")

	# Loop through sections and keys in source project.godot
	for section in config.get_sections():
		for key in config.get_section_keys(section):
			var value = config.get_value(section, key)

			# Combine section and key for ProjectSettings path
			var full_key = key
			if not section.is_empty():
				full_key = section + "/" + key

			# Special handling: preserve our plugin in editor_plugins/enabled
			if full_key == "editor_plugins/enabled":
				var src_plugins: PackedStringArray = []
				# Handle case where value might be generic Array instead of PackedStringArray
				for p in value:
					src_plugins.append(str(p))
				
				var merged_plugins := src_plugins.duplicate()
				for p in current_plugins:
					if not merged_plugins.has(p):
						merged_plugins.append(p)
				ProjectSettings.set_setting(full_key, merged_plugins)
			else:
				ProjectSettings.set_setting(full_key, value)

	# Save ProjectSettings
	var save_err := ProjectSettings.save()
	if save_err == OK:
		_log("Successfully saved new ProjectSettings. Autoloads, inputs, and scenes updated.")
	else:
		_log("Failed to save ProjectSettings (error %d)" % save_err, 2)

