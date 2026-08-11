extends SceneTree

## Headless physics test runner.
##
##     godot --headless --path game --script res://tests/run_tests.gd
##
## Exits non-zero if any check fails, so CI can gate on it.
##
## No `--import` pass is needed for the code to RESOLVE: every cross-file
## reference in `scripts/physics/**` and here goes through `preload()` rather than
## a global `class_name`, because Godot only populates the global script-class
## cache during an editor/import pass, and a bare `--script` run never does.
##
## Termination is guaranteed, and getting that right is load-bearing for CI.
## A GDScript runtime error unwinds the whole call stack back to the engine, so
## if it happened inside `_initialize()` the `quit()` at the end would never run
## and the process would spin forever — a hung CI job rather than a red one.
## The frame callback below therefore always quits on the first frame, with a
## failing code if the run did not reach the end.
##
## The callback MUST be `_process` / `_physics_process`. Godot 3's `MainLoop`
## virtuals were `_iteration` / `_idle`; Godot 4 renamed them, and a GDScript
## `func _iteration()` on a `SceneTree` subclass is simply never called — no
## error, no warning. That is not a benign typo: the suite runs to completion,
## prints "N passed", and then the process hangs forever with the tree spinning,
## so a passing run reads as a CI timeout and no exit code is ever delivered.
## It was misdiagnosed once as a cold-script-class-cache problem and "fixed" by
## running `--import` first, which does nothing for it. Verified against 4.7.1:
## with `_iteration` the process never exits; with `_process` it exits 0/1.

const Library := preload("res://scripts/physics/disc_library.gd")
const Support := preload("res://tests/test_support.gd")
const SuiteAero := preload("res://tests/suites/test_aero_table.gd")
const SuiteIntegrator := preload("res://tests/suites/test_integrator.gd")
const SuitePrecession := preload("res://tests/suites/test_precession_law.gd")
const SuiteBehaviour := preload("res://tests/suites/test_behaviour.gd")
const SuiteRobustness := preload("res://tests/suites/test_robustness.gd")
const SuiteDeterminism := preload("res://tests/suites/test_determinism.gd")
const SuiteCrossval := preload("res://tests/suites/test_crossval.gd")
const SuiteGeometryMirror := preload("res://tests/suites/test_geometry_mirror.gd")
const SuiteKeyBindings := preload("res://tests/suites/test_key_bindings.gd")
const Bench := preload("res://tests/bench.gd")

var _finished: bool = false
var _exit_code: int = 1


func _initialize() -> void:
	var t0 := Time.get_ticks_usec()
	print("Disc Golf Flight Lab — physics test suite")
	print("Godot %s" % Engine.get_version_info()["string"])

	var lib := Library.load_default()
	print("\ndisc roster: %d discs, source = %s" % [lib.size(),
		"game/data (Track A)" if lib.data_present() else "BUILT-IN FALLBACK"])
	for e in lib.load_errors:
		print("  ! %s" % e)
	if lib.size() > 0:
		var provs := {}
		for i in lib.size():
			var pv := lib.get_index(i).aero_provenance
			provs[pv] = int(provs.get(pv, 0)) + 1
		print("  aero provenance: %s" % str(provs))

	var t := Support.new()
	SuiteAero.new().run(t, lib)
	SuiteIntegrator.new().run(t, lib)
	SuitePrecession.new().run(t, lib)
	SuiteBehaviour.new().run(t, lib)
	SuiteRobustness.new().run(t, lib)
	SuiteDeterminism.new().run(t, lib)
	SuiteCrossval.new().run(t, lib)
	SuiteGeometryMirror.new().run(t, lib)
	SuiteKeyBindings.new().run(t, lib)
	Bench.new().run(t, lib)

	_exit_code = t.report()
	print("total wall time: %.2f s" % ((Time.get_ticks_usec() - t0) / 1e6))
	_finished = true


## Godot 4 `MainLoop` frame callback (see the header note — NOT `_iteration`).
func _process(_delta: float) -> bool:
	if not _finished:
		printerr("run_tests: aborted by a runtime error before the suite finished")
		_exit_code = 1
	quit(_exit_code)
	return true
