class_name PuzzleProgress
extends RefCounted

## Per-level medals, persisted locally in the browser.
##
## `user://` maps to IndexedDB in a Godot web export, so this survives a reload
## on the player's own machine and goes nowhere else. There is no account, no
## server and no cloud save; that is a deliberate property of this project, not
## an omission.
##
## ---------------------------------------------------------------------------
## Every level is browsable from the start
## ---------------------------------------------------------------------------
## Nothing here gates a level behind another level's medal, and nothing should.
## `is_unlocked()` exists so the menu has one place to ask, and it returns true.
## The levels are ordered by difficulty and each teaches the next one's
## vocabulary, which is a reason to *suggest* an order, not to enforce one — a
## player who bounces off Level 9 should be able to go and enjoy Level 10.
##
## Records are additive and monotone: a worse run never overwrites a better one,
## so replaying a level can only ever improve what is stored.

const ProgressT := preload("res://scripts/puzzle/progress_store.gd")

const SAVE_PATH := "user://puzzle_progress.json"
const SCHEMA := 1

const MEDAL_RANK := {"": 0, "bronze": 1, "silver": 2, "gold": 3}
const TIERS := ["bronze", "silver", "gold"]

## `level_id -> {medal, best_flag_distance_m, best_discs, attempts, completed}`
var records: Dictionary = {}
var load_errors: PackedStringArray = PackedStringArray()
## Set when persistence is unavailable (a read-only sandbox, a browser with
## storage disabled). The session still works; it just forgets.
var read_only: bool = false

var _path: String = SAVE_PATH


static func load_default(path: String = SAVE_PATH) -> ProgressT:
	var p := ProgressT.new()
	p._path = path
	p.load_from_disk()
	return p


func load_from_disk() -> void:
	records.clear()
	load_errors.clear()
	if not FileAccess.file_exists(_path):
		return
	var text := FileAccess.get_file_as_string(_path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		load_errors.append("%s did not parse; starting fresh" % _path)
		return
	var d: Dictionary = parsed
	if int(d.get("schema", 0)) != SCHEMA:
		load_errors.append("%s has schema %s, expected %d; starting fresh"
			% [_path, str(d.get("schema")), SCHEMA])
		return
	for k in (d.get("levels", {}) as Dictionary):
		records[String(k)] = (d["levels"] as Dictionary)[k]


func save() -> bool:
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		read_only = true
		load_errors.append("cannot write %s (error %d); progress will not persist"
			% [_path, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify({"schema": SCHEMA, "levels": records}, "  "))
	f.close()
	read_only = false
	return true


## Every level is playable from the start. See the class comment.
func is_unlocked(_level_id: String) -> bool:
	return true


func medal_of(level_id: String) -> String:
	return String((records.get(level_id, {}) as Dictionary).get("medal", ""))


func record_of(level_id: String) -> Dictionary:
	return records.get(level_id, {})


func best_distance(level_id: String) -> float:
	return float((records.get(level_id, {}) as Dictionary).get(
		"best_flag_distance_m", INF))


## Fold one finished attempt in. Monotone: only improvements are stored.
## Returns true if anything changed (i.e. worth calling `save()`).
func record_attempt(level_id: String, medal: String, flag_distance_m: float,
		discs_used: int, completed: bool) -> bool:
	var r: Dictionary = records.get(level_id, {
		"medal": "", "best_flag_distance_m": INF, "best_discs": 0,
		"attempts": 0, "completed": false,
	})
	var changed: bool = false
	r["attempts"] = int(r.get("attempts", 0)) + 1
	if MEDAL_RANK.get(medal, 0) > MEDAL_RANK.get(String(r.get("medal", "")), 0):
		r["medal"] = medal
		changed = true
	if completed:
		if not bool(r.get("completed", false)):
			changed = true
		r["completed"] = true
		if flag_distance_m < float(r.get("best_flag_distance_m", INF)):
			r["best_flag_distance_m"] = flag_distance_m
			changed = true
		var bd: int = int(r.get("best_discs", 0))
		if bd <= 0 or discs_used < bd:
			r["best_discs"] = discs_used
			changed = true
	records[level_id] = r
	return changed


## Medal counts across the whole set, for a menu header.
func summary(level_ids: PackedStringArray) -> Dictionary:
	var out := {"gold": 0, "silver": 0, "bronze": 0, "none": 0,
		"completed": 0, "total": level_ids.size()}
	for lid in level_ids:
		var m := medal_of(lid)
		out[m if m != "" else "none"] = int(out[m if m != "" else "none"]) + 1
		if bool((records.get(lid, {}) as Dictionary).get("completed", false)):
			out["completed"] = int(out["completed"]) + 1
	return out


func clear() -> void:
	records.clear()
	save()
