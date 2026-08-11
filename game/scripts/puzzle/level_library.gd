class_name PuzzleLevelLibrary
extends RefCounted

## Loads every puzzle level in `res://data/levels/`, in menu order.
##
## The order comes from `index.json` rather than from a directory walk.
## `DirAccess` over `res://` is reliable in the editor and merely *usually*
## reliable inside an exported pack, and the menu order is content, not an
## accident of filename sorting. `test_puzzle.gd` cross-checks the index against
## the directory listing, so a level added without being indexed fails CI rather
## than silently not shipping.

const LevelDataT := preload("res://scripts/puzzle/level_data.gd")
const LibraryT := preload("res://scripts/puzzle/level_library.gd")

const LEVEL_DIR := "res://data/levels/"
const INDEX_PATH := "res://data/levels/index.json"

var levels: Array = []                ## PuzzleLevelData, menu order
var load_errors: PackedStringArray = PackedStringArray()

var _by_id: Dictionary = {}


static func load_default() -> LibraryT:
	var lib := LibraryT.new()
	lib.load_all()
	return lib


func size() -> int:
	return levels.size()


func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for lv in levels:
		out.append((lv as LevelDataT).id)
	return out


func get_level(level_id: String) -> LevelDataT:
	return _by_id.get(level_id, null)


func get_index(i: int) -> LevelDataT:
	return levels[i] if i >= 0 and i < levels.size() else null


## Index of `level_id` in menu order, or -1.
func order_of(level_id: String) -> int:
	for i in levels.size():
		if (levels[i] as LevelDataT).id == level_id:
			return i
	return -1


func load_all() -> void:
	levels.clear()
	_by_id.clear()
	load_errors.clear()

	for lid in indexed_ids():
		var path: String = LEVEL_DIR + lid + ".json"
		var lv := LevelDataT.from_file(path)
		for e in lv.errors:
			load_errors.append(e)
		if lv.id != lid and lv.id != "":
			load_errors.append("%s declares id '%s'" % [path, lv.id])
		levels.append(lv)
		_by_id[lv.id] = lv


## Ordered level ids from `index.json`.
func indexed_ids() -> PackedStringArray:
	var out := PackedStringArray()
	if not FileAccess.file_exists(INDEX_PATH):
		load_errors.append("%s missing — no levels will load" % INDEX_PATH)
		return out
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(INDEX_PATH))
	if not (parsed is Dictionary):
		load_errors.append("%s did not parse as a JSON object" % INDEX_PATH)
		return out
	for e in ((parsed as Dictionary).get("levels", []) as Array):
		out.append(String(e))
	return out


## Every `*.json` in the level directory except the index, sorted. Used by the
## test that proves the index is complete; not used at runtime.
static func scan_dir() -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(LEVEL_DIR)
	if d == null:
		return out
	for f in d.get_files():
		var name: String = f
		# In an exported build resources arrive with an extra extension.
		if name.ends_with(".remap") or name.ends_with(".import"):
			name = name.get_basename()
		if not name.ends_with(".json") or name == "index.json":
			continue
		out.append(name.get_basename())
	out.sort()
	return out
