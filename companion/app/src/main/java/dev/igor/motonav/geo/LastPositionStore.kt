package dev.igor.motonav.geo

import android.content.Context
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.route.LatLng
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** A position and when it was seen (wall clock, ms). */
data class KnownPosition(val position: LatLng, val atMs: Long) {
    override fun toString(): String = "KnownPosition(em $atMs)"
}

/**
 * The phone's last known position (C16.5), for the favorite the watch
 * asks for when Fused does not answer.
 *
 * On 2026-10-16 the first favorite request arrived with the process freshly
 * thawed and was discarded ("no current position: ignored"), and the watch
 * gave up after 20 s (`DECISIONS.md` §2026-10-16). Starting from an old position is
 * better than not starting: if Igor is somewhere else, the watch asks for a
 * recalculation from its own position as soon as it leaves the route (`OffRoute`, the start).
 *
 * In a file in the app's **private** storage, like the favorites: it is where
 * Igor goes, so it does not go in logs, fixtures or commits (`CLAUDE.md`).
 * Pure, no Android: it takes the [File]. It only runs on the main thread.
 */
class LastPositionStore(private val file: File) {

    @Serializable
    private class Stored(val lat: Double, val lon: Double, val atMs: Long)

    private var cached: KnownPosition? = read()

    fun load(): KnownPosition? = cached

    fun save(position: LatLng, atMs: Long = System.currentTimeMillis()) {
        val known = KnownPosition(position, atMs)
        cached = known
        try {
            val temp = File(file.parentFile, file.name + ".tmp")
            temp.writeText(json.encodeToString(Stored(position.lat, position.lon, atMs)), Charsets.UTF_8)
            if (!temp.renameTo(file)) {
                file.delete()
                temp.renameTo(file)
            }
        } catch (e: Exception) {
            // Stayed in memory: valid until the process dies.
            EventLog.w(TAG, "last position not saved: ${e.javaClass.simpleName}")
        }
    }

    private fun read(): KnownPosition? {
        if (!file.exists()) {
            return null
        }
        return try {
            val stored = json.decodeFromString<Stored>(file.readText(Charsets.UTF_8))
            KnownPosition(LatLng(stored.lat, stored.lon), stored.atMs)
        } catch (e: Exception) {
            EventLog.w(TAG, "last position unreadable: ${e.javaClass.simpleName}")
            null
        }
    }

    companion object {
        private const val TAG = "LastPositionStore"
        const val FILE_NAME = "last_position.json"

        private val json = Json { ignoreUnknownKeys = true }

        /** The file inside [filesDir] (`Context.filesDir`, private to the app). */
        fun defaultFile(filesDir: File): File = File(filesDir, FILE_NAME)

        @Volatile
        private var instance: LastPositionStore? = null

        /** One per process: the writer ([LocationSource]) and the reader (the favorite) see the same one. */
        fun of(context: Context): LastPositionStore =
            instance ?: synchronized(this) {
                instance ?: LastPositionStore(defaultFile(context.applicationContext.filesDir)).also { instance = it }
            }
    }
}
