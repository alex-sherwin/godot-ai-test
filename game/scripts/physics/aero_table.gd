class_name DiscAeroTable
extends RefCounted

# Cross-file/self references go through preloaded consts rather than the global
# `class_name` identifiers. Godot only populates the global script-class cache
# during an editor/import pass, so a bare `godot --headless --script ...` run —
# which is exactly how CI gates on the test suite — cannot resolve class_name
# identifiers at parse time. preload() always can. The `class_name` declarations
# stay for Track C's benefit in the editor.
const AeroTable := preload("res://scripts/physics/aero_table.gd")

## Tabulated aerodynamic coefficients for one disc, as a function of angle of
## attack (radians).
##
## CONTRACT §3: Track A bakes PCHIP-resampled tables onto a *uniform* 0.5° grid
## over the full range, precisely so that the runtime can do plain linear
## interpolation with negligible error. We detect uniformity on load and take a
## fast O(1) path when it holds; a non-uniform grid still works via binary
## search, but it is slower and is reported by `is_uniform`.
##
## Angles are stored in RADIANS. Degrees exist only at the JSON boundary
## (CONTRACT §1: "Degrees ONLY at the UI boundary").
##
## Sign conventions (CONTRACT §5):
##   * alpha > 0  => nose up, airflow striking the underside of the flight plate.
##   * cm  > 0    => nose-UP pitching moment about the lateral axis.
##                   cm < 0 at low alpha  -> turn (right, for RHBH)
##                   cm > 0 at high alpha -> fade (left, for RHBH)

## Angle-of-attack grid, ascending, radians.
var alpha_rad: PackedFloat64Array = PackedFloat64Array()
var cl: PackedFloat64Array = PackedFloat64Array()
var cd: PackedFloat64Array = PackedFloat64Array()
var cm: PackedFloat64Array = PackedFloat64Array()

## Rate-damping derivatives (CONTRACT §3 "damping" block).
## These multiply RAW angular rates in rad/s (this is the convention the
## shotshaper / Hummel coefficient sets are quoted in — see disc_flight_sim.gd
## for the full moment assembly and the unit reasoning).
var c_mq: float = -0.0144  ## pitch damping
var c_rp: float = -0.0125  ## roll damping
var c_nr: float = -3.41e-5 ## spin-down

var source: String = ""

# Fast-path cache for the uniform grid.
var _uniform: bool = false
var _grid_ok: bool = false
var _a0: float = 0.0
var _inv_step: float = 0.0
var _n: int = 0
var _last: int = 0


func _init() -> void:
	pass


func is_uniform() -> bool:
	return _uniform


## False if the alpha grid is missing or not strictly ascending.
func is_grid_ok() -> bool:
	return _grid_ok


func size() -> int:
	return _n


func alpha_min() -> float:
	return alpha_rad[0] if _n > 0 else 0.0


func alpha_max() -> float:
	return alpha_rad[_n - 1] if _n > 0 else 0.0


## Rebuild the interpolation cache. Must be called after mutating the arrays.
func finalize() -> void:
	_n = alpha_rad.size()
	assert(cl.size() == _n and cd.size() == _n and cm.size() == _n,
		"DiscAeroTable: coefficient arrays must all match alpha_rad length")
	_uniform = false
	_last = 0
	_grid_ok = false
	if _n < 2:
		push_error("DiscAeroTable: need at least 2 grid points, got %d" % _n)
		return
	_a0 = alpha_rad[0]
	var step: float = alpha_rad[1] - alpha_rad[0]
	# A grid that is not strictly ascending is unusable — most likely it was
	# never populated. Fail loudly rather than silently clamping every lookup to
	# the last table entry, which reads as plausible-but-wrong coefficients.
	var ascending := true
	for i in range(1, _n):
		if alpha_rad[i] <= alpha_rad[i - 1]:
			ascending = false
			break
	if not ascending or step <= 0.0:
		push_error("DiscAeroTable: alpha grid is not strictly ascending")
		return
	_grid_ok = true
	var uniform := true
	for i in range(1, _n):
		if absf((alpha_rad[i] - alpha_rad[i - 1]) - step) > step * 1e-6:
			uniform = false
			break
	_uniform = uniform
	_inv_step = 1.0 / step


