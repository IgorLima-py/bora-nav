package dev.igor.motonav.ui

import dev.igor.motonav.proto.ConfigKey
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The watch preview is a mirror ([MIRROR]): each number in it came from a `.mc`. This test reads the
 * `.mc` files and fails if one side changes without the other, as `WatchSettingsTest` does with the ranges.
 */
class WatchFaceTest {

    private val repo = File("../..")

    private fun source(path: String) = File(repo, path).readText(Charsets.UTF_8)

    /** The right side of `const NAME = ...;` (with or without `static`), without the `as Array<...>`. */
    private fun constant(text: String, file: String, name: String): String =
        Regex("""const $name = (.+?);""").find(text)?.groupValues?.get(1)?.substringBefore(" as ")?.trim()
            ?: error("no `const $name` in $file")

    private fun number(text: String): Double =
        if (text.startsWith("0x")) text.removePrefix("0x").toLong(16).toDouble() else text.toDouble()

    @Test
    fun `the preview numbers are the watch's`() {
        MIRROR.forEach { (file, names) ->
            val text = source(file)
            names.forEach { (name, mirrored) ->
                val raw = constant(text, file, name)
                val label = "$file: $name"
                if (mirrored is List<*>) {
                    val items = raw.removePrefix("[").removeSuffix("]").split(',').map { number(it.trim()) }
                    assertEquals(label, items.size, mirrored.size)
                    items.zip(mirrored).forEach { (raw, ours) -> assertEquals(label, raw, (ours as Number).toDouble(), 1e-6) }
                } else {
                    assertEquals(label, number(raw), (mirrored as Number).toDouble(), 1e-6)
                }
            }
        }
    }

    @Test
    fun `the literals that are not const also match`() {
        val speed = source("watch/source/render/SpeedHud.mc")
        fun font(field: String) =
            Regex("""$field = face\(DesignTokens.FACE_NUMBER, (\d+)""").find(speed)!!.groupValues[1].toInt()
        assertEquals(font("_signFont"), MirrorLiterals.SIGN_FONT)
        assertEquals(font("_distFont"), MirrorLiterals.RADAR_DIST_FONT)

        val cache = source("watch/source/render/StreetCache.mc")
        val minus = Regex("""const EDGE_FROM_LOD = Protocol.CORRIDOR_LOD_COUNT - (\d+);""").find(cache)!!.groupValues[1]
        val lods = constant(source("watch/source/comm/Protocol.mc"), "Protocol.mc", "CORRIDOR_LOD_COUNT").toInt()
        assertEquals(lods - minus.toInt(), MirrorLiterals.EDGE_FROM)
    }

    /** The sign arrow is icon 3 of `TurnGlyphs`, and the sign measures the height of the tallest of them. */
    @Test
    fun `the arrow and the tallest glyph are those of TurnGlyphs`() {
        val glyphs = source("watch/source/render/TurnGlyphs.mc")
        val rows = Regex("""^\s*\[([\d,\s]+)]b,?\s*$""", RegexOption.MULTILINE).findAll(glyphs)
            .map { m -> m.groupValues[1].split(',').map { it.trim().toInt() } }
            .toList()
        val right = Regex("""// 3: ic_turn_right\s*\n\s*\[([\d,\s]+)]b""").find(glyphs)!!.groupValues[1]
            .split(',').map { it.trim().toInt() }
        assertEquals(right, TURN_RIGHT_GLYPH.toList())
        assertTrue("TurnGlyphs has ${rows.size} icons", rows.size > 20)
        assertEquals(rows.maxOf { it[3] - it[1] }, TALLEST_GLYPH)

        val protocol = source("watch/source/comm/Protocol.mc")
        val type = constant(protocol, "Protocol.mc", "TURN_RIGHT").toInt()
        val iconOfType = Regex("""const ICON_OF_TYPE = \[([\d,\s]+)]b""").find(glyphs)!!.groupValues[1]
            .split(',').map { it.trim().toInt() }
        assertEquals("the right turn draws icon 3", 3, iconOfType[type])
    }

    /** The preview font is Android's condensed one: the watch faces have to be Roboto Condensed. */
    @Test
    fun `the watch faces are Roboto Condensed`() {
        val tokens = source("watch/source/render/DesignTokens.mc")
        assertEquals("\"RobotoCondensedRegular\"", constant(tokens, "DesignTokens.mc", "FACE_TEXT"))
        assertEquals("\"RobotoCondensedBold\"", constant(tokens, "DesignTokens.mc", "FACE_NUMBER"))
    }

    /** `Config.commit`: the gray times the brightness, channel by channel, capped at 0xFF. */
    @Test
    fun `the street brightness is the Config calculation`() {
        assertEquals(0x8C7A58, roadColor(0, 100))
        assertEquals(0x463D2C, roadColor(0, 50))
        assertEquals(0xE0C38C, roadColor(0, 160))
        assertEquals(0x768496, roadColor(3, 160))
    }

    @Test
    fun `the control zoom is the NavState one`() {
        assertEquals(1.2f, metersPerPx(emptyMap()))
        assertEquals(0.6f, metersPerPx(mapOf(ConfigKey.ZOOM to 0)))
        assertEquals(5.0f, metersPerPx(mapOf(ConfigKey.ZOOM to 3)))
    }

    /** Every control that lights up a part says in words what it moves. */
    @Test
    fun `whoever lights up a part has a name`() {
        ConfigKey.values().filter { partsOf(it).isNotEmpty() }.forEach {
            assertNotNull("${it.wireName} lights up and has no name", previewPartName(it))
        }
    }
}
