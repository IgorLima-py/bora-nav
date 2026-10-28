package dev.igor.motonav.favorites

import dev.igor.motonav.R
import android.content.Context
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.proto.WireFavorite
import java.io.File
import kotlin.math.abs
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * A favorite (`04 §Favorites`). Without [lat]/[lon] it is a seed that Igor has not yet
 * filled in: it appears in the phone's list and **never** goes to the watch.
 */
@Serializable
data class Favorite(
    /** 0 = no id yet: the storage assigns a new one on save. */
    val id: Int,
    val name: String,
    val lat: Double? = null,
    val lon: Double? = null,
    val icon: Int = 0,
    /** The address the search returned, only for the phone screen; it does not go to the watch. */
    val address: String? = null,
) {
    val hasPlace: Boolean get() = lat != null && lon != null
}

/**
 * Igor's favorites, in a single JSON file in the app's **private**
 * storage (`filesDir`; the manifest has `allowBackup="false"`, so not even Google's
 * backup takes it). His address is sensitive data: it does not go in logs, fixtures
 * or commits (`CLAUDE.md`).
 *
 * Pure, no Android: it takes the [File]. It only runs on the main thread, like the
 * rest of the app, so there is no lock.
 */
/**
 * @param seedNames the three from the first run; [of] passes the ones for the device language (C16.8b).
 */
class FavoritesStore(private val file: File, private val seedNames: List<String> = SEED_NAMES) {

    @Serializable
    private class Snapshot(val nextId: Int, val items: List<Favorite>)

    private var snapshot: Snapshot = load()

    /** The favorites, in the order Igor sees them. */
    fun list(): List<Favorite> = snapshot.items

    fun find(id: Int): Favorite? = snapshot.items.firstOrNull { it.id == id }

    /**
     * Saves [favorite]: with `id` 0 it is new (new id, never reused), with an
     * existing id it replaces. Going past [MAX] items throws [IllegalStateException]:
     * the watch would refuse the whole list.
     */
    fun save(favorite: Favorite): Favorite {
        val existing = snapshot.items.indexOfFirst { it.id == favorite.id && favorite.id != 0 }
        if (existing >= 0) {
            val items = snapshot.items.toMutableList().also { it[existing] = favorite }
            snapshot = Snapshot(snapshot.nextId, items)
            persist()
            return favorite
        }
        check(snapshot.items.size < MAX) { "at most $MAX favorites" }
        // favId is one byte in the protocol (05 §FAVORITES): past 255, it goes back to the smallest free one.
        // With at most MAX items one is always left.
        val id = if (snapshot.nextId <= MAX_FAV_ID) {
            snapshot.nextId
        } else {
            (1..MAX_FAV_ID).first { candidate -> snapshot.items.none { it.id == candidate } }
        }
        val created = favorite.copy(id = id)
        snapshot = Snapshot(snapshot.nextId + 1, snapshot.items + created)
        persist()
        return created
    }

    fun delete(id: Int) {
        snapshot = Snapshot(snapshot.nextId, snapshot.items.filter { it.id != id })
        persist()
    }

    /** What goes in FAVORITES: only those with a place, and with at most [MAX] items. */
    fun wire(): List<WireFavorite> = snapshot.items
        .filter { it.hasPlace }
        .take(MAX)
        .map {
            WireFavorite(
                favId = it.id,
                latE5 = toE5(it.lat!!),
                lonE5 = toE5(it.lon!!),
                name = it.name,
                icon = it.icon,
            )
        }

    private fun load(): Snapshot {
        if (!file.exists()) {
            return seeds()
        }
        return try {
            json.decodeFromString<Snapshot>(file.readText(Charsets.UTF_8))
        } catch (e: Exception) {
            // A truncated file (process killed mid-write) does not take the app down.
            EventLog.w(TAG, "favorites unreadable, back to the initial ones: ${e.javaClass.simpleName}")
            seeds()
        }
    }

    /** Writes to a temp file in the same directory and renames: never leaves half a file. */
    private fun persist() {
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.writeText(json.encodeToString(snapshot), Charsets.UTF_8)
        if (!temp.renameTo(file)) {
            file.delete()
            check(temp.renameTo(file)) { "could not save the favorites" }
        }
    }

    private fun seeds(): Snapshot = Snapshot(
        nextId = seedNames.size + 1,
        items = seedNames.mapIndexed { index, name -> Favorite(id = index + 1, name = name) },
    )

    companion object {
        private const val TAG = "FavoritesStore"

        /** Same as the protocol's `MAX_FAVORITES` (`05 §FAVORITES`). */
        const val MAX = 6
        private const val MAX_FAV_ID = 0xFF

        const val FILE_NAME = "favorites.json"

        /** `04 §Favorites`: Igor fills in the addresses on the first run. */
        private val SEED_NAMES = listOf("Casa", "Academia", "Escritório")

        private val json = Json { ignoreUnknownKeys = true }

        /** The file inside [filesDir] (`Context.filesDir`, private to the app). */
        fun defaultFile(filesDir: File): File = File(filesDir, FILE_NAME)

        @Volatile
        private var instance: FavoritesStore? = null

        /**
         * The process's storage. The edit screen and `NAV_START_REQ` must
         * see the **same** object: the list lives in memory and each instance would read the
         * file once.
         */
        fun of(context: Context): FavoritesStore =
            instance ?: synchronized(this) {
                instance ?: FavoritesStore(
                    defaultFile(context.applicationContext.filesDir),
                    listOf(R.string.fav_seed_home, R.string.fav_seed_gym, R.string.fav_seed_work).map { context.getString(it) },
                ).also { instance = it }
            }

        /** Degrees to 1e-5, rounding halves away from zero (like the packer's `quantize_deg`). */
        fun toE5(degrees: Double): Int {
            val scaled = abs(degrees) * 1e5
            val rounded = Math.floor(scaled + 0.5).toInt()
            return if (degrees < 0) -rounded else rounded
        }
    }
}
