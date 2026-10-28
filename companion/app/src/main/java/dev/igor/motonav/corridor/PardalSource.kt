package dev.igor.motonav.corridor

import android.content.Context
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.net.textCapped
import dev.igor.motonav.proto.PointE5
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import kotlin.math.roundToInt

/** A speed camera from pardal with a direction: the heading of the traffic it measures, in degrees from north. */
data class PardalCamera(val point: PointE5, val limitKmh: Int, val directionDeg: Int)

/**
 * **The official speed cameras missing from OSM, via pardal** (C16.7b, `06-APIS-DATA.md` §Radares).
 *
 * Pardal (`github.com/Murkiriel/pardal`, ODbL 1.0) merges OSM and the official lists (CET-SP, DER-SP,
 * ANTT, DNIT and others), with the direction the official source gives. On Igor's 20 routes, 19 of the 24
 * CET cameras missing from OSM were in it with a direction (`DECISIONS.md` §"2026-10-27 — C16.7").
 *
 * Only fixed, active cameras with `direction_deg` are kept: without a direction, the watch would warn on both, and on a
 * two-way avenue the one on the other side is as close as the one on the route. The join with OSM belongs to
 * [RadarFilter].
 *
 * The file (857 KB on 2026-10-27) is downloaded at most once every [MAX_AGE_MS] and kept in
 * private storage: the list for all of Brazil does not say where Igor goes, but the file belongs
 * to the app. **No network is never an error**: the old file is used, and without it the list is just OSM's.
 * An attempt that fails, for any reason, waits [RETRY_MS] until the next one.
 */
