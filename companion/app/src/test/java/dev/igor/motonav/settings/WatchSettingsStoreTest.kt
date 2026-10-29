package dev.igor.motonav.settings

import android.content.Context
import dev.igor.motonav.proto.ConfigKey
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** What the "Watch settings" screen starts from: the last send, minus the bench levers. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class WatchSettingsStoreTest {

    private val context = RuntimeEnvironment.getApplication()

    // prevents: the street lever saved by phone 1.4.2 going back to the watch in the next CONFIG, and the "D2"
    // staying on the map after the lever left the screen (2026-10-29).
    @Test
    fun `a saved bench lever loads as the default and a riding setting keeps its value`() {
        context.getSharedPreferences("motonav_watch_settings", Context.MODE_PRIVATE).edit()
            .putInt(ConfigKey.STREET_DIAG.wireName, 2)
            .putInt(ConfigKey.MAP_TILT.wireName, 0)
            .putInt(ConfigKey.LEAD_S.wireName, 10)
            .commit()

        val loaded = WatchSettingsStore(context).load()

        assertEquals(0, loaded[ConfigKey.STREET_DIAG])
        assertEquals(1, loaded[ConfigKey.MAP_TILT])
        assertEquals(10, loaded[ConfigKey.LEAD_S])
        WatchSettings.bench.forEach { assertEquals(it.name, WatchSettings.of(it).default, loaded[it]) }
    }
}
