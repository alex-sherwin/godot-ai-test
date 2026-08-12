class_name KeyBindings
extends RefCounted

## THE keyboard map. One file, three tables, no other place in the project may
## decide what a key does.
##
## ---------------------------------------------------------------------------
## Why this exists
## ---------------------------------------------------------------------------
## The scene track (`FlightApp`) and the UI track (`ControlPanel`) were written
## against a contract that covered signals and method names but said nothing
## about keyboard input. Both bound Space, C, V, R, H and the digit row, in two
## different `_unhandled_key_input` handlers, to two different actions. Godot
## delivers unhandled input in reverse tree order, so the panel silently won
## every collision and the scene's shortcuts became dead code that still looked
## live in its on-screen hint. That is the kind of defect that survives review
## because each file is individually correct.
##
## The fix is not "be careful": it is that both handlers now dispatch through
## the tables below, the on-screen hints are generated from them, and
## `tests/suites/test_key_bindings.gd` fails the build if the tables overlap or
## if either handler grows a `KEY_*` the tables do not declare.
##
## ---------------------------------------------------------------------------
## Ownership
## ---------------------------------------------------------------------------
##   PANEL       ControlPanel owns these whenever it is in the scene. It is the
##               authority on input: it consumes them and marks them handled.
##   WORLD       FlightApp keeps these even when the panel is present. Must be
##               disjoint from PANEL — the test asserts it.
##   STANDALONE  FlightApp binds these ONLY when there is no control panel (the
##               built-in debug HUD). They may overlap PANEL freely: the two
##               sets are never live at the same time.
##   PUZZLE      PuzzleUi owns these in Portal Puzzles mode. The two modes are
##               separate scenes chosen at boot and never coexist, so overlap
##               with PANEL and WORLD is expected — the same reasoning as
##               STANDALONE. Where a key appears in both, it means the same
##               thing on both sides (Space throws, R starts over, C cycles the
##               camera), because a player moving between the two modes should
##               not have to relearn the keyboard.
##
## To add a shortcut: put it in exactly one table here, then handle it in that
## table's owner. Nowhere else.

## Values are the short label used in the on-screen hint; the tooltip on the
## matching widget carries the long version.

## Owned by `scripts/ui/control_panel.gd`.
const PANEL := {
	KEY_SPACE: "throw",
	KEY_ENTER: "throw",
	KEY_KP_ENTER: "throw",
	KEY_R: "reset",
	KEY_C: "camera",
	KEY_V: "vectors",
	KEY_T: "trails",
	KEY_H: "panel",
	KEY_ESCAPE: "close overlay",
	KEY_1: "Throw tab",
	KEY_2: "Discs tab",
	KEY_3: "Design tab",
	KEY_4: "Env tab",
	KEY_5: "Flight tab",
}

## Owned by `scripts/app/flight_app.gd`, live alongside the panel.
##
## W is the whole list, and deliberately: the wind visualiser is the one thing
## the panel's Env tab cannot exercise without typing numbers, and a demo needs
## one key that changes the weather. Anything else added here must first be
## removed from PANEL.
const WORLD := {
	KEY_W: "wind",
}

## Owned by `scripts/app/flight_app.gd`, live ONLY when `control_panel.tscn` is
## absent or failed to load. Overlap with PANEL is expected and harmless.
const STANDALONE := {
	KEY_SPACE: "throw",
	KEY_1: "camera: tee",
	KEY_2: "camera: follow",
	KEY_3: "camera: top",
	KEY_4: "camera: side",
	KEY_5: "camera: free",
	KEY_V: "vectors",
	KEY_C: "clear trails",
	KEY_H: "panel",
	KEY_BRACKETLEFT: "previous disc",
	KEY_BRACKETRIGHT: "next disc",
	KEY_R: "reset to the tee",
	KEY_W: "wind",
}


## Owned by `scripts/ui/puzzle/puzzle_ui.gd`, live ONLY in Portal Puzzles mode.
##
## The digit row is deliberately absent. In the sandbox 1-5 are the panel tabs,
## and a player who has learned that should not find that 1 loads a level here.
## Level choice is a screen (L), not a chord.
## F, Home and the two zoom keys are the free camera. They are declared here and
## handled in `PuzzleUi` rather than left to `CameraRig`'s own `_unhandled_input`
## (which is how the sandbox reaches the same zoom) because in puzzle mode the
## aim overlay owns the pointer and the rig never sees an event — see the note in
## `scripts/ui/puzzle/aim_overlay.gd`.
const PUZZLE := {
	KEY_SPACE: "throw",
	KEY_ENTER: "throw",
	KEY_KP_ENTER: "throw",
	KEY_R: "retry",
	KEY_A: "exact parameters",
	KEY_C: "camera",
	KEY_F: "inspect",
	KEY_HOME: "camera to the tee",
	# Both, because the key is labelled "+" and produces "=" unshifted, and a
	# player pressing the key with the plus sign on it is not wrong.
	KEY_EQUAL: "zoom in",
	KEY_PLUS: "zoom in",
	KEY_MINUS: "zoom out",
	KEY_G: "ghost",
	KEY_K: "hint",
	KEY_L: "levels",
	KEY_N: "next level",
	KEY_BRACKETLEFT: "previous disc",
	KEY_BRACKETRIGHT: "next disc",
	KEY_ESCAPE: "back",
}


## Keys bound twice at the same time. Must always be empty; the test suite
## asserts it rather than trusting the tables to have been read.
static func conflicts() -> Array:
	var out: Array = []
	for code: int in PANEL:
		if WORLD.has(code):
			out.append(label(code))
	out.sort()
	return out


## "Space", "R", "BracketLeft" — the name Godot itself prints for the key.
static func label(code: int) -> String:
	return OS.get_keycode_string(code)


## The GDScript identifier for a keycode: `KEY_SPACE`, `KEY_BRACKETLEFT`.
## Used by the test suite to compare these tables against the `match` arms in
## the two input handlers, so a new binding cannot be added to a handler without
## being declared here.
static func token(code: int) -> String:
	return "KEY_" + OS.get_keycode_string(code).to_upper().replace(" ", "_")


## One-line on-screen hint, generated from a table so the hint and the bindings
## cannot drift apart. `order` picks which keys appear and in what sequence;
## keys not in the table are skipped.
static func hint(table: Dictionary, order: Array, sep: String = " · ") -> String:
	var parts: PackedStringArray = PackedStringArray()
	for code: int in order:
		if table.has(code):
			parts.append("%s %s" % [label(code).to_upper(), str(table[code]).to_lower()])
	return sep.join(parts)