class PardalSource(
    private val file: File,
    private val download: suspend () -> String = { get(URL) },
    private val now: () -> Long = System::currentTimeMillis,
) {

    /** The file read, keyed by its date: it is 19,762 lines, and every route asks for the list again. */
    @Volatile
    private var memo: Pair<Long, List<PardalCamera>>? = null

    /**
     * When the last download attempt was. The mark on disk survives the app reopening; the one in
     * memory covers when even the mark cannot be written (full disk, vanished folder).
     */
    private val attempt = File(file.parentFile, file.name + ".tentativa")

    @Volatile
    private var triedAt: Long? = null

    /** The cameras from pardal; with [network] false, only what is already on disk. */
    suspend fun cameras(network: Boolean = true): List<PardalCamera> = withContext(Dispatchers.IO) {
        val fresh = file.exists() && now() - file.lastModified() < MAX_AGE_MS
        if (network && !fresh && !triedRecently()) {
            markAttempt()
            refresh()
        }
        if (!file.exists()) {
            return@withContext emptyList()
        }
        val stamp = file.lastModified()
        memo?.takeIf { it.first == stamp }?.let { return@withContext it.second }
        try {
            parse(file.readText(Charsets.UTF_8)).also { memo = stamp to it }
        } catch (e: Exception) {
            EventLog.w(TAG, "pardal unreadable: ${e.javaClass.simpleName}")
            emptyList()
        }
    }

    private fun triedRecently(): Boolean {
        val last = triedAt ?: attempt.takeIf { it.exists() }?.lastModified() ?: return false
        // A phone clock that went back in time does not hold back the next attempt.
        return now() - last in 0 until RETRY_MS
    }

    /** Before the download: a bad response, a write that fails and a body above the cap count the same. */
    private fun markAttempt() {
        triedAt = now()
        try {
            attempt.writeText("")
            attempt.setLastModified(now())
        } catch (e: Exception) {
            EventLog.w(TAG, "attempt mark not saved: ${e.javaClass.simpleName}")
        }
    }

    private suspend fun refresh() {
        val body = try {
            download()
        } catch (e: Exception) {
            EventLog.w(TAG, "pardal not downloaded: ${e.javaClass.simpleName} ${e.message.orEmpty().take(80)}")
            return
        }
        // An error page with a 200 does not erase the good file: the CSV starts with the header.
        if (!body.startsWith(HEADER)) {
            EventLog.w(TAG, "pardal came without the CSV header: ${body.take(60)}")
            return
        }
        try {
            val temp = File(file.parentFile, file.name + ".tmp")
            temp.writeText(body, Charsets.UTF_8)
            temp.setLastModified(now())
            if (!temp.renameTo(file)) {
                file.delete()
                temp.renameTo(file)
            }
            file.setLastModified(now())
            EventLog.i(TAG, "pardal downloaded: ${body.length} B")
        } catch (e: Exception) {
            EventLog.w(TAG, "pardal not saved: ${e.javaClass.simpleName}")
        }
    }

    companion object {
        private const val TAG = "PardalSource"
        const val FILE_NAME = "radares_pardal.csv"
        const val URL = "https://raw.githubusercontent.com/Murkiriel/pardal/main/brasil/radares.csv"

        /** One month: pardal is regenerated when the official sources change, which is monthly (its README). */
        const val MAX_AGE_MS = 30L * 24 * 3600 * 1000

        /**
         * The columns from pardal's README. If they changed there, the new download is refused and the file that was
         * already on disk stays, older and older; without a file, the list is just OSM's.
         */
        const val HEADER = "lat,lng,kind,limit_kmh,source,active,end_lat,end_lng,direction_deg"

        /**
         * One day between failed attempts. A choice: before, a bad response downloaded the 857 KB
         * on every route, up to 4 per route with Overpass down (`RADAR_RETRY_MS`); with one day, it is
         * at most 30 per month in the worst case, and the good file that already exists stays valid.
         */
        const val RETRY_MS = 24L * 3600 * 1000

        /**
         * A choice based on measurement: `brasil/radares.csv` was 856,664 B and 19,762 lines on 2026-10-27;
         * 8 MB fits a pardal ~10 times larger. It is the cap on the expanded text: OkHttp opens the gzip first.
         */
        const val MAX_BODY_BYTES = 8 * 1024 * 1024

        private val http by lazy { OkHttpClient.Builder().build() }

        /** With a cap ([textCapped]): an endless body became `OutOfMemoryError`, which slips past the `catch`es. */
        internal fun get(url: String, client: OkHttpClient = http): String =
            client.newCall(Request.Builder().url(url).header("User-Agent", "BoraNav/1.0").build()).execute().use {
                check(it.isSuccessful) { "HTTP ${it.code} from pardal" }
                checkNotNull(it.textCapped(MAX_BODY_BYTES)) { "pardal response over ${MAX_BODY_BYTES / (1024 * 1024)} MB" }
            }

        /** The fixed, active camera with a direction; the rest, and the line that cannot be read, stay out. */
        fun parse(csv: String): List<PardalCamera> {
            val lines = csv.lineSequence().iterator()
            if (!lines.hasNext() || lines.next().trim() != HEADER) {
                return emptyList()
            }
            val out = ArrayList<PardalCamera>()
            for (line in lines) {
                val f = line.trimEnd().split(',')
                if (f.size < 9 || f[2] != "FIXED" || f[5] != "1" || f[8].isBlank()) {
                    continue
                }
                val lat = f[0].toDoubleOrNull() ?: continue
                val lon = f[1].toDoubleOrNull() ?: continue
                val direction = f[8].toDoubleOrNull() ?: continue
                out.add(
                    PardalCamera(
                        point = PointE5(OverpassClient.quantize(lat), OverpassClient.quantize(lon)),
                        limitKmh = f[3].toIntOrNull()?.takeIf { it in 1..255 } ?: 0,
                        directionDeg = direction.roundToInt().mod(360),
                    ),
                )
            }
            return out
        }

        fun defaultFile(filesDir: File): File = File(filesDir, FILE_NAME)

        @Volatile
        private var instance: PardalSource? = null

        /** One per process, like [RadarStore]. */
        fun of(context: Context): PardalSource =
            instance ?: synchronized(this) {
                instance ?: PardalSource(defaultFile(context.applicationContext.filesDir)).also { instance = it }
            }
    }
}
