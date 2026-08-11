extends SceneTree

## Proves that the committed project can actually be *built and parsed*, which
## a green export does not.
##
##     godot --headless --path game --import                  # once, first
##     godot --headless --path game --script res://tests/check_resources.gd
##
## The import pass is mandatory here (unlike `run_tests.gd`): this check is
## specifically about `class_name` resolution, and the global script-class cache
## only exists after an import.
##
## ---------------------------------------------------------------------------
## Why a green export is not evidence
## ---------------------------------------------------------------------------
## `godot --headless --export-release` returns **exit 0** when scripts are
## missing. It writes the `.pck`, writes the `.wasm`, and every size assertion
## downstream of it passes. GDScript resolves `class_name` at *parse* time, so
## the failure surfaces in the browser and nowhere else. Six deploys of this
## project went green that way.
##
## Loading the scene back is not evidence either, and this is the subtle part:
##
##     load("res://scripts/app/flight_app.gd")   -> non-null, even when its
##                                                  `class_name` deps are gone
##     PackedScene.instantiate()                 -> a Node, same conditions
##
## Both "succeed" while the engine logs `Parse Error: Could not find script for
## class "Atmosphere"`. What does *not* lie is `GDScript.reload()`, which
## returns `ERR_PARSE_ERROR` (43). That is the signal this check gates on.
## Verified by deleting `atmosphere.gd` from a scratch copy of the tree: `load`
## and `instantiate` both reported success, `reload()` returned 43.

const ROOT_SCENE := "res://scenes/main.tscn"
const SELF_PATH := "res://tests/check_resources.gd"

## `path="res://..."` in a .tscn/.tres ext_resource line.
const EXT_RESOURCE_RE := 'path\\s*=\\s*"(res://[^"]+)"'
## Any res:// string literal in a script.
const RES_LITERAL_RE := '"(res://[^"]*)"'

var _errors: PackedStringArray = PackedStringArray()
var _checked_scripts: int = 0
var _reached: Dictionary = {}
var _finished: bool = false
var _exit_code: int = 1


func _initialize() -> void:
	print("Disc Golf Flight Lab — resource / parse check")
	print("Godot %s" % Engine.get_version_info()["string"])

	_walk(ROOT_SCENE)
	print("\nreachable from %s: %d resources" % [ROOT_SCENE, _reached.size()])
	for p in _sorted(_reached.keys()):
		print("  %s" % p)

	_compile_every_script()
	_check_root_scene()
	_check_stretch_policy()

	print("\n" + "=".repeat(72))
	if _errors.is_empty():
		print("resource check: OK — %d scripts compile, %d resources reachable"
			% [_checked_scripts, _reached.size()])
		_exit_code = 0
	else:
		print("resource check: %d PROBLEM(S)" % _errors.size())
		for e in _errors:
			print("  - %s" % e)
	print("=".repeat(72))
	_finished = true


## Godot 4 MainLoop frame callback. See run_tests.gd — it is NOT `_iteration`,
## which is the Godot 3 name and is silently never called.
func _process(_delta: float) -> bool:
	if not _finished:
		printerr("check_resources: aborted by a runtime error before finishing")
		_exit_code = 1
	quit(_exit_code)
	return true


# ---------------------------------------------------------------------------
# Transitive reachability from the root scene
# ---------------------------------------------------------------------------

func _walk(res_path: String) -> void:
	if _reached.has(res_path):
		return
	_reached[res_path] = true
	if res_path.ends_with("/"):
		if not DirAccess.dir_exists_absolute(res_path):
			_errors.append("%s (directory) is referenced but does not exist" % res_path)
		return
	if not FileAccess.file_exists(res_path):
		_errors.append("%s is referenced but does not exist" % res_path)
		return
	var ext := res_path.get_extension()
	if ext != "gd" and ext != "tscn" and ext != "tres":
		return
	var text := FileAccess.get_file_as_string(res_path)
	var re := RegEx.new()
	re.compile(EXT_RESOURCE_RE if ext != "gd" else RES_LITERAL_RE)
	for m in re.search_all(text):
		_walk(m.get_string(1))
	if ext == "gd":
		_walk_class_edges(text)


