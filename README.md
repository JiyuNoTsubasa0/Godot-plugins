# Godot Project Cleaner

A powerful, visual **Godot 4.x editor plugin** that helps you clean, optimize, and migrate your projects. 

Instead of copying files manually (which leaves behind hundreds of unused textures, models, and sound files) or using naive python scripts (which causes hundreds of compilation errors due to missing configuration settings), **Project Cleaner** allows you to import only the assets your game actually uses into a clean, fresh Godot project.

---

## 🌟 Features

* **Recursive Dependency Scanning:** Starts from `project.godot` (main scene and autoloads) and follows all `res://` and `uid://` paths through `.tscn`, `.tres`, `.gd`, and `.gdshader` files.
* **Companion File Aware:** Automatically packages binary sidecars (`.bin` for GLTF, `.mtl` for OBJ), resource metadata (`.import`, `.uid`), and model-specific texture companions (`ModelName_0.png`, etc.).
* **Autoload & Input Mapping Preservation:** Programmatically syncs your source project's configurations (autoload singletons, input maps, display settings, custom rendering pipelines, physics engines, and audio layouts) directly into the clean project's live `ProjectSettings`.
* **Safe Plugin Management:** Smart-merges plugin lists to guarantee **Project Cleaner** doesn't disable itself mid-migration.
* **Polished Live Dashboard:** 
  * **Native OS Directory Picker:** Fully browser-capable across the filesystem.
  * **Interactive Validation:** Instantly validates the source directory and reads the project name.
  * **Live Log Output:** Color-coded status updates for info, warnings, and copy errors.
  * **Dry Run Preview:** Analyze exactly how many files will be copied and what categories they fall into before writing to the disk.
  * **Categorized Breakdowns:** Displays exact counts for Scenes, Scripts, Resources, Shaders, Models, Textures, and Audio.

---

## 🚀 How it Works

To prevent editor locks and compilation errors, the plugin runs inside the **clean, target destination project**:

```
[Source Project] (Messy/Unorganized)
       │
       ▼ (Recursive Scan & Filter)
[Project Cleaner Plugin] (Runs inside target project)
       │
       ▼ (Imports only used files + Syncs ProjectSettings)
[Destination Project] (Clean & Lightweight)
```

---

## 🛠️ Installation

1. Create a **new, clean Godot project** (where you want to import your cleaned game).
2. Download or clone this repository.
3. Copy the `addons/project_cleaner` folder into the root directory of your new project.
4. Open the new project in the Godot Editor.
5. Go to **Project Settings > Plugins** and check the **Enable** box next to **Project Cleaner**.

---

## 📖 Usage Guide

1. Once enabled, click on the **Project Cleaner** tab at the bottom of the Godot Editor (next to *Output* and *Debugger*).
2. Under **Source Project Folder**, click **Browse** and select the folder of the project you want to clean/import from.
   * *The status label will show `✓ Valid Godot project: [Project Name]` if a `project.godot` is found.*
3. Configure your **Skip Patterns** (comma-separated file extensions or names to ignore, e.g. `.mp4, .zip, .blend, .tmp`).
4. Click **Dry Run (Preview)** to scan the project.
   * View the progress and check the *Summary* panel for file counts by category, missing references, or unresolved UIDs.
5. Check **Overwrite existing files** if you want to update any files you've modified in the source.
6. Click **Import Clean Project** to begin the copy and configuration sync.
7. Once finished, click **Reload Current Project** if prompted by the editor. Your game is now ready to play!

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
