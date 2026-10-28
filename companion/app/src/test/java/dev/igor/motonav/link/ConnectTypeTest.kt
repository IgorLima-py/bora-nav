package dev.igor.motonav.link

import dev.igor.motonav.BuildConfig
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which transport each variant uses (C7a). Only `sim` talks to the Connect IQ
 * simulator (`TETHERED`, via `adb forward tcp:7381`); `debug` and `release` are
 * what goes to the S25 and talk to the watch through Garmin Connect (`WIRELESS`).
 * A `debug` on `TETHERED` on Igor's phone would find no watch at all, and the
 * on-screen error would send the search to the wrong place.
 *
 * A `testDebugUnitTest` only sees the debug `BuildConfig`. For the three
 * variants to come out of a single run, gradle generates the `BuildConfig` of all of them
 * before the test and passes the folder in `motonav.buildConfigDir`.
 */
class ConnectTypeTest {

    @Test
    fun `only the sim variant talks to the simulator`() {
        assertEquals(false, tethered("debug"))
        assertEquals(false, tethered("release"))
        assertEquals(true, tethered("sim"))
    }

    @Test
    fun `the running variant agrees with its build type`() {
        assertEquals(BuildConfig.BUILD_TYPE == "sim", BuildConfig.CIQ_TETHERED)
    }

    private fun tethered(variant: String): Boolean {
        val root = System.getProperty("motonav.buildConfigDir")
            ?: error("motonav.buildConfigDir missing: run through gradle (app/build.gradle.kts)")
        val file = File(root, "$variant/dev/igor/motonav/BuildConfig.java")
        assertTrue("BuildConfig of $variant was not generated: $file", file.exists())
        val match = FIELD.find(file.readText())
            ?: error("$variant does not declare CIQ_TETHERED in $file")
        return match.groupValues[1].toBoolean()
    }

    private companion object {
        val FIELD = Regex("""boolean CIQ_TETHERED = (true|false);""")
    }
}
