package dev.igor.motonav.settings

import dev.igor.motonav.proto.ConfigKey
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The settings screen offers only what the watch accepts: the ranges and defaults
 * here have to be those of `watch/source/Config.mc`, which is the authority
 * (`05 §CONFIG`). This test reads the `.mc` — if someone changes the range there, it
 * fails here, instead of the screen sending a value the watch silently refuses.
 */
class WatchSettingsTest {

    private val repo = File("../..")
    private val config = File(repo, "watch/source/Config.mc").readText(Charsets.UTF_8)
    private val tokens = File(repo, "watch/source/render/DesignTokens.mc").readText(Charsets.UTF_8)

    /** `const NAME = [a, b, ...] as Array<Number>;` -> the list, with the DesignTokens constants resolved. */
    private fun array(name: String): List<Int> {
        val line = Regex("""const $name = \[([^\]]*)\]""").find(config)?.groupValues?.get(1)
            ?: error("no `const $name` in Config.mc")
        return line.split(',').map { item ->
            val text = item.trim()
            text.toIntOrNull() ?: tokenConstant(text.removePrefix("DesignTokens."))
        }
    }

    private fun tokenConstant(name: String): Int =
        Regex("""const $name = (\d+);""").find(tokens)?.groupValues?.get(1)?.toInt()
            ?: error("no `const $name` in DesignTokens.mc")

    @Test
    fun `ranges and defaults match the Config mc`() {
        val mins = array("MINS")
        val maxs = array("MAXS")
        val defaults = array("DEFAULTS")

        assertEquals(ConfigKey.values().size, WatchSettings.all.size)
        WatchSettings.all.forEach { setting ->
            val index = setting.key.id - 1
            assertEquals("${setting.key.wireName}: minimum", mins[index], setting.min)
            assertEquals("${setting.key.wireName}: maximum", maxs[index], setting.max)
            assertEquals("${setting.key.wireName}: default", defaults[index], setting.default)
        }
    }

    @Test
    fun `key names match the Config mc`() {
        val line = Regex("""const NAMES = \[([^\]]*)\]""").find(config)!!.groupValues[1]
        val names = line.split(',').map { it.trim().trim('"') }

        assertEquals(names, WatchSettings.all.map { it.key.wireName })
    }

    @Test
    fun `default is inside the range and the step fits in it`() {
        WatchSettings.all.forEach { s ->
            assertTrue("${s.key.wireName}: default out of range", s.default in s.min..s.max)
            assertEquals("${s.key.wireName}: the step must land on the maximum", 0, (s.max - s.min) % s.step)
            if (s.names.isNotEmpty()) {
                assertEquals("${s.key.wireName}: one name per value", s.max - s.min + 1, s.names.size)
            }
        }
    }

    @Test
    fun `entries sends the sixteen keys in id order`() {
        val entries = WatchSettings.entries(mapOf(ConfigKey.LEAD_S to 10))

        assertEquals(22, entries.size)
        assertEquals((1..22).toList(), entries.map { it.first })
        assertEquals(10, entries[0].second)
        // A key the screen did not touch goes with the default.
        assertEquals(80, entries[1].second)
    }

    @Test
    fun `the screen groups show each key once, all but the bench levers`() {
        val keys = WatchSettings.sections.flatMap { it.keys }
        assertEquals(ConfigKey.VIBE_ON, keys.first())
        assertEquals(keys.size, keys.toSet().size)
        assertEquals(ConfigKey.values().toSet() - WatchSettings.bench, keys.toSet())
    }

    @Test
    fun `effective size multiplies by the overall and stops at the watch limit`() {
        val values = WatchSettings.defaults()
        assertEquals(100, WatchSettings.effectivePct(values, ConfigKey.DIST_PCT))
        assertEquals(80, WatchSettings.effectivePct(values + (ConfigKey.HUD_PCT to 80), ConfigKey.DIST_PCT))
        // 112 x 112 = 125, but the watch stops at the ceiling.
        val top = values + mapOf(ConfigKey.HUD_PCT to 112, ConfigKey.DIST_PCT to 112)
        assertEquals(WatchSettings.of(ConfigKey.HUD_PCT).max, WatchSettings.effectivePct(top, ConfigKey.DIST_PCT))
    }

    @Test
    fun `near_m greater or equal to lead_min_m is a conflict the watch would refuse`() {
        // 05 §CONFIG and Config.mc merge: the whole message is refused (and the ACK goes out anyway).
        assertEquals(null, WatchSettings.conflict(WatchSettings.defaults()))
        assertEquals(null, WatchSettings.conflict(mapOf(ConfigKey.LEAD_MIN_M to 30, ConfigKey.NEAR_M to 25)))
        assertTrue(WatchSettings.conflict(mapOf(ConfigKey.LEAD_MIN_M to 30, ConfigKey.NEAR_M to 30)) != null)
        assertTrue(WatchSettings.conflict(mapOf(ConfigKey.LEAD_MIN_M to 40, ConfigKey.NEAR_M to 50)) != null)
        // Only one of the two touched: the other comes in with the default (near 25 / lead_min 80).
        assertTrue(WatchSettings.conflict(mapOf(ConfigKey.LEAD_MIN_M to 20)) != null)
    }
}
