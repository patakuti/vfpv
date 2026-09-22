class_name SolarPosition
extends RefCounted

# NOAA solar position algorithm (elevation/azimuth of the sun from
# latitude/longitude/UTC time). Reference:
# https://gml.noaa.gov/grad/solcalc/solareqns.PDF
#
# Verified against known reference facts (see scripts note in
# real_terrain_manager.gd / project docs): at the equinox, sunset azimuth is
# ~270 deg (due west) at any latitude; in the northern hemisphere summer it
# swings north of west, in winter south of west.

static func _day_of_year(year: int, month: int, day: int) -> int:
	var jan1 := Time.get_unix_time_from_datetime_dict({"year": year, "month": 1, "day": 1, "hour": 0, "minute": 0, "second": 0})
	var target := Time.get_unix_time_from_datetime_dict({"year": year, "month": month, "day": day, "hour": 0, "minute": 0, "second": 0})
	return int(round((target - jan1) / 86400.0)) + 1

# Returns {elevation_deg, azimuth_deg} of the sun for the given lat/lon at
# the given UTC date + hour (float, 0-24). azimuth_deg is compass bearing
# (0 = north, 90 = east, clockwise).
static func position(lat_deg: float, lon_deg: float, year: int, month: int, day: int, hour_utc: float) -> Dictionary:
	var n := _day_of_year(year, month, day)
	var gamma := 2.0 * PI / 365.0 * (n - 1 + (hour_utc - 12.0) / 24.0)

	var eqtime := 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
		- 0.014615 * cos(2.0 * gamma) - 0.040849 * sin(2.0 * gamma))
	var decl := (0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
		- 0.006758 * cos(2.0 * gamma) + 0.000907 * sin(2.0 * gamma)
		- 0.002697 * cos(3.0 * gamma) + 0.00148 * sin(3.0 * gamma))

	var time_offset := eqtime + 4.0 * lon_deg
	var true_solar_time := hour_utc * 60.0 + time_offset
	var hour_angle_deg := (true_solar_time / 4.0) - 180.0

	var lat := deg_to_rad(lat_deg)
	var ha := deg_to_rad(hour_angle_deg)

	var cos_zenith: float = clamp(sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(ha), -1.0, 1.0)
	var zenith := acos(cos_zenith)
	var elevation_deg := 90.0 - rad_to_deg(zenith)

	var azimuth_deg: float = 0.0
	if sin(zenith) > 0.0001:
		var cos_az: float = clamp((sin(decl) - sin(lat) * cos(zenith)) / (cos(lat) * sin(zenith)), -1.0, 1.0)
		var az := rad_to_deg(acos(cos_az))
		azimuth_deg = (360.0 - az) if hour_angle_deg > 0.0 else az

	return {"elevation_deg": elevation_deg, "azimuth_deg": azimuth_deg}

# Scans the given UTC date (minute resolution) for the moment the sun
# descends through target_elevation_deg in the evening — i.e. the real sun
# position for an actual golden-hour moment on this date at this location.
# Falls back to local solar noon if no such crossing exists that day
# (e.g. polar day/night at extreme latitudes).
static func find_evening_elevation(lat_deg: float, lon_deg: float, year: int, month: int, day: int, target_elevation_deg: float) -> Dictionary:
	var prev_elev: float = 999.0
	var result: Dictionary = {}
	for minute in range(0, 24 * 60):
		var hour_utc: float = minute / 60.0
		var pos := position(lat_deg, lon_deg, year, month, day, hour_utc)
		var elev: float = pos["elevation_deg"]
		if prev_elev > target_elevation_deg and elev <= target_elevation_deg:
			result = pos
		prev_elev = elev
	if result.is_empty():
		result = position(lat_deg, lon_deg, year, month, day, 12.0 - lon_deg / 15.0)
	return result
