class_name ModeBoot
extends Node

## Chooses which mode the build starts in, and hosts it.
##
## One Godot export serves two products — **Flight Lab**, the open-range
## sandbox, and **Portal Puzzles** — because they share the physics core, the
## disc data, the theme and the key-binding table, and shipping them as two
## exports would mean shipping the 40 MB engine twice.
##
## ---------------------------------------------------------------------------
## How the mode arrives
## ---------------------------------------------------------------------------
##   web       `?mode=puzzle` on the query string, read through
##             `JavaScriptBridge`. The landing page links to
##             `game/index.html?mode=puzzle`, so the choice is made before the
##             engine downloads and the browser back button works.
##   desktop   `--mode=puzzle` (or `-- puzzle`) on the command line, which is
##             what the export smoke tests and `godot --path game` use.
##   default   Flight Lab, so an existing bookmark to `game/index.html` opens
##             exactly what it opened before.
##
## Godot's web shell does NOT forward the query string into
## `OS.get_cmdline_args()`, so reading `location.search` is not a shortcut around
## an engine feature — it is the only route. `JavaScriptBridge.eval` is guarded
## by `OS.has_feature("web")` because the singleton exists on every platform but
## does nothing off the web, and by a null check because a hardened browser can
## refuse the bridge outright.
##
## ---------------------------------------------------------------------------
## Why a boot scene rather than a branch inside `main.tscn`
## ---------------------------------------------------------------------------
## `main.tscn`'s root node IS `FlightApp` — the sandbox controller with the range
## instanced under it. Putting a mode branch in there would mean the puzzle mode
## always paid for the 200 m range's geometry and lighting. A three-line host
## scene keeps each mode's scene tree its own, and keeps `main.tscn` exactly what
## `check_resources.gd` asserts it is.

const LAB_SCENE := "res://scenes/main.tscn"
const PUZZLE_SCENE := "res://scenes/ui/puzzle/puzzle_mode.tscn"

const MODE_LAB := "lab"
const MODE_PUZZLE := "puzzle"

var _current: Node = null
var _mode: String = MODE_LAB


func _ready() -> void:
	_mode = detect_mode()
	print("[ModeBoot] mode=%s" % _mode)
	_enter(_mode)


## The requested mode, normalised. Unknown values fall back to the sandbox
## rather than to an error screen: a mistyped URL should still give you a
## simulator.
static func detect_mode() -> String:
	var raw := _raw_mode().strip_edges().to_lower()
	match raw:
		"puzzle", "puzzles", "portal", "portals":
			return MODE_PUZZLE
		_:
			return MODE_LAB


static func _raw_mode() -> String:
	for source: PackedStringArray in [OS.get_cmdline_user_args(), OS.get_cmdline_args()]:
		for arg in source:
			if arg.begins_with("--mode="):
				return arg.substr(7)
			if arg.begins_with("mode="):
				return arg.substr(5)
	if OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge"):
		var value: Variant = JavaScriptBridge.eval(
			"(function(){try{" +
			"var p=new URLSearchParams(window.location.search).get('mode');" +
			"if(p)return p;" +
			"var h=(window.location.hash||'').replace('#','');" +
			"return h||'';}catch(e){return '';}})()", true)
		if value is String:
			return value
	return ""


func mode() -> String:
	return _mode


## An optional level id from `?level=08_the_drop` / `--level=08_the_drop`, so a
## level is a linkable URL. Empty means "start at the first one". Also what the
## browser screenshot harness uses to reach a level without driving a menu.
static func requested_level() -> String:
	for source: PackedStringArray in [OS.get_cmdline_user_args(), OS.get_cmdline_args()]:
		for arg in source:
			if arg.begins_with("--level="):
				return arg.substr(8)
	if OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge"):
		var value: Variant = JavaScriptBridge.eval(
			"(function(){try{return new URLSearchParams(window.location.search)" +
			".get('level')||'';}catch(e){return '';}})()", true)
		if value is String:
			return value
	return ""


func switch_to(mode_name: String) -> void:
	if mode_name == _mode:
		return
	_mode = mode_name
	_enter(mode_name)


func _enter(mode_name: String) -> void:
	if _current != null:
		_current.queue_free()
		_current = null
	var path: String = PUZZLE_SCENE if mode_name == MODE_PUZZLE else LAB_SCENE
	if not ResourceLoader.exists(path):
		push_error("ModeBoot: %s is missing" % path)
		path = LAB_SCENE
	var packed := load(path) as PackedScene
	if packed == null:
		push_error("ModeBoot: %s did not load as a scene" % path)
		return
	_current = packed.instantiate()
	add_child(_current)
	# The puzzle UI offers a way back to the sandbox; the sandbox's own way out
	# is the export shell's "Back to overview" link, which is not ours to change.
	if _current.has_signal("sandbox_requested"):
		_current.connect("sandbox_requested", func() -> void: switch_to(MODE_LAB))
