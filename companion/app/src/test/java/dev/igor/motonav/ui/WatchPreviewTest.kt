package dev.igor.motonav.ui

import android.graphics.Bitmap
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.font.createFontFamilyResolver
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import dev.igor.motonav.proto.ConfigKey
import dev.igor.motonav.settings.WatchSettings
import java.io.File
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The preview drawn on a 454 px bitmap, one phone px per glass px: what is in each
 * place, and what each setting moves. The expected positions are the watch's (`MapRenderer`,
 * `SpeedHud`, `Hud`); where they depend on the text width, the math comes from the box the drawing
 * annotated. With `MOTONAV_TELAS=1` it writes the photos to `app/build/screens/preview-*.png`.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34])
class WatchPreviewTest {

    private class Frame(val bitmap: Bitmap, val boxes: Map<Part, Rect>) {
        fun at(x: Number, y: Number): Int = bitmap.getPixel(x.toInt(), y.toInt()) and 0xFFFFFF
        fun box(part: Part): Rect = boxes.getValue(part)
    }

    private fun frame(changes: Map<ConfigKey, Int> = emptyMap()): Frame {
        val density = Density(1f)
        val measurer = TextMeasurer(
            createFontFamilyResolver(RuntimeEnvironment.getApplication()),
            density,
            LayoutDirection.Ltr,
        )
        val image = ImageBitmap(GLASS.toInt(), GLASS.toInt())
        val boxes = mutableMapOf<Part, Rect>()
        CanvasDrawScope().draw(density, LayoutDirection.Ltr, Canvas(image), Size(GLASS, GLASS)) {
            drawWatchFace(measurer, WatchSettings.defaults() + changes, boxes)
        }
        return Frame(image.asAndroidBitmap(), boxes)
    }

    private fun hex(color: Int) = "%06X".format(color)

    private fun near(label: String, expected: Int, actual: Int, tolerance: Int = 24) {
        val ok = (0..2).all { i -> abs(((expected shr (8 * i)) and 0xFF) - ((actual shr (8 * i)) and 0xFF)) <= tolerance }
        assertTrue("$label: expected ${hex(expected)}, got ${hex(actual)}", ok)
    }

    private fun far(label: String, color: Int, actual: Int) {
        val same = (0..2).all { i -> abs(((color shr (8 * i)) and 0xFF) - ((actual shr (8 * i)) and 0xFF)) <= 24 }
        assertFalse("$label: should not be ${hex(color)}", same)
    }

    @Test
    fun `the rider and the route are where the MapRenderer puts them`() {
        val f = frame()
        // The cyan ring of radius 22 around the anchor (227, 330), and the blue route just ahead.
        near("rider ring", 0x2FD3FF, f.at(227 + 22, 330))
        near("halo", 0x12303B, f.at(227 + 12, 330 + 12))
        near("arrow tip", 0xFFFFFF, f.at(227, 330))
        near("route ahead", 0x4C8DF6, f.at(227, 290))
    }

    @Test
    fun `the street sign and the Hud one`() {
        val f = frame()
        val plate = f.box(Part.PLATE)
        assertEquals("the plate is centered", 227f, plate.center.x, 1f)
        // Cutouts and sign in the Hud order: the time, the 10 px gap, the sign; the arrival below.
        assertTrue(plate.top >= f.box(Part.CLOCK).bottom + 6 + 10)
        assertTrue(f.box(Part.TIME).top > plate.bottom)
        near("plate background", 0x0B5A73, f.at(plate.left + 2, plate.top + 2))
        near("2 px frame, 5 px from the edge", 0xFFFFFF, f.at(plate.left + 6, plate.center.y))
        near("fundo entre a moldura e o texto", 0x0B5A73, f.at(plate.left + 8, plate.center.y))
        // The arrow, the number and the unit on one line, the name below, inside the sign.
        listOf(Part.ARROW, Part.DIST, Part.STREET).forEach {
            assertTrue("$it outside the plate", plate.contains(f.box(it).center))
        }
        assertTrue(f.box(Part.ARROW).right < f.box(Part.DIST).left)
        assertTrue(f.box(Part.DIST).bottom <= f.box(Part.STREET).top + 2)
    }

    @Test
    fun `the radar has the ring, the sign and the SpeedHud distance`() {
        val f = frame()
        near("edge ring", 0xE53935, f.at(227, 1))
        near("plate rim", 0xE53935, f.at(74 - 27, 238))
        near("plate core", 0xFFFFFF, f.at(74 - 20, 238))
        val radar = f.box(Part.RADAR)
        assertEquals(74f, radar.center.x, 1f)
        assertEquals(238f - 33f, radar.top, 0.5f)
        // The radar icon on the map, 120 m along the route: tilted, 120 / 1.2 × 0.72 = 72 px above the rider.
        near("radar on the map", 0xE53935, f.at(227 + 11, 330 - 72))
    }

