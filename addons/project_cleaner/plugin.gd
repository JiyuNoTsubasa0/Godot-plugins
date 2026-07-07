@tool
extends EditorPlugin
## Project Cleaner — EditorPlugin entry point.
## Adds a bottom panel with the Project Cleaner UI when the plugin is enabled,
## and removes it cleanly when disabled.

const CleanerDock := preload("res://addons/project_cleaner/cleaner_dock.gd")

var _dock: Control = null


func _enter_tree() -> void:
	_dock = CleanerDock.new()
	_dock.name = "ProjectCleanerDock"
	add_control_to_bottom_panel(_dock, "Project Cleaner")


func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_bottom_panel(_dock)
		_dock.queue_free()
		_dock = null
