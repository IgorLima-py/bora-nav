package dev.igor.motonav.route

import dev.igor.motonav.proto.PointE5
import dev.igor.motonav.proto.Protocol
import dev.igor.motonav.proto.Turn
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.math.abs

/**
 * Turns a Mapbox Directions response into a [RouteResult].
 *
 * Pure parsing, no network: the unit tests run it against
 * tools/fixtures/route_sample.json (an OSRM response, same v5 format) and compare the packed bytes with the
 * vectors produced by tools/packer.py, which implements the very same rules.
 */
object MapboxRouteParser {

    private val json = Json { ignoreUnknownKeys = true }

    fun parse(body: String, destNameOverride: String? = null): RouteResult {
        val response = json.decodeFromString<MbResponse>(body)
        val route = response.routes.firstOrNull()
            ?: throw RouteException("Mapbox returned no route")

        val points = decodePolyline6E6(route.geometry).map { (lat, lon) ->
            PointE5(quantizeE6(lat), quantizeE6(lon))
        }
        if (points.size > Protocol.MAX_POLY_POINTS) {
            throw RouteException(
                "${points.size} points exceed the ${Protocol.MAX_POLY_POINTS} cap (05 §ROUTE_POLY)",
            )
        }

        val turns = mutableListOf<Turn>()
        val stopIdx = mutableListOf<Int>()
        var cursor = 0
        route.legs.forEachIndexed { legNo, leg ->
            leg.steps.forEachIndexed { stepNo, step ->
                val location = step.maneuver.location
                // The `depart` of a leg that is not the first repeats the `arrive` of the
                // previous one: in the middle of the route it would be a meaningless "exit" arrow.
                val repeatedDepart = legNo > 0 && stepNo == 0 && step.maneuver.type.lowercase() == "depart"
                if (location.size >= 2 && !repeatedDepart) {
                    val target = PointE5(quantizeDeg(location[1]), quantizeDeg(location[0]))
                    cursor = nearestIndex(points, target, cursor)
                    // The banner of step i describes the maneuver of step i+1: the roundabout exit
                    // angle is in the previous step (05 §TURNS).
                    val degrees = if (stepNo > 0) bannerDegrees(leg.steps[stepNo - 1]) else null
                    turns += Turn(
                        pointIdx = cursor,
                        type = maneuverToTurnType(step.maneuver, degrees, step.drivingSide.lowercase()),
                        streetName = streetNameOf(step),
                        exitNum = step.maneuver.exit ?: 0,
                    )
                }
            }
            if (legNo < route.legs.size - 1) {
                stopIdx += cursor
            }
        }

        val destName = destNameOverride
            ?: response.waypoints.lastOrNull()?.name?.takeIf { it.isNotBlank() }
            ?: "Destino"

        return RouteResult(
            points = points,
            turns = turns,
            distanceM = Math.round(route.distance).toInt(),
            durationS = Math.round(route.duration).toInt(),
            destName = destName,
            stopIdx = stopIdx,
        )
    }

    /**
     * 1e-6 degrees -> protocol units (1e-5), halves away from zero.
     * Integer-only on purpose: Kotlin and Python must agree on every tie, and
     * one in ten polyline6 coordinates is one. Mirrors packer.quantize_e6.
     */
    fun quantizeE6(microdeg: Int): Int {
        val magnitude = (abs(microdeg) + 5) / 10
        return if (microdeg < 0) -magnitude else magnitude
    }

    /** Degrees as a JSON double -> protocol units. Mirrors packer.quantize_deg. */
    fun quantizeDeg(degrees: Double): Int {
        val value = (abs(degrees) * 1e5 + 0.5).toInt()
        return if (degrees < 0) -value else value
    }

    /** Decodes a `polyline6` geometry into (lat, lon) microdegrees. */
    fun decodePolyline6E6(encoded: String): List<Pair<Int, Int>> {
        val points = mutableListOf<Pair<Int, Int>>()
        var index = 0
        var lat = 0
        var lon = 0
        while (index < encoded.length) {
            repeat(2) { axis ->
                var shift = 0
                var result = 0
                while (true) {
                    val byte = encoded[index].code - 63
                    index++
                    result = result or ((byte and 0x1F) shl shift)
                    shift += 5
                    if (byte < 0x20) {
                        break
                    }
                }
                val delta = if (result and 1 != 0) (result shr 1).inv() else result shr 1
                if (axis == 0) lat += delta else lon += delta
            }
            points += lat to lon
        }
        return points
    }