    @Test
    fun `the overall size and that of each part move as on the watch`() {
        val normal = frame()
        val small = frame(mapOf(ConfigKey.HUD_PCT to 63))
        val big = frame(mapOf(ConfigKey.HUD_PCT to 112))
        assertTrue(big.box(Part.PLATE).width > normal.box(Part.PLATE).width)
        assertTrue(small.box(Part.PLATE).width < normal.box(Part.PLATE).width)
        assertTrue(big.box(Part.TIME).height > normal.box(Part.TIME).height)

        // The distance moves only the number: the time and the arrival stay where they were.
        val dist = frame(mapOf(ConfigKey.DIST_PCT to 112))
        assertTrue(dist.box(Part.DIST).height > normal.box(Part.DIST).height)
        assertEquals(normal.box(Part.CLOCK), dist.box(Part.CLOCK))
        assertEquals(normal.box(Part.TIME), dist.box(Part.TIME))

        // The watch ceiling (`Config.groupPct`): 112 × 112 % draws the same as 112 %.
        val capped = frame(mapOf(ConfigKey.HUD_PCT to 112, ConfigKey.DIST_PCT to 112))
        assertEquals(big.box(Part.DIST), capped.box(Part.DIST))
    }

    @Test
    fun `the sign breathing room moves the frame and not the letters`() {
        val tight = frame(mapOf(ConfigKey.PLATE_W_PCT to 0))
        val wide = frame(mapOf(ConfigKey.PLATE_W_PCT to 100))
        // On the sides: from 20 px to 9 (the frame, the thread and 2 px), on each side.
        assertEquals(2 * (20 - 9).toFloat(), wide.box(Part.PLATE).width - tight.box(Part.PLATE).width, 1f)
        assertEquals(wide.box(Part.DIST).height, tight.box(Part.DIST).height)

        val low = frame(mapOf(ConfigKey.PLATE_H_PCT to 0))
        val tall = frame(mapOf(ConfigKey.PLATE_H_PCT to 100))
        assertTrue(tall.box(Part.PLATE).height > low.box(Part.PLATE).height)
    }

    @Test
    fun `the orbit reserves the edge margin`() {
        val still = frame(mapOf(ConfigKey.ORBIT_PX to 0))
        val moving = frame(mapOf(ConfigKey.ORBIT_PX to 6))
        assertTrue(moving.box(Part.CLOCK).top >= still.box(Part.CLOCK).top + 6)
        assertTrue(moving.box(Part.PLATE).top > still.box(Part.PLATE).top)
        assertTrue(moving.box(Part.TIME).bottom < still.box(Part.TIME).bottom)
    }

    @Test
    fun `the tilted map and the zoom move the route`() {
        // Paulista (the leg of the route to the right) at 200 m: 200 / 1.2 = 167 px; tilted, × 0.72.
        near("deitado, 1,2 m/px", 0x4C8DF6, frame().at(227 + 60, 330 - 120))
        // At 2.5 m/px, 80 px flat and 58 tilted.
        val flat = frame(mapOf(ConfigKey.ZOOM to 2, ConfigKey.MAP_TILT to 0))
        val tilted = frame(mapOf(ConfigKey.ZOOM to 2))
        near("plano, 2,5 m/px", 0x4C8DF6, flat.at(227 + 60, 330 - 80))
        far("flat, 2.5 m/px, at the tilted height", 0x4C8DF6, flat.at(227 + 60, 330 - 58))
        near("deitado, 2,5 m/px", 0x4C8DF6, tilted.at(227 + 60, 330 - 58))
        far("tilted, 2.5 m/px, at the flat height", 0x4C8DF6, tilted.at(227 + 60, 330 - 80))
    }

    @Test
    fun `the street brightness is the Config one`() {
        // The local street 110 m to the right of the route, behind the rider: x = 227 + 110 / 1.2.
        near("100 %", 0x4A535E, frame().at(319, 355), tolerance = 8)
        near("160 %", 0x768496, frame(mapOf(ConfigKey.CORRIDOR_PCT to 160)).at(319, 355), tolerance = 8)
    }

    @Test
    fun `preview photos`() {
        assumeTrue(System.getenv("MOTONAV_TELAS") == "1")
        mapOf(
            "padrao" to emptyMap(),
            "plano" to mapOf(ConfigKey.MAP_TILT to 0),
            "zoom-2" to mapOf(ConfigKey.ZOOM to 2),
            "grande" to mapOf(ConfigKey.HUD_PCT to 112),
            "pequeno" to mapOf(ConfigKey.HUD_PCT to 63),
            "sem-imagem" to mapOf(ConfigKey.STREET_IMG to 0),
        ).forEach { (name, changes) ->
            val out = File("build/screens/preview-$name.png").apply { parentFile?.mkdirs() }
            out.outputStream().use { frame(changes).bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
    }
}
