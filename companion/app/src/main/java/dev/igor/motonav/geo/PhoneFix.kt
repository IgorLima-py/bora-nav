package dev.igor.motonav.geo

import kotlin.math.ceil
import kotlin.math.roundToInt

/**
 * A position from the phone's GPS on its way to the watch (`05 §PHONE_FIX`, C13b), already in
 * protocol units.
 *
 * @property speedDms speed in dm/s, the unit of the watch's `trk` line.
 * @property headingDeg heading in degrees, 0..359, or `null` if Android gave none
 *   (phone stationary).
 * @property accuracyM accuracy radius in meters; 0xFFFF when Android did not say,
 *   which the watch treats as a weak fix.
 * @property fixElapsedMs the `elapsedRealtime` at which Android obtained the fix. The age
 *   that goes on the wire is computed **at send time**: the fix may wait its turn behind
 *   a corridor chunk.
 */
data class PhoneFix(
    val latE5: Int,
    val lonE5: Int,
    val speedDms: Int,
    val headingDeg: Int?,
    val accuracyM: Int,
    val fixElapsedMs: Long,
) {
    /**
     * Without the coordinate: it is Igor's position, and a `$fix` forgotten in a
     * log line would carry it into `motonav.log` (08 §Conventions).
     */
    override fun toString(): String = "PhoneFix(accuracy $accuracyM m)"

    companion object {
        /**
         * From what Android's `Location` carries. `null` for what is not a place
         * (latitude or longitude outside the globe, or `NaN`). The three optionals are
         * `null` when the `Location` does not have them (`hasSpeed`, `hasBearing`,
         * `hasAccuracy`).
         */
        fun of(
            latitude: Double,
            longitude: Double,
            speedMps: Float?,
            bearingDeg: Float?,
            accuracyM: Float?,
            fixElapsedMs: Long,
        ): PhoneFix? {
            // `NaN in a..b` is false, so the range also rejects NaN.
            if (latitude !in -90.0..90.0 || longitude !in -180.0..180.0) {
                return null
            }
            val speed = speedMps?.takeIf { it.isFinite() && it > 0f } ?: 0f
            return PhoneFix(
                latE5 = (latitude * 1e5).roundToInt(),
                lonE5 = (longitude * 1e5).roundToInt(),
                speedDms = (speed * 10f).roundToInt().coerceAtMost(0xFFFF),
                headingDeg = bearingDeg?.takeIf { it.isFinite() }?.let { ((it.roundToInt() % 360) + 360) % 360 },
                accuracyM = accuracyM?.takeIf { it.isFinite() && it >= 0f }
                    ?.let { ceil(it).toInt().coerceAtMost(0xFFFF) } ?: 0xFFFF,
                fixElapsedMs = fixElapsedMs,
            )
        }
    }
}
