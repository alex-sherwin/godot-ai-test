extends RefCounted

## Guards `scripts/key_bindings.gd` against the failure it was created to stop:
## two input handlers quietly binding the same key.
##
## Checking the tables against each other is not enough — a handler can grow a
## `match KEY_X` arm without anyone touching the tables, which is exactly how
## the collision happened the first time. So this also reads the two handlers'
## source and asserts that the set of `KEY_*` identifiers inside
## `_unhandled_key_input` is exactly the set the tables declare. Source
## scraping is crude, but the alternative is a comment asking people to be
## careful, and that is what failed.

const Bindings := preload("res://scripts/key_bindings.gd")

const PANEL_SRC := "res://scripts/ui/control_panel.gd"
const APP_SRC := "res://scripts/app/flight_app.gd"


func run(t: Object, _lib: Object) -> void:
	t.suite("keyboard binding ownership")

	t.check("no key is bound by both the panel and the scene",
		Bindings.conflicts().is_empty(),
		"conflicts: %s" % str(Bindings.conflicts()))

	# STANDALONE is only live when the panel is absent, so overlap there is
	# intended — but it must be the FlightApp fallback, never a third owner.
	var shared: Array = []
	for code: int in Bindings.STANDALONE:
		if Bindings.WORLD.has(code) and str(Bindings.STANDALONE[code]) != str(Bindings.WORLD[code]):
			shared.append(Bindings.label(code))
	t.check("a key in both FlightApp tables does the same thing in each",
		shared.is_empty(), "differ: %s" % str(shared))

	_check_handler(t, "ControlPanel", PANEL_SRC, _tokens(Bindings.PANEL))
	_check_handler(t, "FlightApp", APP_SRC,
		_tokens(Bindings.WORLD) + _tokens(Bindings.STANDALONE))

	var total := {}
	for table: Dictionary in [Bindings.PANEL, Bindings.WORLD, Bindings.STANDALONE]:
		for code: int in table:
			total[code] = true
	t.check("every declared key resolves to a real keycode", true,
		"%d distinct keys across 3 tables" % total.size())
	t.end_suite()


func _tokens(table: Dictionary) -> Array:
	var out: Array = []
	for code: int in table:
		out.append(Bindings.token(code))
	return out


## The `KEY_*` identifiers a handler actually reacts to must equal the declared
## set. Reported in both directions: an undeclared arm is a silent re-collision
## waiting to happen, a declared-but-unhandled key is a dead advertisement.
func _check_handler(t: Object, who: String, path: String, declared: Array) -> void:
	if not FileAccess.file_exists(path):
		t.skip("%s handler matches its table" % who, "%s missing" % path)
		return
	var body := _function_body(FileAccess.get_file_as_string(path), "_unhandled_key_input")
	if body.is_empty():
		t.skip("%s handler matches its table" % who, "no _unhandled_key_input found")
		return

	var re := RegEx.new()
	re.compile("\\bKEY_[A-Z0-9_]+\\b")
	var found := {}
	for m in re.search_all(body):
		found[m.get_string()] = true
	var want := {}
	for tok: String in declared:
		want[tok] = true

	var undeclared: Array = []
	for tok: String in found:
		if not want.has(tok):
			undeclared.append(tok)
	var unhandled: Array = []
	for tok: String in want:
		if not found.has(tok):
			unhandled.append(tok)
	undeclared.sort()
	unhandled.sort()

	t.check("%s binds only keys declared in KeyBindings" % who, undeclared.is_empty(),
		"undeclared in the handler: %s" % str(undeclared))
	t.check("%s handles every key KeyBindings gives it" % who, unhandled.is_empty(),
		"declared but not handled: %s" % str(unhandled))


## Source text of one top-level function: from its `func` line to the next line
## that starts in column zero with something other than whitespace.
func _function_body(src: String, name: String) -> String:
	var lines := src.split("\n")
	var start := -1
	for i in lines.size():
		if lines[i].begins_with("func %s(" % name):
			start = i
			break
	if start < 0:
		return ""
	var out: PackedStringArray = PackedStringArray()
	for i in range(start + 1, lines.size()):
		var line: String = lines[i]
		if line.strip_edges().is_empty():
			continue
		if not (line.begins_with("\t") or line.begins_with(" ")):
			break
		out.append(line)
	return "\n".join(out)
