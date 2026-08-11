class_name DiscLibrary
extends RefCounted

# See the note in aero_table.gd for why these are preloads, not class_name refs.
const AeroTable := preload("res://scripts/physics/aero_table.gd")
const DiscDef := preload("res://scripts/physics/disc_definition.gd")
const Library := preload("res://scripts/physics/disc_library.gd")

## Loads the disc roster described by CONTRACT §3.
##
##   res://data/discs.json         -> array of disc entries
##   res://data/aero/<aero>.json   -> coefficient table for each entry
##
## Track A owns `game/data/**`. If it is absent (or an entry is malformed) we
## fall back to DiscDefinition's built-in roster so that the physics core and
## Track C's scene remain runnable. `data_present()` reports which happened, so
## the UI can be honest about it (CONTRACT §7).

const DISCS_PATH := "res://data/discs.json"
const AERO_DIR := "res://data/aero/"

var discs: Array[DiscDef] = []
var load_errors: PackedStringArray = PackedStringArray()

var _by_id: Dictionary = {}
var _data_present: bool = false


func data_present() -> bool:
	return _data_present


func size() -> int:
	return discs.size()


func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for d in discs:
		out.append(d.id)
	return out


func get_disc(disc_id: String) -> DiscDef:
	return _by_id.get(disc_id, null)


func get_index(i: int) -> DiscDef:
	if i < 0 or i >= discs.size():
		return null
	return discs[i]


## Load the roster. Always succeeds: falls back to the built-ins.
static func load_default() -> Library:
	var lib := Library.new()
	lib._load()
	return lib


func _load() -> void:
	discs.clear()
	_by_id.clear()
	load_errors.clear()
	_data_present = false

	if not FileAccess.file_exists(DISCS_PATH):
		load_errors.append("%s not found; using built-in fallback roster" % DISCS_PATH)
		_load_builtins()
		return

	var text := FileAccess.get_file_as_string(DISCS_PATH)
	if text.is_empty():
		load_errors.append("%s is empty; using built-in fallback roster" % DISCS_PATH)
		_load_builtins()
		return

	var parsed: Variant = JSON.parse_string(text)
	var entries: Array = []
	if parsed is Array:
		entries = parsed
	elif parsed is Dictionary and (parsed as Dictionary).has("discs"):
		entries = (parsed as Dictionary)["discs"]
	else:
		load_errors.append("%s did not parse to an array; using built-in fallback" % DISCS_PATH)
		_load_builtins()
		return

	for e in entries:
		if not (e is Dictionary):
			continue
		var entry: Dictionary = e
		var aero_id := String(entry.get("aero", entry.get("id", "")))
		var table: AeroTable = _load_aero(aero_id)
		var disc := DiscDef.from_dict(entry, table)
		if disc == null or not disc.is_valid():
			load_errors.append("disc '%s' failed validation; skipped" % String(entry.get("id", "?")))
			continue
		discs.append(disc)
		_by_id[disc.id] = disc

	if discs.is_empty():
		load_errors.append("no usable discs in %s; using built-in fallback roster" % DISCS_PATH)
		_load_builtins()
		return
	_data_present = true


func _load_aero(aero_id: String) -> AeroTable:
	if aero_id.is_empty():
		return null
	var path := AERO_DIR + aero_id + ".json"
	if not FileAccess.file_exists(path):
		load_errors.append("%s not found; synthesising fallback coefficients" % path)
		return null
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		load_errors.append("%s did not parse to an object" % path)
		return null
	var table := AeroTable.from_dict(parsed)
	if table == null:
		load_errors.append("%s is missing required coefficient arrays" % path)
	return table


func _load_builtins() -> void:
	for bid in DiscDef.builtin_ids():
		var d := DiscDef.builtin(bid)
		if d != null:
			discs.append(d)
			_by_id[d.id] = d
