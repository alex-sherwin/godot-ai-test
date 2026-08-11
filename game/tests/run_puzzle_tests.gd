extends SceneTree

## Headless puzzle-mode test runner: the level replay gate plus the unit tests
## for the puzzle runtime.
##
##     godot --headless --path game --script res://tests/run_puzzle_tests.gd
##
## Exits non-zero if any check fails, so CI can gate on it.
##
## Separate from `run_tests.gd` on purpose. That runner is the physics core's,
## it is owned by another track, and it is edited concurrently; wiring level
## content into it would couple two independent gates and make a red level a red
## physics suite. Both are steps in the same CI job, so nothing reaches Pages
## without passing both.
##
## Everything here reaches its dependencies through `preload()` rather than the
## global `class_name` identifiers. A bare `--script` run never populates the
## global script-class cache, and a `class_name` reference in that mode is a
## parse error at load time rather than a failing test.
##
## The frame callback MUST be `_process`: Godot 3's `MainLoop` virtual was
## `_iteration`, Godot 4 never calls it, and a suite that finishes and then spins
## forever reads as a CI timeout with no exit code. See the long note in
## `run_tests.gd` — this runner inherits the same trap and the same fix.

const Library := preload("res://scripts/physics/disc_library.gd")
const Support := preload("res://tests/test_support.gd")
const SuitePuzzle := preload("res://tests/suites/test_puzzle.gd")
const SuiteReplay := preload("res://tests/suites/test_level_replay.gd")

var _finished: bool = false
var _exit_code: int = 1


func _initialize() -> void:
	var t0 := Time.get_ticks_usec()
	print("Disc Golf Flight Lab — puzzle mode / level replay gate")
	print("Godot %s" % Engine.get_version_info()["string"])

	var lib := Library.load_default()
	print("\ndisc roster: %d discs, source = %s" % [lib.size(),
		"game/data (Track A)" if lib.data_present() else "BUILT-IN FALLBACK"])
	for e in lib.load_errors:
		print("  ! %s" % e)

	var t := Support.new()
	SuitePuzzle.new().run(t, lib)
	SuiteReplay.new().run(t, lib)

	_exit_code = t.report()
	print("total wall time: %.2f s" % ((Time.get_ticks_usec() - t0) / 1e6))
	_finished = true


func _process(_delta: float) -> bool:
	if not _finished:
		printerr("puzzle suite did not reach the end of _initialize()")
		_exit_code = 1
	quit(_exit_code)
	return true
