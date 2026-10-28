package dev.igor.motonav.trips

import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** A fix from the watch's `trk` line (`TrackBuffer.mc`): `t` in watch seconds, speed in dm/s. */
data class TrackFix(val t: Long, val latE5: Int, val lonE5: Int, val speedDms: Int)

/**
 * The meters traveled, summed from the `trk` lines the watch sends in `LOG` (C16.5, "o log
 * trackeia quantos km rodou?": it did not add up).
 *
 * The watch writes a fix every 5 s (`TrackBuffer.mc`): `trk <t s> <lat E5> <lon E5> <speed dm/s>
 * <heading>`. The simulated lap comes out as `trs` and **does not count**: it is not a street. The calculation is the same as
 * `tools/relatorio.py`'s (`km_ridden`), so the phone's number and the report's match.
 *
 * Three filters, each against an error the track has:
 * - **stopped does not move**: with both speeds below [STOPPED_DMS], the stretch does not add up. GPS
 *   stopped at a traffic light jumps a few meters per fix, and 2 min of signal would add tens of meters;
 * - **a jump does not move**: a stretch faster than [MAX_MPS] is a bad fix or another lap's track;
 * - **time that goes back** (smaller `t`, the watch reopened) restarts from the new fix, without adding.
 */
class TrackOdometer {

    private var lastT = 0L
    private var lastLat = 0
    private var lastLon = 0
    private var lastSpeed = 0
    private var hasLast = false

    /** The meters this line added: 0 for a line that is not `trk`, the first fix or a filtered stretch. */
    fun feed(line: String): Double = parse(line)?.let(::feed) ?: 0.0

    /** The meters this fix added since the previous one: 0 at the first and on a filtered stretch. */
    fun feed(fix: TrackFix): Double {
        val t = fix.t
        val lat = fix.latE5
        val lon = fix.lonE5
        val speed = fix.speedDms
        val had = hasLast
        val dt = t - lastT
        val (pLat, pLon, pSpeed) = Triple(lastLat, lastLon, lastSpeed)
        lastT = t
        lastLat = lat
        lastLon = lon
        lastSpeed = speed
        hasLast = true
        if (!had || dt <= 0) {
            return 0.0
        }
        if (speed < STOPPED_DMS && pSpeed < STOPPED_DMS) {
            return 0.0
        }
        val d = metres(pLat, pLon, lat, lon)
        return if (d / dt > MAX_MPS) 0.0 else d
    }

    companion object {
        /** `trk`, never `trs`: the `TrackBuffer.mc` format, the same regex as `relatorio.py`. */
        private val TRK = Regex("""\btrk (-?\d+) (-?\d+) (-?\d+) (-?\d+) (-?\d+)\s*$""")

        /** The fix of a `trk` line, or `null` for any other (including the simulated lap's `trs`). */
        fun parse(line: String): TrackFix? {
            val m = TRK.find(line) ?: return null
            return TrackFix(
                t = m.groupValues[1].toLong(),
                latE5 = m.groupValues[2].toInt(),
                lonE5 = m.groupValues[3].toInt(),
                speedDms = m.groupValues[4].toInt(),
            )
        }

        /** 1 m/s (3.6 km/h): below this, at both fixes of the stretch, the bike is stopped. A choice, not a measurement. */
        const val STOPPED_DMS = 10

        /** 60 m/s (216 km/h): above this the stretch is a GPS jump. A choice, not a measurement. */
        const val MAX_MPS = 60.0

        private const val EARTH_M = 6_371_000.0

        /** Haversine between two E5 points. */
        fun metres(lat1: Int, lon1: Int, lat2: Int, lon2: Int): Double {
            val p1 = Math.toRadians(lat1 / 1e5)
            val p2 = Math.toRadians(lat2 / 1e5)
            val dp = p2 - p1
            val dl = Math.toRadians((lon2 - lon1) / 1e5)
            val h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
            return 2 * EARTH_M * asin(sqrt(h))
        }
    }
}
