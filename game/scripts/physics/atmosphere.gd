class_name Atmosphere
extends RefCounted

## CONTRACT §6: air_density = f(altitude_m, temperature_C), ISA barometric.
## Sea level at 15 °C -> 1.225 kg/m^3.

const P0 := 101325.0        ## Pa, ISA sea-level pressure
const T0 := 288.15          ## K, ISA sea-level temperature
const LAPSE := 0.0065       ## K/m, ISA troposphere lapse rate
const R_SPECIFIC := 287.0528 ## J/(kg K), dry air
const G0 := 9.80665         ## m/s^2, standard gravity
## g0 * M / (R* * L) = 5.25588 — the ISA pressure exponent.
const P_EXPONENT := 5.255877


## Static pressure at geopotential altitude (m), ISA troposphere.
static func pressure(altitude_m: float) -> float:
	var h: float = clampf(altitude_m, -500.0, 11000.0)
	return P0 * pow(1.0 - LAPSE * h / T0, P_EXPONENT)


## Air density from altitude and *actual* local temperature.
##
## Note this deliberately mixes the ISA pressure profile with a measured
## temperature: pressure follows the standard atmosphere for the given
## altitude, but density uses the real temperature the thrower is standing in.
## That is what you want for "70 °F in Denver" and it is a common convention;
## it is not the pure ISA density unless temperature_c matches the ISA profile.
static func air_density(altitude_m: float = 0.0, temperature_c: float = 15.0) -> float:
	var t_k: float = maxf(temperature_c + 273.15, 150.0)
	return pressure(altitude_m) / (R_SPECIFIC * t_k)