## Sample all three coefficients at `alpha` (radians) into `out` (size >= 3):
## out[0]=cl, out[1]=cd, out[2]=cm. Alpha is CLAMPED to the table range —
## CONTRACT §3 forbids extrapolation.
func sample_into(alpha: float, out: PackedFloat64Array) -> void:
	if _n == 0:
		out[0] = 0.0
		out[1] = 0.0
		out[2] = 0.0
		return
	if _n == 1:
		out[0] = cl[0]
		out[1] = cd[0]
		out[2] = cm[0]
		return
	var i: int
	var f: float
	if _uniform:
		var t: float = (alpha - _a0) * _inv_step
		if t <= 0.0:
			out[0] = cl[0]
			out[1] = cd[0]
			out[2] = cm[0]
			return
		var nf: float = float(_n - 1)
		if t >= nf:
			out[0] = cl[_n - 1]
			out[1] = cd[_n - 1]
			out[2] = cm[_n - 1]
			return
		i = int(t)
		f = t - float(i)
	else:
		if alpha <= alpha_rad[0]:
			out[0] = cl[0]
			out[1] = cd[0]
			out[2] = cm[0]
			return
		if alpha >= alpha_rad[_n - 1]:
			out[0] = cl[_n - 1]
			out[1] = cd[_n - 1]
			out[2] = cm[_n - 1]
			return
		i = _search(alpha)
		f = (alpha - alpha_rad[i]) / (alpha_rad[i + 1] - alpha_rad[i])
	var j: int = i + 1
	out[0] = cl[i] + (cl[j] - cl[i]) * f
	out[1] = cd[i] + (cd[j] - cd[i]) * f
	out[2] = cm[i] + (cm[j] - cm[i]) * f


## Convenience for tests/tools. Allocates; do not use in the hot loop.
func sample(alpha: float) -> Dictionary:
	var out := PackedFloat64Array()
	out.resize(3)
	sample_into(alpha, out)
	return {"cl": out[0], "cd": out[1], "cm": out[2]}


func _search(alpha: float) -> int:
	# Locality hint: trajectories sweep alpha slowly, so the previous bracket is
	# usually still valid or adjacent.
	var i: int = _last
	if i >= 0 and i < _n - 1 and alpha >= alpha_rad[i] and alpha < alpha_rad[i + 1]:
		return i
	var lo := 0
	var hi := _n - 1
	while hi - lo > 1:
		var mid: int = (lo + hi) >> 1
		if alpha < alpha_rad[mid]:
			hi = mid
		else:
			lo = mid
	_last = lo
	return lo


## Build from the CONTRACT §3 JSON dictionary. Returns null on a malformed doc,
## with the reason pushed as an error.
static func from_dict(d: Dictionary) -> AeroTable:
	if not d.has("alpha_deg") or not d.has("cl") or not d.has("cd") or not d.has("cm"):
		push_error("DiscAeroTable.from_dict: missing one of alpha_deg/cl/cd/cm")
		return null
	var t := AeroTable.new()
	var ad: Array = d["alpha_deg"]
	var n: int = ad.size()
	t.alpha_rad.resize(n)
	t.cl.resize(n)
	t.cd.resize(n)
	t.cm.resize(n)
	var acl: Array = d["cl"]
	var acd: Array = d["cd"]
	var acm: Array = d["cm"]
	if acl.size() != n or acd.size() != n or acm.size() != n:
		push_error("DiscAeroTable.from_dict: coefficient arrays disagree with alpha_deg")
		return null
	for i in n:
		t.alpha_rad[i] = deg_to_rad(float(ad[i]))
		t.cl[i] = float(acl[i])
		t.cd[i] = float(acd[i])
		t.cm[i] = float(acm[i])
	if d.has("damping"):
		var dm: Dictionary = d["damping"]
		t.c_mq = float(dm.get("c_mq", t.c_mq))
		t.c_rp = float(dm.get("c_rp", t.c_rp))
		t.c_nr = float(dm.get("c_nr", t.c_nr))
	t.source = String(d.get("source", ""))
	t.finalize()
	return t
