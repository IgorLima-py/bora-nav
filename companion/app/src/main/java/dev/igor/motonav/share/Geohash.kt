package dev.igor.motonav.share

import dev.igor.motonav.route.LatLng

/**
 * Geohash decoder, for Waze's short link (`waze.com/ul/h<geohash>`):
 * the coordinate already comes in the link itself, and decoding avoids the trip to the network
 * (`docs/04 §1`). The cell's center is the point; 9 characters give ~5 m.
 */
object Geohash {

    private const val BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz"

    fun decode(hash: String): LatLng? {
        if (hash.isEmpty()) {
            return null
        }
        var lat = -90.0 to 90.0
        var lon = -180.0 to 180.0
        var evenBit = true // the first bit is longitude
        for (char in hash.lowercase()) {
            val value = BASE32.indexOf(char)
            if (value < 0) {
                return null
            }
            for (shift in 4 downTo 0) {
                val bit = (value shr shift) and 1 == 1
                if (evenBit) {
                    val mid = (lon.first + lon.second) / 2
                    lon = if (bit) mid to lon.second else lon.first to mid
                } else {
                    val mid = (lat.first + lat.second) / 2
                    lat = if (bit) mid to lat.second else lat.first to mid
                }
                evenBit = !evenBit
            }
        }
        return LatLng((lat.first + lat.second) / 2, (lon.first + lon.second) / 2)
    }
}
