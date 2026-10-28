package dev.igor.motonav.trips

/**
 * **The stop in the middle of the trip** (C16): the longest stretch in which the bike stayed below [SLOW_DMS]
 * **after having already passed it** in this trip. It is what separates the interrupted trip from one that only hit
 * traffic lights, so [PersonalPace] does not learn the pace from it.
 *
 * Below 10 km/h, and not just stopped, because walking with the watch is 5 km/h: on a real lap the rider
 * got off the bike in the middle of the trip, and the track shows ~9 min at walking pace and ~3
 * stopped, 11.7 min in a row below 10 km/h; in the two trips with no stop, the longest stretch was 1.2
 * and 1.6 min (traffic light). The wait before leaving (helmet, gate) does not count: the bike has not moved yet.
 *
 * One per trip: the [TripRecorder] resets it at departure ([reset]).
 */
class PauseMeter {

    private var moved = false
    private var slowSinceT = -1L
    private var lastT = -1L

    /** Seconds of the longest slow stretch since [reset]. */
    var longestS = 0
        private set

    fun reset() {
        moved = false
        slowSinceT = -1L
        lastT = -1L
        longestS = 0
    }

    fun feed(fix: TrackFix) {
        if (fix.t == lastT) {
            return // the same line again (the LOG batch repeats)
        }
        if (fix.t < lastT) {
            slowSinceT = -1L // the watch reopened: the stretch restarts from the new fix
        }
        lastT = fix.t
        if (fix.speedDms >= SLOW_DMS) {
            moved = true
            slowSinceT = -1L
            return
        }
        if (!moved) {
            return
        }
        if (slowSinceT < 0) {
            slowSinceT = fix.t
            return
        }
        longestS = maxOf(longestS, (fix.t - slowSinceT).toInt())
    }

    companion object {
        /** 2.8 m/s (10 km/h), in the track's unit (dm/s). */
        const val SLOW_DMS = 28
    }
}