    /**
     * Maps a Mapbox maneuver to a protocol turn type (05 §TURNS). [degrees] is the roundabout
     * exit angle from the previous step's banner; without it, or where traffic keeps left and
     * the ring turns clockwise, a roundabout stays type 9. Mirrors packer.maneuver_to_turn_type.
     */
    fun maneuverToTurnType(maneuver: MbManeuver, degrees: Double? = null, drivingSide: String = "right"): Int {
        val modifier = maneuver.modifier.lowercase()
        val left = "left" in modifier
        val right = "right" in modifier
        return when (maneuver.type.lowercase()) {
            "depart" -> Protocol.TURN_DEPART
            "arrive" -> when {
                left -> Protocol.TURN_ARRIVE_LEFT
                right -> Protocol.TURN_ARRIVE_RIGHT
                else -> Protocol.TURN_ARRIVE
            }
            "roundabout", "rotary", "roundabout turn" ->
                if (degrees == null || drivingSide == "left") Protocol.TURN_ROUNDABOUT
                else Protocol.roundaboutByDegrees(degrees)
            "exit roundabout", "exit rotary" -> Protocol.TURN_STRAIGHT
            "on ramp" -> if (left) Protocol.TURN_HIGHWAY_ENTER_LEFT else Protocol.TURN_HIGHWAY_ENTER
            "off ramp" -> if (left) Protocol.TURN_HIGHWAY_EXIT_LEFT else Protocol.TURN_HIGHWAY_EXIT
            "fork" -> when {
                left -> Protocol.TURN_FORK_LEFT
                right -> Protocol.TURN_FORK_RIGHT
                else -> Protocol.TURN_STRAIGHT
            }
            "merge" -> when {
                left -> Protocol.TURN_MERGE_LEFT
                right -> Protocol.TURN_MERGE_RIGHT
                else -> Protocol.TURN_MERGE
            }
            "new name", "notification" -> Protocol.TURN_NEW_NAME
            else -> MODIFIER_TO_TURN[modifier] ?: Protocol.TURN_STRAIGHT
        }
    }

    /** The first `primary.degrees` of a step's banners: the exit angle of the **next** maneuver. */
    fun bannerDegrees(step: MbStep): Double? =
        step.bannerInstructions.firstNotNullOfOrNull { it.primary?.degrees }

    /**
     * Name of the road this step runs on, or "" when it has none.
     * The banner text is only accepted when it fits the field whole — for
     * unnamed roads Mapbox puts a full instruction sentence there. See
     * docs/DECISIONS.md.
     */
    fun streetNameOf(step: MbStep): String {
        step.name.trim().takeIf { it.isNotEmpty() }?.let { return it }
        step.ref.trim().takeIf { it.isNotEmpty() }?.let { return it }
        step.destinations.trim().takeIf { it.isNotEmpty() }?.let { return it }
        val banner = step.bannerInstructions.firstOrNull()?.primary?.text?.trim().orEmpty()
        if (banner.isNotEmpty() &&
            banner.toByteArray(Charsets.UTF_8).size <= Protocol.MAX_STREET_NAME_BYTES
        ) {
            return banner
        }
        return ""
    }

    /**
     * Index of the polyline point closest to [target], scanning forward from
     * [start]. Maneuver locations are snapped to the route, so a monotonic scan
     * is correct and needs no projection.
     *
     * Stops at the **first** point within at most 1 E5 unit on each axis (C11): a
     * stop in the middle of a street is reached and left along the same street, the polyline
     * passes through it twice, and the nearer of the two could be the one on the way back —
     * skipping all the maneuvers in between. Mirrors the packer's `_nearest_index`.
     */
    private fun nearestIndex(points: List<PointE5>, target: PointE5, start: Int): Int {
        var bestIdx = start
        var bestDist = Long.MAX_VALUE
        for (i in start until points.size) {
            val dLat = (points[i].lat - target.lat).toLong()
            val dLon = (points[i].lon - target.lon).toLong()
            val dist = dLat * dLat + dLon * dLon
            if (dist < bestDist) {
                bestDist = dist
                bestIdx = i
            }
            if (abs(dLat) <= 1 && abs(dLon) <= 1) {
                return i
            }
        }
        return bestIdx
    }

    private val MODIFIER_TO_TURN = mapOf(
        "uturn" to Protocol.TURN_UTURN,
        "sharp right" to Protocol.TURN_SHARP_RIGHT,
        "right" to Protocol.TURN_RIGHT,
        "slight right" to Protocol.TURN_SLIGHT_RIGHT,
        "straight" to Protocol.TURN_STRAIGHT,
        "slight left" to Protocol.TURN_SLIGHT_LEFT,
        "left" to Protocol.TURN_LEFT,
        "sharp left" to Protocol.TURN_SHARP_LEFT,
    )
}

// --- Mapbox Directions DTOs (only the fields we consume) ---------------------

@Serializable
data class MbResponse(
    val routes: List<MbRoute> = emptyList(),
    val waypoints: List<MbWaypoint> = emptyList(),
)

@Serializable
data class MbRoute(
    val distance: Double = 0.0,
    val duration: Double = 0.0,
    val geometry: String = "",
    val legs: List<MbLeg> = emptyList(),
)

@Serializable
data class MbLeg(val steps: List<MbStep> = emptyList())

@Serializable
data class MbStep(
    val name: String = "",
    val ref: String = "",
    val destinations: String = "",
    val maneuver: MbManeuver = MbManeuver(),
    @SerialName("bannerInstructions") val bannerInstructions: List<MbBanner> = emptyList(),
    @SerialName("driving_side") val drivingSide: String = "right",
)

@Serializable
data class MbManeuver(
    val type: String = "",
    val modifier: String = "",
    val location: List<Double> = emptyList(),
    val exit: Int? = null,
)

@Serializable
data class MbBanner(val primary: MbBannerText? = null)

@Serializable
data class MbBannerText(
    val text: String = "",
    /** Counterclockwise arc to the roundabout exit, 180 = straight ahead (only on a roundabout banner). */
    val degrees: Double? = null,
)

@Serializable
data class MbWaypoint(val name: String = "")
