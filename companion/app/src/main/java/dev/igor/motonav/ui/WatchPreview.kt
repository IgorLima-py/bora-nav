package dev.igor.motonav.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.text.rememberTextMeasurer
import dev.igor.motonav.R
import dev.igor.motonav.proto.ConfigKey
import dev.igor.motonav.ui.theme.Cyan

/**
 * The watch preview on the settings screen (Igor's request, 2026-10-22: "print do visual do relógio,
 * e quando eu mexo a opção ele mostra qual tá mexendo"). Since C16.6 it is the real watch
 * screen ([drawWatchFace], the mirror of `Hud.mc`, `SpeedHud.mc` and `MapRenderer.mc`), and it reacts to the
 * settings as the watch does: sizes, the sign's breathing room, orbit margin, zoom, street brightness,
 * tilted map and image streets.
 *
 * When a size control moves, its part lights up with a frame and the rest dims; the ones
 * that change the whole screen (overall size, orbit, map) just redraw.
 */
@Composable
fun WatchPreview(values: Map<ConfigKey, Int>, active: ConfigKey?, modifier: Modifier = Modifier) {
    val measurer = rememberTextMeasurer(cacheSize = 32)
    Canvas(modifier.aspectRatio(1f)) {
        val k = size.minDimension / (GLASS + 2 * BEZEL)
        val boxes = mutableMapOf<Part, Rect>()
        withTransform({
            translate(BEZEL * k, BEZEL * k)
            scale(k, k, pivot = Offset.Zero)
        }) {
            drawWatchFace(measurer, values, boxes)
            drawHighlight(active, boxes)
            // The watch case, outside the glass: the screen's black disappears into the app's dark background.
            drawCircle(BEZEL_COLOR, GLASS / 2 + BEZEL / 2, Offset(GLASS / 2, GLASS / 2), style = Stroke(BEZEL / 2))
        }
    }
}

/** What each control changes in the preview, in words, for the line below it. */
@StringRes
fun previewPartName(key: ConfigKey): Int? = when (key) {
    ConfigKey.HUD_PCT -> R.string.part_hud
    ConfigKey.DIST_PCT -> R.string.part_dist
    ConfigKey.ETA_PCT -> R.string.part_eta
    ConfigKey.TEXT_PCT -> R.string.part_text
    ConfigKey.ARROW_PCT -> R.string.part_arrow
    ConfigKey.PLATE_W_PCT -> R.string.part_plate_w
    ConfigKey.PLATE_H_PCT -> R.string.part_plate_h
    ConfigKey.ORBIT_PX -> R.string.part_orbit
    ConfigKey.ZOOM -> R.string.part_zoom
    ConfigKey.CORRIDOR_PCT -> R.string.part_corridor
    ConfigKey.MAP_TILT -> R.string.part_tilt
    ConfigKey.STREET_IMG -> R.string.part_street_img
    ConfigKey.RADAR_VIBE -> R.string.part_radar
    else -> null
}

/** The parts each control changes; the ones that change the whole screen light up nothing. */
internal fun partsOf(key: ConfigKey?): Set<Part> = when (key) {
    ConfigKey.DIST_PCT -> setOf(Part.DIST)
    ConfigKey.ETA_PCT -> setOf(Part.TIME)
    ConfigKey.TEXT_PCT -> setOf(Part.CLOCK, Part.STREET, Part.REST)
    ConfigKey.ARROW_PCT -> setOf(Part.ARROW)
    ConfigKey.PLATE_W_PCT, ConfigKey.PLATE_H_PCT -> setOf(Part.PLATE)
    ConfigKey.RADAR_VIBE -> setOf(Part.RADAR)
    else -> emptySet()
}

/** Dims the glass outside the parts the [active] control changes, and puts the frame on them. */
private fun DrawScope.drawHighlight(active: ConfigKey?, boxes: Map<Part, Rect>) {
    val lit = partsOf(active).mapNotNull { boxes[it]?.inflate(GROW) }
    if (lit.isEmpty()) return
    var veil = Path().apply { addOval(Rect(0f, 0f, GLASS, GLASS)) }
    lit.forEach { box ->
        val hole = Path().apply { addRoundRect(RoundRect(box, CornerRadius(8f))) }
        veil = Path().apply { op(veil, hole, PathOperation.Difference) }
    }
    drawPath(veil, Color.Black.copy(alpha = VEIL))
    val dash = PathEffect.dashPathEffect(floatArrayOf(10f, 6f))
    lit.forEach { box ->
        drawRoundRect(
            color = Cyan,
            topLeft = box.topLeft,
            size = Size(box.width, box.height),
            cornerRadius = CornerRadius(8f),
            style = Stroke(width = 3f, pathEffect = dash),
        )
    }
}

/** The watch case around the glass, in glass px. */
private const val BEZEL = 8f
private val BEZEL_COLOR = Color(0xFF2C353E)
/** How much the highlight frame extends around the part, in glass px. */
private const val GROW = 6f
/** How much what the control does not change is dimmed. */
private const val VEIL = 0.7f
