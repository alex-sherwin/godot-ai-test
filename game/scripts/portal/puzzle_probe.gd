class_name PuzzleProbe
extends Node

## The puzzle-mode counterpart of `PortalProbe`: it boots the real Portal
## Puzzles scene, walks a list of levels and camera views, and writes a PNG for
## each.
##
## ---------------------------------------------------------------------------
## Why this exists
## ---------------------------------------------------------------------------
## Every real defect found on this project was found by looking at a picture.
## The alternative to this scene is a 12-minute export-and-drive cycle in
## headless Chromium, which is the only thing that PROVES the shipped build
## works but is far too slow to iterate a look against. `PortalProbe` solved
## that for the hand-authored test pair; this solves it for the ten shipped
## levels, which are the thing players actually see.
##
##     xvfb-run -a godot --path game --rendering-driver opengl3 \
##         res://scenes/portal/puzzle_probe.tscn -- --capture=/tmp/shots
##
## Optional: `--levels=01_crosswind_hall,08_the_drop` and `--views=tee,top,level`.
##
## Software GL under Xvfb is NOT evidence the exported build works — only
## Chromium against `web/public/game/` is, and `scratchpad/verify/verify_build.sh`
## is what does that. This is a truthful preview of the FRAMING and the SHADING,
## which is what the loop is usually about.
##
## It is not reachable from `boot.tscn` and ships no code into either mode: it
## instances `puzzle_mode.tscn` exactly as `ModeBoot` does and drives its public
## API, so what it photographs is the real thing and not a copy of it.

const PUZZLE_SCENE := "res://scenes/ui/puzzle/puzzle_mode.tscn"

## Frames to settle before each capture. The portal renderer warms every pooled
## SubViewport over its first `warm_frames` frames and the ghost predictor is
## rate-limited, so a capture taken immediately shows neither.
const SETTLE_FRAMES := 14

var app: PuzzleModeApp = null

var _capture_dir: String = ""
var _shots: Array = []
var _next: int = 0
var _frames: int = 0
var _capture_at: int = 0
var _arm_portal_disc: bool = false
var _throw_after: int = 0


func _ready() -> void:
	var packed := load(PUZZLE_SCENE) as PackedScene
	if packed == null:
		push_error("PuzzleProbe: %s did not load" % PUZZLE_SCENE)
		return
	app = packed.instantiate() as PuzzleModeApp
	add_child(app)

	var levels := PackedStringArray()
	var views := PackedStringArray(["tee"])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--capture="):
			_capture_dir = a.substr("--capture=".length())
		elif a.begins_with("--levels="):
			levels = a.substr("--levels=".length()).split(",", false)
		elif a.begins_with("--views="):
			views = a.substr("--views=".length()).split(",", false)
		elif a.begins_with("--throw="):
			# Throw on arrival and capture this many frames into the flight, so
			# the crossing ghost, the renderer's focus hint and the follow camera
			# are all photographed doing their job rather than asserted about.
			_throw_after = int(a.substr("--throw=".length()).to_int())
		elif a == "--arm-portal-disc":
			# Levels 6, 7, 9 and 10 draw the predicted portal rectangle only
			# while a portal disc is armed, so the aid cannot be photographed
			# without pressing the same toggle a player presses.
			_arm_portal_disc = true
	if levels.is_empty():
		for i in app.levels.size():
			levels.append((app.levels.get_index(i) as PuzzleLevelData).id)

	for level_id: String in levels:
		for view: String in views:
			_shots.append({"level": level_id, "view": view})
	# One extra frame of the level browser, which is where a player starts and
	# the one screen that is nothing but UI.
	_shots.append({"level": "", "view": "select"})

	print("[PuzzleProbe] %d shots -> %s" % [_shots.size(), _capture_dir])
	if _capture_dir != "":
		DirAccess.make_dir_recursive_absolute(_capture_dir)
	_apply(0)


func _process(_delta: float) -> void:
	_frames += 1
	if _capture_dir == "" or _next >= _shots.size() or _frames < _capture_at:
		return
	var shot: Dictionary = _shots[_next]
	var name := "%02d-%s-%s" % [_next + 1, str(shot["level"]).replace("_", "-"),
		str(shot["view"])]
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [_capture_dir, name])
	var stats: Dictionary = app.preview.stage.stats()
	print("[PuzzleProbe] %s  rooms=%d portals=%d live=%d draw_calls=%d prims=%d problems=%d" % [
		name, int(stats.get("rooms", 0)), int(stats.get("portals", 0)),
		int(stats.get("active", 0)), int(stats.get("draw_calls", 0)),
		int(stats.get("primitives", 0)), int(stats.get("problems", 0))])
	_next += 1
	if _next >= _shots.size():
		get_tree().quit(0)
		return
	_apply(_next)


func _apply(i: int) -> void:
	var shot: Dictionary = _shots[i]
	if str(shot["view"]) == "select":
		app.ui.open_level_select()
	else:
		app.ui.level_select.visible = false
		app.load_level_by_id(str(shot["level"]))
		if _arm_portal_disc:
			for c in app.ui.find_children("", "CheckButton", true, false):
				var check := c as CheckButton
				if check.visible:
					check.button_pressed = true
					check.toggled.emit(true)
		app.set_view(str(shot["view"]))
		if _throw_after > 0:
			app.ui.throw_requested.emit()
	_capture_at = _frames + SETTLE_FRAMES + _throw_after
