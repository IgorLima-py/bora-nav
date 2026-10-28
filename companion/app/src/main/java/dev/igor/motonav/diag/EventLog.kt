package dev.igor.motonav.diag

import android.content.Context
import android.util.Log
import dev.igor.motonav.BuildConfig
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Debug-phase log: goes to logcat **and** to a file in
 * `getExternalFilesDir`, from where it comes out with an `adb pull`.
 *
 * Logcat vanishes (circular buffer, and it has already swallowed test rounds while
 * Igor was coming back from the road). The file survives the whole test, even when the
 * phone sits in a pocket for an hour before going back to the cable:
 *
 * ```
 * adb pull /sdcard/Android/data/dev.igor.motonav/files/motonav.log
 * ```
 *
 * Rules: no secrets (the Mapbox token goes through `redact` first), a single
 * line per event and rotation at [MAX_BYTES] so it does not grow endlessly.
 */
object EventLog {

    private const val MAX_BYTES = 512 * 1024
    private val stamp = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)
    private val lock = Any()

    private var file: File? = null

    /** Idempotent: each activity calls it in `onCreate` without coordinating. */
    fun init(context: Context) {
        var started = false
        synchronized(lock) {
            if (file != null) {
                return
            }
            file = try {
                File(context.getExternalFilesDir(null), "motonav.log").also { rotateIfBig(it) }
            } catch (e: Exception) {
                Log.w("EventLog", "no log file: ${e.message}")
                null
            }
            // One line per **process**, not per Activity: each screen calls
            // `init` in `onCreate`, and one line per call made a second
            // share look like a new process. The pid is what
            // `tools/e2e.py --dupla` checks: both shares must be
            // under the same line (C8).
            started = true
        }
        if (started) {
            i("EventLog", "--- session ${BuildConfig.VERSION_NAME} pid ${android.os.Process.myPid()} ---")
        }
    }

    /**
     * Place, address or searched text: only the `sim` variant writes it (public places on the emulator,
     * which `tools/e2e.py` checks). Outside it, this is the home of whoever uses it, in a file that leaves the phone.
     */
    fun place(text: String): String = if (BuildConfig.CIQ_TETHERED) text else "(omitido)"

    fun i(tag: String, message: String) {
        Log.i(tag, message)
        append("I", tag, message)
    }

    fun w(tag: String, message: String, error: Throwable? = null) {
        Log.w(tag, message, error)
        append("W", tag, if (error == null) message else "$message — ${error.javaClass.simpleName}: ${error.message}")
    }

    fun e(tag: String, message: String, error: Throwable? = null) {
        Log.e(tag, message, error)
        append("E", tag, if (error == null) message else "$message — ${error.javaClass.simpleName}: ${error.message}")
    }

    private fun append(level: String, tag: String, message: String) {
        val target = synchronized(lock) { file } ?: return
        try {
            synchronized(lock) {
                target.appendText("${stamp.format(Date())} $level $tag: $message\n")
            }
        } catch (e: Exception) {
            Log.w("EventLog", "failed to write to log: ${e.message}")
        }
    }

    /** Keeps at most the current file + one previous. */
    private fun rotateIfBig(target: File) {
        if (target.exists() && target.length() > MAX_BYTES) {
            val previous = File(target.parentFile, "${target.name}.1")
            previous.delete()
            target.renameTo(previous)
        }
    }
}