## `class_name` edges: the dependency a .tscn never mentions and the one that
## broke the deploys. Resolved through the global class list, which is what the
## parser itself uses.
func _walk_class_edges(text: String) -> void:
	var re := RegEx.new()
	re.compile("\\b([A-Z][A-Za-z0-9_]*)\\b")
	var seen := {}
	for m in re.search_all(text):
		seen[m.get_string(1)] = true
	for cls: String in seen:
		var path := _class_path(cls)
		if path != "":
			_walk(path)


var _class_paths: Dictionary = {}
var _class_paths_built: bool = false


func _class_path(cls: String) -> String:
	if not _class_paths_built:
		_class_paths_built = true
		for entry in ProjectSettings.get_global_class_list():
			_class_paths[str(entry["class"])] = str(entry["path"])
	return str(_class_paths.get(cls, ""))


# ---------------------------------------------------------------------------
# Parse check
# ---------------------------------------------------------------------------

## Every script in the project, not just the reachable ones: a script that no
## longer compiles is a defect whether or not the main scene happens to touch
## it today.
func _compile_every_script() -> void:
	var scripts := _sorted(_all_scripts("res://"))
	print("\ncompiling %d scripts" % scripts.size())
	for path: String in scripts:
		if path == SELF_PATH:
			continue
		_checked_scripts += 1
		var res: Variant = load(path)
		var gds := res as GDScript
		if gds == null:
			_errors.append("%s did not load as a GDScript" % path)
			continue
		# `load()` returns non-null for a script whose class_name dependencies
		# are missing; `reload()` is the call that reports it.
		var err: int = gds.reload(true)
		if err != OK:
			_errors.append("%s failed to compile (error %d)" % [path, err])


func _all_scripts(dir_path: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		var child := dir_path.path_join(name)
		if d.current_is_dir():
			out.append_array(_all_scripts(child))
		elif name.ends_with(".gd"):
			out.append(child)
		name = d.get_next()
	d.list_dir_end()
	return out


## The root scene has to instantiate, and the script on its root node has to be
## the real one — a scene whose script failed to parse still instantiates, with
## a bare Node3D where FlightApp should be.
func _check_root_scene() -> void:
	var packed := load(ROOT_SCENE) as PackedScene
	if packed == null:
		_errors.append("%s did not load as a PackedScene" % ROOT_SCENE)
		return
	var inst: Node = packed.instantiate()
	if inst == null:
		_errors.append("%s did not instantiate" % ROOT_SCENE)
		return
	var script := inst.get_script() as GDScript
	if script == null:
		_errors.append("%s root node has no script attached" % ROOT_SCENE)
	elif script.reload(true) != OK:
		_errors.append("%s root script does not compile" % ROOT_SCENE)
	elif not inst.has_method("throw"):
		_errors.append("%s root script is not FlightApp (no throw() method)" % ROOT_SCENE)
	else:
		print("\nroot scene instantiates, root script = %s" % script.resource_path)
	inst.free()


## `ControlPanel._layout()` is written against a guaranteed floor on the
## canvas-space viewport: `canvas_items` stretch with `expand` and a 1280x720
## base scales by `min(win.x/1280, win.y/720)`, so the canvas is never smaller
## than the base in either axis. The narrow-viewport branches were deleted on
## that basis, so the guarantee has to be enforced somewhere. Here.
func _check_stretch_policy() -> void:
	var want := {
		"display/window/stretch/mode": "canvas_items",
		"display/window/stretch/aspect": "expand",
		"display/window/size/viewport_width": 1280,
		"display/window/size/viewport_height": 720,
	}
	for key: String in want:
		var got: Variant = ProjectSettings.get_setting(key)
		if str(got) != str(want[key]):
			_errors.append(
				"%s is %s, expected %s — ControlPanel._layout() assumes the "
				% [key, str(got), str(want[key])]
				+ "canvas never drops below 1280x720 and has no narrow-viewport branches")
	print("\nstretch policy: %s / %s at %sx%s" % [
		ProjectSettings.get_setting("display/window/stretch/mode"),
		ProjectSettings.get_setting("display/window/stretch/aspect"),
		ProjectSettings.get_setting("display/window/size/viewport_width"),
		ProjectSettings.get_setting("display/window/size/viewport_height")])


static func _sorted(a: Array) -> Array:
	var out := a.duplicate()
	out.sort()
	return out
