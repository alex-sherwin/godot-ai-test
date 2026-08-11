class_name SampleRoster
extends RefCounted

## A built-in roster in the CONTRACT §3 shape, used only when
## `res://data/discs.json` has not been generated yet.
##
## The flight numbers and PDGA measurements are the same published facts Track
## A's `tools/aero/roster.py` ships, so the panel looks and behaves the same
## before and after the data pipeline lands. Two of the eight geometry
## parameters — `parting_line_m` and `rim_thickness_m` — are published by
## nobody; here they are filled in by a fixed rule of thumb rather than by Track
## A's flight-number inference, so every entry in this fallback is flagged
## `"fallback"` and the UI says so out loud. Nothing here is measured data,
## including the four entries whose *aero table* upstream is.

## id, name, category, speed, glide, turn, fade, mass_kg,
## diameter_cm, height_cm, rim_depth_cm, rim_width_cm
const MOULDS := [
	["aviar", "Innova Aviar", "putter", 2, 3, 0, 1, 0.175, 21.2, 2.0, 1.5, 0.9],
	["zone", "Discraft Zone", "approach", 4, 3, 0, 3, 0.173, 21.1, 2.0, 1.3, 1.2],
	["roc", "Innova Roc", "midrange", 4, 4, 0, 3, 0.180, 21.7, 2.0, 1.3, 1.2],
	["buzzz", "Discraft Buzzz", "midrange", 5, 4, -1, 1, 0.177, 21.7, 1.9, 1.3, 1.2],
	["leopard", "Innova Leopard", "fairway_driver", 6, 5, -2, 1, 0.175, 21.2, 1.6, 1.1, 1.6],
	["teebird", "Innova Teebird", "fairway_driver", 7, 5, 0, 2, 0.175, 21.2, 1.5, 1.1, 1.7],
	["fd", "Discmania FD", "fairway_driver", 7, 6, -1, 1, 0.175, 21.2, 1.8, 1.1, 1.8],
	["river", "Latitude 64 River", "fairway_driver", 7, 7, -1, 1, 0.174, 21.5, 1.9, 1.2, 1.8],
	["undertaker", "Discraft Undertaker", "control_driver", 9, 5, -1, 2, 0.173, 21.1, 1.8, 1.1, 1.9],
	["firebird", "Innova Firebird", "control_driver", 9, 3, 0, 4, 0.175, 21.1, 1.4, 1.2, 1.9],
	["roadrunner", "Innova Roadrunner", "control_driver", 9, 5, -4, 1, 0.175, 21.1, 1.4, 1.2, 1.8],
	["wraith", "Innova Wraith", "distance_driver", 11, 5, -1, 3, 0.175, 21.1, 1.4, 1.2, 2.1],
	["destroyer", "Innova Destroyer", "distance_driver", 12, 5, -1, 3, 0.175, 21.1, 1.4, 1.2, 2.2],
	["boss", "Innova Boss", "distance_driver", 13, 5, -1, 2, 0.175, 21.2, 1.5, 1.2, 2.5],
]

## Which moulds the Giljarhus et al. (2022) CFD cases were run on. Upstream
## states the first three in the case-file headers; `dd2` names no commercial
## mould at all, so pairing it with a Destroyer is our inference and is labelled
## as such wherever it is shown.
const MEASURED := {
	"teebird": "giljarhus2022:fd2",
	"firebird": "giljarhus2022:cd1",
	"roadrunner": "giljarhus2022:cd5",
	"destroyer": "giljarhus2022:dd2",
}


static func entries() -> Array:
	var out: Array = []
	for m in MOULDS:
		var diameter_m: float = float(m[8]) * 0.01
		var height_m: float = float(m[9]) * 0.01
		var rim_depth_m: float = float(m[10]) * 0.01
		var rim_width_m: float = float(m[11]) * 0.01
		# Unpublished pair, filled by rule of thumb (see the class docstring).
		var parting_line_m: float = 0.42 * rim_depth_m
		var rim_thickness_m: float = 0.50 * rim_depth_m
		var geometry := {
			"diameter_m": diameter_m,
			"mass_kg": float(m[7]),
			"rim_width_m": rim_width_m,
			"rim_depth_m": rim_depth_m,
			"rim_thickness_m": rim_thickness_m,
			"parting_line_m": parting_line_m,
			"dome_height_m": maxf(height_m - rim_depth_m - DiscGeometryCalc.PLATE_THICKNESS_M, 0.0),
			"inner_rim_edge_m": diameter_m * 0.5 - rim_width_m,
		}
		var id: String = m[0]
		out.append({
			"id": id,
			"name": m[1],
			"category": m[2],
			"flight_numbers": {
				"speed": float(m[3]), "glide": float(m[4]),
				"turn": float(m[5]), "fade": float(m[6]),
			},
			"geometry": geometry,
			"aero": id,
			# Even the four CFD moulds are "fallback" here: this roster carries
			# no coefficient tables at all, so nothing in it may claim to be
			# measured (CONTRACT §7).
			"aero_provenance": "fallback",
			"aero_source": MEASURED.get(id, ""),
			"fallback": true,
		})
	return out
