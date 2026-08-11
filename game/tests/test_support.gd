extends RefCounted

## Minimal assertion/reporting harness for the headless physics test suite.
##
## Deliberately tiny and dependency-free: it has to run under a bare
## `godot --headless --script res://tests/run_tests.gd` with no import pass, so
## everything is reached through preloads rather than global class names.

const Support := preload("res://tests/test_support.gd")

var passed: int = 0
var failed: int = 0
var skipped: int = 0
var failures: PackedStringArray = PackedStringArray()
var notes: PackedStringArray = PackedStringArray()
var _suite: String = ""
var _t_suite: int = 0


func suite(name: String) -> void:
	_suite = name
	_t_suite = Time.get_ticks_usec()
	print("\n== %s" % name)


func end_suite() -> void:
	if _suite != "":
		print("   (%.0f ms)" % ((Time.get_ticks_usec() - _t_suite) / 1000.0))


## Hard assertion. `detail` is printed on both pass and fail so the suite output
## doubles as a measurement log — a green test that prints nothing tells you
## nothing about whether the number is close to the edge.
func check(name: String, ok: bool, detail: String = "") -> bool:
	if ok:
		passed += 1
		print("  PASS  %s%s" % [name, ("  " + detail) if detail != "" else ""])
	else:
		failed += 1
		var line := "%s / %s%s" % [_suite, name, ("  " + detail) if detail != "" else ""]
		failures.append(line)
		print("  FAIL  %s%s" % [name, ("  " + detail) if detail != "" else ""])
	return ok


func close(name: String, got: float, want: float, tol: float, units: String = "") -> bool:
	var d: float = absf(got - want)
	return check(name, d <= tol,
		"got %s want %s (|d|=%s <= %s%s)" % [Support.g(got, 6), Support.g(want, 6), Support.g(d, 3), Support.g(tol, 3), units])


func between(name: String, got: float, lo: float, hi: float, units: String = "") -> bool:
	return check(name, got >= lo and got <= hi,
		"got %s in [%s, %s]%s" % [Support.g(got, 6), Support.g(lo, 6), Support.g(hi, 6), units])


func skip(name: String, reason: String) -> void:
	skipped += 1
	print("  SKIP  %s  (%s)" % [name, reason])


## A non-fatal observation. Used where a number is a property of the DATA rather
## than of the integrator — reporting it loudly is honest; failing the build on
## it would only pressure the physics into being tuned to the fixture.
func note(text: String) -> void:
	notes.append(text)
	print("  NOTE  %s" % text)


func report() -> int:
	print("\n" + "=".repeat(72))
	print("physics suite: %d passed, %d failed, %d skipped" % [passed, failed, skipped])
	if not notes.is_empty():
		print("\nnotes (non-fatal):")
		for n in notes:
			print("  - %s" % n)
	if failed > 0:
		print("\nfailures:")
		for f in failures:
			print("  - %s" % f)
	print("=".repeat(72))
	return 1 if failed > 0 else 0


# ---------------------------------------------------------------------------
# shared helpers
# ---------------------------------------------------------------------------

## Absolute path of the repo root (the Godot project lives in `game/`).
## Validation fixtures live outside res://, so they are reached through the OS
## filesystem. Only valid for a source run, which is the only way tests run.
static func repo_root() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


## GDScript's `%` format has no `%g`, and `%f` renders 1e-9 as "0.000000" —
## exactly the range these tests report errors in. This is the missing
## specifier: `sig` significant figures, switching to exponent form outside
## [1e-4, 1e6).
static func g(x: float, sig: int = 4) -> String:
	if not is_finite(x):
		return str(x)
	if x == 0.0:
		return "0"
	var a: float = absf(x)
	var e: int = int(floor(log(a) / log(10.0)))
	if a >= 1e-4 and a < 1e6:
		return String.num(x, maxi(0, sig - 1 - e))
	var m: float = x / pow(10.0, e)
	return "%se%d" % [String.num(m, sig - 1), e]


static func max_component(a: Vector3, b: Vector3) -> float:
	return maxf(maxf(absf(a.x - b.x), absf(a.y - b.y)), absf(a.z - b.z))


## Sample a trajectory of {t, pos} samples at an arbitrary time by linear
## interpolation, so two runs on different sample grids can still be compared.
static func interp_samples(samples: Array, t: float, key: String) -> Vector3:
	var n: int = samples.size()
	if n == 0:
		return Vector3.ZERO
	if t <= float(samples[0]["t"]):
		return samples[0][key]
	if t >= float(samples[n - 1]["t"]):
		return samples[n - 1][key]
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid: int = (lo + hi) >> 1
		if t < float(samples[mid]["t"]):
			hi = mid
		else:
			lo = mid
	var t0: float = float(samples[lo]["t"])
	var t1: float = float(samples[lo + 1]["t"])
	var f: float = 0.0 if t1 <= t0 else (t - t0) / (t1 - t0)
	var a: Vector3 = samples[lo][key]
	var b: Vector3 = samples[lo + 1][key]
	return a.lerp(b, f)


static func interp_scalar(samples: Array, t: float, key: String) -> float:
	var n: int = samples.size()
	if n == 0:
		return 0.0
	if t <= float(samples[0]["t"]):
		return float(samples[0][key])
	if t >= float(samples[n - 1]["t"]):
		return float(samples[n - 1][key])
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid: int = (lo + hi) >> 1
		if t < float(samples[mid]["t"]):
			hi = mid
		else:
			lo = mid
	var t0: float = float(samples[lo]["t"])
	var t1: float = float(samples[lo + 1]["t"])
	var f: float = 0.0 if t1 <= t0 else (t - t0) / (t1 - t0)
	return lerpf(float(samples[lo][key]), float(samples[lo + 1][key]), f)
