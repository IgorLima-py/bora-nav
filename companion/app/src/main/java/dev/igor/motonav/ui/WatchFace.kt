package dev.igor.motonav.ui

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.DeviceFontFamilyName
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import dev.igor.motonav.proto.ConfigKey
import dev.igor.motonav.settings.WatchSettings
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.hypot
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * Draws the watch's navigation screen on the phone, for the settings preview (C16.6: Igor wants the
 * preview "100% igual" to the Venu 4's). It is a **mirror** of what the watch draws, in the same category as
 * `tools/preview_map.py`: every number came from a `.mc`, with the symbol name from there, and
 * `WatchFaceTest` reads the `.mc` files and fails if one side changes without the other ([MIRROR]).
 *
 *  - `render/MapRenderer.mc` and `StreetCache.mc` → [drawMap]: the streets, the route, the destination, the camera on the
 *    map and the rider, with the zoom, brightness, tilted map and image streets from the settings;
 *  - `render/Hud.mc` → [Hud]: the time, the street sign and the arrival, with the same integer math, the
 *    per-group sizes (`Config.groupPx`), the sign's breathing room and the orbit margin;
 *  - `render/SpeedHud.mc` → [drawRadar]: the red ring on the edge, the camera sign and the distance;
 *  - `render/TurnGlyphs.mc` → [TURN_RIGHT_GLYPH], Google's arrow on the sign.
 *
 * Everything is drawn in px of the [GLASS] px glass; the caller sets the scale.
 *
 * What is **not** the same, and why:
 *  - **the font.** The watch uses its own RobotoCondensed; here it is Android's `sans-serif-condensed`,
 *    the same Roboto Condensed on most devices. The measured width may change by a few px, and the sign
 *    and the cutouts follow, because the math uses the measured width, as on the watch.
 *  - **the map is a scene**, not the day's route: an avenue, the right turn at [Scene.TURN_M], the
 *    camera and the street mesh around the route ([CORRIDOR_M], like the phone's corridor). The stroke, the
 *    colors, the widths, the scale and the flattening are the watch's.
 *  - **the anti burn-in orbit.** On the wrist the HUD moves up to `orbit_px` to one side every minute; here
 *    it stays in the middle of the orbit, with the margin the watch reserves for it.
 *
 * Records in [boxes] the box of each [Part], so the preview lights up the part a control moves.
 */
internal fun DrawScope.drawWatchFace(measurer: TextMeasurer, values: Map<ConfigKey, Int>, boxes: MutableMap<Part, Rect>) {
    val face = Face(measurer, this)
    val glass = Path().apply { addOval(Rect(0f, 0f, GLASS, GLASS)) }
    clipPath(glass) {
        drawRect(Color.Black, size = Size(GLASS, GLASS))
        drawMap(values, face)
        // NavView.onUpdate: the map, the HUD and the camera sign on top.
        Hud(values, face, boxes).draw(this)
        drawRadar(face, boxes)
    }
}

/** The side of the Venu 4's glass, in px. */
internal const val GLASS = 454f

/** The parts a control changes, for the preview to light up ([WatchPreview]). */
internal enum class Part { CLOCK, PLATE, ARROW, DIST, STREET, TIME, REST, RADAR }

// ─── The scene ───────────────────────────────────────────────────────────────

/**
 * What the preview shows: running at [SPEED_KMH] along an avenue, 200 m from turning right onto
 * Paulista, with a camera at 50 to 120 m. Above the limit, so the red ring lights up (it is the case in
 * which it appears on the wrist).
 */
internal object Scene {
    const val CLOCK = "14:32"
    /**
     * `Hud.weatherSuffix`: on the wrist, the weather comes from Garmin Connect and is almost always there. Only the
     * temperature, without the weather word: the preview does not speak the watch's language (C16.8b).
     */
    const val WEATHER = " · 24°"
    const val TURN_M = 200
    /** `Fmt.plate("Avenida Paulista")`. */
    const val STREET = "Av. Paulista"
    /** `Hud.arrivalClock`: the time without a leading zero. */
    const val ETA = "14:51"
    /** `NavEngine.formatDuration` · `Hud.remaining`. */
    const val REST = "19 min · 12,4 km"
    const val RADAR_LIMIT = 50
    const val RADAR_M = 120
    const val SPEED_KMH = 58
}

/** The route, in meters, with the rider at (0, 0) heading north: the stretch behind is not drawn. */
private val ROUTE = listOf(Offset(0f, -1500f), Offset(0f, Scene.TURN_M.toFloat()), Offset(500f, Scene.TURN_M.toFloat()))

/** Up to how many meters of the route the streets reach the watch: the phone's corridor, in round numbers. */
internal const val CORRIDOR_M = 170f

private class Road(val lod: Int, val a: Offset, val b: Offset)

/**
 * The mesh around the route: 110 m blocks, the route's avenue and Paulista as arterials,
 * two collectors and an expressway on the diagonal, cut at [CORRIDOR_M] from the route like the corridor.
 */
private val ROADS: List<Road> by lazy {
    val block = 110f
    val roads = mutableListOf<Road>()
    fun add(lod: Int, a: Offset, b: Offset) {
        if (distanceToRoute((a + b) / 2f) <= CORRIDOR_M) roads += Road(lod, a, b)
    }
    for (i in -14..14) {
        val x = i * block
        val lod = when {
            i == 0 -> 1
            abs(i) == 3 -> 2
            else -> 3
        }
        for (j in -14 until 14) add(lod, Offset(x, 200f + j * block), Offset(x, 200f + (j + 1) * block))
    }
    for (j in -14..14) {
        val y = 200f + j * block
        val lod = when (j) {
            0 -> 1
            -5 -> 2
            else -> 3
        }
        for (i in -14 until 14) add(lod, Offset(i * block, y), Offset((i + 1) * block, y))
    }
    var x = -1500f
    while (x < 1500f) {
        add(0, Offset(x, 90f - x / 2), Offset(x + 60f, 90f - (x + 60f) / 2))
        x += 60f
    }
    roads
}

private fun distanceToRoute(p: Offset): Float = ROUTE.zipWithNext().minOf { (a, b) ->
    val ab = b - a
    val t = (((p - a).x * ab.x + (p - a).y * ab.y) / (ab.x * ab.x + ab.y * ab.y)).coerceIn(0f, 1f)
    (p - (a + ab * t)).getDistance()
}

// ─── The watch's numbers ─────────────────────────────────────────────────────

// DesignTokens.mc
private const val BACKGROUND = 0x000000
private const val PRIMARY = 0xFFFFFF
private const val SECONDARY = 0xB0BAC2
private const val ROUTE_AHEAD = 0x2FD3FF
private const val HALO = 0x12303B
private const val PUCK = 0xFFFFFF
private const val ARROW_REST = 0x6A7380
private val ROAD_COLORS = listOf(0x8C7A58, 0x6A7584, 0x58626F, 0x4A535E)
private val ROAD_WIDTHS = listOf(16, 12, 9, 7)
private const val ROUTE_PX = 12
private const val ROUTE_CASING_PX = 3
private const val HALO_RADIUS = 24
private const val PUCK_Y = 330
private const val ROUTE_LINE = 0x4C8DF6
private const val ROUTE_EDGE = 0x0E2550
private const val ROAD_EDGE = 0x000000
private const val PLATE = 0x0B5A73
private const val ROAD_EDGE_PX = 2
private const val TILT_K = 0.72f
private const val ARROW_HALF = 34
private const val DIST_PX = 60
private const val UNIT_PX = 40
private const val STREET_PX = 28
private const val CLOCK_PX = 20
private const val TIME_PX = 34
private const val REST_PX = 20
private const val EDGE_MARGIN = 6
private const val GAP_ARROW = 14
private const val GAP_UNIT = 8
private const val STREET_MIN_PX = 22
private const val STREET_TWO_PX = 20
private const val TAB_TOP = 12
private const val TAB_PAD = 14
private const val TAB_EXTRA = 12
private const val TAB_GAP = 10
private const val PLATE_TOP = 54
private const val PLATE_INSET = 5
private const val PLATE_LINE = 2
private const val PLATE_SIDE = 20
private const val PLATE_ROW_MIN = 74
private const val PLATE_ROW_PAD = 2
private const val PLATE_NAME_EXTRA = 14
private const val PLATE_NAME_STEP = 2
private const val ARRIVAL_END_Y = 436
private const val ARRIVAL_EXTRA = 16

// MapRenderer.mc
private const val ANCHOR_X = 227
private const val WIDTH_REF_MPP = 1.2f
private const val WIDTH_EXPONENT = 0.5f
private const val WIDTH_MIN_SCALE = 0.35f
private const val ROUTE_WIDTH_EXPONENT = 0.35f
private const val ROUTE_MIN_SCALE = 0.6f
private const val CAP_MAX_LOD = 1
private const val PUCK_RING_R = 22
private const val PUCK_RING_W = 4
private const val PUCK_ARROW_HALF = 15.0f
private const val PUCK_ARROW_BELOW = 8.6f
private const val PUCK_ARROW_ABOVE = 10.5f
private const val DEST_DOT_R = 10
private const val DEST_EDGE_R = 13.5f
private const val DEST_MAX_PX = 240.0f
private const val DIAG_LABEL_X = 60
private const val DIAG_LABEL_Y = 227

// StreetCache.mc: `EDGE_FROM_LOD = Protocol.CORRIDOR_LOD_COUNT - 2`.
private const val EDGE_FROM_LOD = 2

// NavState.mc: the first 4 are those of the "Zoom when the route opens" control.
private val ZOOM_LEVELS = listOf(0.6f, 1.2f, 2.5f, 5.0f, 10.0f, 20.0f)

// SpeedHud.mc
private const val SIGN_X = 74
private const val SIGN_Y = 238
private const val SIGN_R = 30
private const val SIGN_RING = 7
private const val RED = 0xE53935
private const val RING_R = 226
private const val RING_FADE_PX = 26
private const val RING_ALPHA = 150
/** `_signFont` and `_distFont` of `SpeedHud.initialize`: fixed, the size settings do not touch them. */
private const val SIGN_FONT_PX = 30
private const val RADAR_DIST_FONT_PX = 26

// TurnGlyphs.mc
private const val REF_H = 213

/** The `ic_turn_right` (index 3 of `TurnGlyphs.DATA`): box, polygons, and per polygon color, points and x y. */
internal val TURN_RIGHT_GLYPH = intArrayOf(
    37, 30, 210, 223, 1, 0, 27, 139, 30, 135, 32, 134, 35, 133, 37, 138, 56, 138, 58, 54, 58, 49, 59, 44, 62,
    38, 69, 37, 77, 37, 223, 73, 223, 74, 222, 74, 95, 138, 95, 139, 97, 133, 117, 135, 121, 141, 124, 145,
    123, 149, 120, 207, 80, 210, 77, 206, 73, 147, 33, 142, 30,
)

/** The height, in the frame, of the tallest of the `TurnGlyphs.DATA` icons (the roundabout: 10 to 244). */
internal const val TALLEST_GLYPH = 234

/**
 * The copied numbers, by file and symbol name from there, for `WatchFaceTest` to check against
 * the `.mc` files. If it changed there, the test fails until it changes here.
 */
internal val MIRROR: Map<String, Map<String, Any>> = mapOf(
    "watch/source/render/DesignTokens.mc" to mapOf(
        "BACKGROUND" to BACKGROUND, "PRIMARY" to PRIMARY, "SECONDARY" to SECONDARY, "ROUTE_AHEAD" to ROUTE_AHEAD,
        "HALO" to HALO, "PUCK" to PUCK, "ARROW_REST" to ARROW_REST, "ROAD_COLORS" to ROAD_COLORS,
        "ROAD_WIDTHS" to ROAD_WIDTHS, "ROUTE_PX" to ROUTE_PX, "ROUTE_CASING_PX" to ROUTE_CASING_PX,
        "HALO_RADIUS" to HALO_RADIUS, "PUCK_Y" to PUCK_Y, "ROUTE_LINE" to ROUTE_LINE, "ROUTE_EDGE" to ROUTE_EDGE,
        "ROAD_EDGE" to ROAD_EDGE, "PLATE" to PLATE, "ROAD_EDGE_PX" to ROAD_EDGE_PX, "TILT_K" to TILT_K,
        "ARROW_HALF" to ARROW_HALF, "DIST_PX" to DIST_PX, "UNIT_PX" to UNIT_PX, "STREET_PX" to STREET_PX,
        "CLOCK_PX" to CLOCK_PX, "TIME_PX" to TIME_PX, "REST_PX" to REST_PX, "EDGE_MARGIN" to EDGE_MARGIN,
        "GAP_ARROW" to GAP_ARROW, "GAP_UNIT" to GAP_UNIT, "STREET_MIN_PX" to STREET_MIN_PX,
        "STREET_TWO_PX" to STREET_TWO_PX, "TAB_TOP" to TAB_TOP, "TAB_PAD" to TAB_PAD, "TAB_EXTRA" to TAB_EXTRA,
        "TAB_GAP" to TAB_GAP, "PLATE_TOP" to PLATE_TOP, "PLATE_INSET" to PLATE_INSET, "PLATE_LINE" to PLATE_LINE,
        "PLATE_SIDE" to PLATE_SIDE, "PLATE_ROW_MIN" to PLATE_ROW_MIN, "PLATE_ROW_PAD" to PLATE_ROW_PAD,
        "PLATE_NAME_EXTRA" to PLATE_NAME_EXTRA, "PLATE_NAME_STEP" to PLATE_NAME_STEP,
        "ARRIVAL_END_Y" to ARRIVAL_END_Y, "ARRIVAL_EXTRA" to ARRIVAL_EXTRA,
    ),
    "watch/source/render/MapRenderer.mc" to mapOf(
        "ANCHOR_X" to ANCHOR_X, "WIDTH_REF_MPP" to WIDTH_REF_MPP, "WIDTH_EXPONENT" to WIDTH_EXPONENT,
        "WIDTH_MIN_SCALE" to WIDTH_MIN_SCALE, "ROUTE_WIDTH_EXPONENT" to ROUTE_WIDTH_EXPONENT,
        "ROUTE_MIN_SCALE" to ROUTE_MIN_SCALE, "CAP_MAX_LOD" to CAP_MAX_LOD, "PUCK_RING_R" to PUCK_RING_R,
        "PUCK_RING_W" to PUCK_RING_W, "PUCK_ARROW_HALF" to PUCK_ARROW_HALF, "PUCK_ARROW_BELOW" to PUCK_ARROW_BELOW,
        "PUCK_ARROW_ABOVE" to PUCK_ARROW_ABOVE, "DEST_DOT_R" to DEST_DOT_R, "DEST_EDGE_R" to DEST_EDGE_R,
        "DEST_MAX_PX" to DEST_MAX_PX, "DIAG_LABEL_X" to DIAG_LABEL_X, "DIAG_LABEL_Y" to DIAG_LABEL_Y,
    ),
    "watch/source/model/NavState.mc" to mapOf("ZOOM_LEVELS" to ZOOM_LEVELS),
    "watch/source/render/SpeedHud.mc" to mapOf(
        "SIGN_X" to SIGN_X, "SIGN_Y" to SIGN_Y, "SIGN_R" to SIGN_R, "SIGN_RING" to SIGN_RING, "RED" to RED,
        "RING_R" to RING_R, "RING_FADE_PX" to RING_FADE_PX, "RING_ALPHA" to RING_ALPHA,
    ),
    "watch/source/render/TurnGlyphs.mc" to mapOf("REF_H" to REF_H),
)

/** What `WatchFaceTest` checks outside [MIRROR]: the literals the `.mc` does not call a `const`. */
internal object MirrorLiterals {
    const val SIGN_FONT = SIGN_FONT_PX
    const val RADAR_DIST_FONT = RADAR_DIST_FONT_PX
    const val EDGE_FROM = EDGE_FROM_LOD
}

private fun rgb(color: Int, alpha: Float = 1f) = Color(0xFF000000.toInt() or color).copy(alpha = alpha)

// ─── The font ────────────────────────────────────────────────────────────────

/** `DesignTokens.FACE_TEXT` (RobotoCondensedRegular) and `FACE_NUMBER` (RobotoCondensedBold). */
private val Condensed = FontFamily(
    Font(DeviceFontFamilyName("sans-serif-condensed"), FontWeight.Normal),
    Font(DeviceFontFamilyName("sans-serif-condensed"), FontWeight.Bold),
)

/** The measurements and text drawing in glass px: the watch's vector font requested at `px`. */
private class Face(private val measurer: TextMeasurer, private val scope: DrawScope) {

    fun layout(text: String, px: Int, bold: Boolean): TextLayoutResult = measurer.measure(
        text,
        TextStyle(
            fontFamily = Condensed,
            fontWeight = if (bold) FontWeight.Bold else FontWeight.Normal,
            fontSize = with(scope) { px.toFloat().toSp() },
        ),
        softWrap = false,
        maxLines = 1,
    )

    /** `Dc.getTextWidthInPixels`. */
    fun width(text: String, px: Int, bold: Boolean): Int = layout(text, px, bold).size.width

    /** `Hud.put`: the text with the baseline at `baseline`, left of `x` or centered on it. */
    fun put(text: String, px: Int, bold: Boolean, x: Float, baseline: Float, color: Int, centre: Boolean) {
        val layout = layout(text, px, bold)
        val left = if (centre) x - layout.size.width / 2 else x
        scope.drawText(layout, color = rgb(color), topLeft = Offset(left, baseline - layout.firstBaseline))
    }

    /** `TEXT_JUSTIFY_CENTER | TEXT_JUSTIFY_VCENTER`: the font line centered at (`x`, `y`). */
    fun putCentred(text: String, px: Int, bold: Boolean, x: Float, y: Float, color: Int) {
        val layout = layout(text, px, bold)
        scope.drawText(
            layout,
            color = rgb(color),
            topLeft = Offset(x - layout.size.width / 2, y - layout.size.height / 2),
        )
    }
}

// ─── The map (MapRenderer.draw) ──────────────────────────────────────────────

/** `MapRenderer.widthScale`: near does not thicken, far thins. */
private fun widthScale(mpp: Float, exponent: Float, floor: Float): Float =
    if (mpp <= WIDTH_REF_MPP) 1f else (WIDTH_REF_MPP / mpp).pow(exponent).coerceAtLeast(floor)

/** `MapRenderer.scaledWidth`. */
private fun scaledWidth(base: Int, k: Float): Int = (base * k + 0.5f).toInt().coerceAtLeast(2)

/** `Config.corridorColor`: the class's gray times the brightness, channel by channel, capped at 0xFF. */
internal fun roadColor(lod: Int, pct: Int): Int {
    val base = ROAD_COLORS[lod]
    var colour = 0
    for (shift in intArrayOf(16, 8, 0)) {
        val channel = ((base shr shift) and 0xFF) * pct / 100
        colour = (colour shl 8) or channel.coerceAtMost(0xFF)
    }
    return colour
}

/** `NavState.ZOOM_LEVELS[zoom]`: the m/px of the zoom the route opens with. */
internal fun metersPerPx(values: Map<ConfigKey, Int>): Float =
    ZOOM_LEVELS[(values[ConfigKey.ZOOM] ?: WatchSettings.of(ConfigKey.ZOOM).default).coerceIn(0, 3)]

private fun DrawScope.drawMap(values: Map<ConfigKey, Int>, face: Face) {
    fun on(key: ConfigKey) = (values[key] ?: WatchSettings.of(key).default) == 1
    val mpp = metersPerPx(values)
    // `beginAt`: tilted, the world flattens by K around the rider.
    val k = if (on(ConfigKey.MAP_TILT)) TILT_K else 1f
    val anchor = Offset(ANCHOR_X.toFloat(), PUCK_Y.toFloat())
    // Heading north: the world x is the screen's, and the world y goes up.
    fun flat(p: Offset) = Offset(anchor.x + p.x / mpp, anchor.y - p.y / mpp)
    fun screen(p: Offset) = Offset(anchor.x + p.x / mpp, anchor.y - k * p.y / mpp)

    val roadK = widthScale(mpp, WIDTH_EXPONENT, WIDTH_MIN_SCALE)
    val widths = ROAD_WIDTHS.map { scaledWidth(it, roadK) }
    val brightness = values[ConfigKey.CORRIDOR_PCT] ?: WatchSettings.of(ConfigKey.CORRIDOR_PCT).default
    if (on(ConfigKey.STREET_IMG)) {
        // StreetCache: the streets in a north-up image, pasted flattened by K around the rider
        // (the width flattens along). From local to expressway; in each class up to the collector, the
        // black border of all the ways and then the core. Round tip and bend on all.
        withTransform({ scale(1f, k, pivot = anchor) }) {
            for (lod in ROAD_COLORS.indices.reversed()) {
                val ways = ROADS.filter { it.lod == lod }
                if (lod <= EDGE_FROM_LOD) {
                    ways.forEach {
                        drawLine(rgb(ROAD_EDGE), flat(it.a), flat(it.b), (widths[lod] + 2 * ROAD_EDGE_PX).toFloat(), StrokeCap.Round)
                    }
                }
                ways.forEach {
                    drawLine(rgb(roadColor(lod, brightness)), flat(it.a), flat(it.b), widths[lod].toFloat(), StrokeCap.Round)
                }
            }
        }
    } else {
        // `drawCorridor`, street by street: no border, the points flattened and the width not, and a
        // round tip only up to [CAP_MAX_LOD].
        for (lod in ROAD_COLORS.indices.reversed()) {
            val cap = if (lod <= CAP_MAX_LOD) StrokeCap.Round else StrokeCap.Butt
            ROADS.filter { it.lod == lod }.forEach {
                drawLine(rgb(roadColor(lod, brightness)), screen(it.a), screen(it.b), widths[lod].toFloat(), cap)
            }
        }
    }

    val diag = values[ConfigKey.STREET_DIAG] ?: 0
    if (diag != 0) {
        // the system's `FONT_XTINY`; the condensed one at the nearest size.
        face.putCentred("D$diag", 24, false, DIAG_LABEL_X.toFloat(), DIAG_LABEL_Y.toFloat(), PRIMARY)
    }

    // `drawRoute`: from the rider forward, the dark border underneath and the blue line on top.
    val routeK = widthScale(mpp, ROUTE_WIDTH_EXPONENT, ROUTE_MIN_SCALE)
    val routeWidth = scaledWidth(ROUTE_PX, routeK)
    val casingWidth = routeWidth + 2 * scaledWidth(ROUTE_CASING_PX, routeK).coerceAtLeast(2)
    val ahead = Path().apply {
        val start = screen(Offset.Zero)
        moveTo(start.x, start.y)
        ROUTE.drop(1).map(::screen).forEach { lineTo(it.x, it.y) }
    }
    listOf(ROUTE_EDGE to casingWidth, ROUTE_LINE to routeWidth).forEach { (colour, width) ->
        drawPath(ahead, rgb(colour), style = Stroke(width.toFloat(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    }

    // `drawDestination`: only less than DEST_MAX_PX from the glass center.
    val end = screen(ROUTE.last())
    if (hypot(end.x - GLASS / 2, end.y - GLASS / 2) <= DEST_MAX_PX) {
        drawCircle(rgb(BACKGROUND), DEST_EDGE_R, end)
        drawCircle(rgb(ROUTE_LINE), DEST_DOT_R.toFloat(), end)
    }

    // `Radars.drawMarkers`: the camera icon where it is, on top of the route.
    val radar = screen(Offset(0f, Scene.RADAR_M.toFloat()))
    if (radar.x in -20f..474f && radar.y in -20f..474f) drawCamera(radar)

    // `drawRider`, with a good position: the halo, the cyan ring and the white arrow tip.
    drawCircle(rgb(HALO), HALO_RADIUS.toFloat(), anchor)
    drawCircle(rgb(ROUTE_AHEAD), PUCK_RING_R.toFloat(), anchor, style = Stroke(PUCK_RING_W.toFloat()))
    drawPath(
        Path().apply {
            moveTo(anchor.x - PUCK_ARROW_HALF, anchor.y + PUCK_ARROW_BELOW)
            lineTo(anchor.x + PUCK_ARROW_HALF, anchor.y + PUCK_ARROW_BELOW)
            lineTo(anchor.x, anchor.y - PUCK_ARROW_ABOVE)
            close()
        },
        rgb(PUCK),
    )
}

/** `SpeedHud.camera`: a white camera on a red disc with a black border. */
private fun DrawScope.drawCamera(at: Offset) {
    val (x, y) = at
    drawCircle(rgb(BACKGROUND), 15f, at)
    drawCircle(rgb(RED), 13f, at)
    drawRoundRect(rgb(PRIMARY), Offset(x - 8, y - 5), Size(13f, 10f), CornerRadius(2f))
    drawPath(
        Path().apply {
            moveTo(x + 5, y - 2)
            lineTo(x + 9, y - 5)
            lineTo(x + 9, y + 5)
            lineTo(x + 5, y + 2)
            close()
        },
        rgb(PRIMARY),
    )
    drawCircle(rgb(RED), 2f, Offset(x - 2, y))
}

// ─── The radar (SpeedHud.draw) ───────────────────────────────────────────────

private fun DrawScope.drawRadar(face: Face, boxes: MutableMap<Part, Rect>) {
    val centre = Offset(GLASS / 2, GLASS / 2)
    // `drawRing`: above the limit (`Radars.OVER_KMH`), the border stroke and the fading rings.
    drawCircle(rgb(RED), RING_R.toFloat(), centre, style = Stroke(3f))
    for (d in 2 until RING_FADE_PX step 2) {
        val alpha = RING_ALPHA * (RING_FADE_PX - d) / RING_FADE_PX
        drawCircle(rgb(RED, alpha / 255f), (RING_R - 1 - d).toFloat(), centre, style = Stroke(2f))
    }

    // `drawSign`: red rim, white core and the limit in black.
    val sign = Offset(SIGN_X.toFloat(), SIGN_Y.toFloat())
    drawCircle(rgb(BACKGROUND), (SIGN_R + 3).toFloat(), sign)
    drawCircle(rgb(RED), SIGN_R.toFloat(), sign)
    drawCircle(rgb(PRIMARY), (SIGN_R - SIGN_RING).toFloat(), sign)
    face.putCentred(Scene.RADAR_LIMIT.toString(), SIGN_FONT_PX, true, sign.x, sign.y, BACKGROUND)

    // `drawDistance`: in 10 m steps, in a black cutout under the sign.
    val text = "${Scene.RADAR_M / 10 * 10} m"
    val w = face.width(text, RADAR_DIST_FONT_PX, true)
    val y = SIGN_Y + SIGN_R + 20
    val pill = Rect(Offset((SIGN_X - w / 2 - 8).toFloat(), (y - 16).toFloat()), Size((w + 16).toFloat(), 32f))
    drawRoundRect(rgb(BACKGROUND), pill.topLeft, pill.size, CornerRadius(8f))
    face.putCentred(text, RADAR_DIST_FONT_PX, true, SIGN_X.toFloat(), y.toFloat(), PRIMARY)
    val r = (SIGN_R + 3).toFloat()
    boxes[Part.RADAR] = Rect(sign.x - r, sign.y - r, sign.x + r, pill.bottom)
}

// ─── The HUD (Hud.draw) ──────────────────────────────────────────────────────

/**
 * `Hud.mc` in the preview scene: the time with the weather, the sign with the turn-right arrow, the
 * distance and the name, and the stacked arrival. The math is the watch's, whole, line by line; only what
 * the scene does not use (the back arrow, the arrival, the "then" line, the "Where to?" prompt) was left out.
 */
private class Hud(
    private val values: Map<ConfigKey, Int>,
    private val face: Face,
    private val boxes: MutableMap<Part, Rect>,
) {
    private fun value(key: ConfigKey) = values[key] ?: WatchSettings.of(key).default

    /** `Config.groupPx`. */
    private fun px(base: Int, key: ConfigKey) = (base * WatchSettings.effectivePct(values, key) + 50) / 100

    // `setReserve`: the margin the orbit reserves, and the radial one (A·√2 rounded up).
    private val reserve = value(ConfigKey.ORBIT_PX)
    private val radial = (reserve * 1414 + 999) / 1000
    private val margin = EDGE_MARGIN + radial

    // `resolveFonts`.
    private val clockPx = px(CLOCK_PX, ConfigKey.TEXT_PCT)
    private val restPx = px(REST_PX, ConfigKey.TEXT_PCT)
    private val nameStartPx = px(STREET_PX, ConfigKey.TEXT_PCT)
    private val nameMinPx = px(STREET_MIN_PX, ConfigKey.TEXT_PCT)
    private val nameTwoPx = px(STREET_TWO_PX, ConfigKey.TEXT_PCT)
    private val timePx = px(TIME_PX, ConfigKey.ETA_PCT)
    private val unitPx = px(UNIT_PX, ConfigKey.DIST_PCT)
    private val distPx = px(DIST_PX, ConfigKey.DIST_PCT)
    /** `TurnArrow.half` and `TurnArrow.unit`. */
    private val half = px(ARROW_HALF, ConfigKey.ARROW_PCT)
    private val unit = 2.0f * half / REF_H
    /** `tallestGlyph`. */
    private val glyphH = ceil(TALLEST_GLYPH * unit).toInt()
    private val plateSide: Int
    private val plateTall = value(ConfigKey.PLATE_H_PCT)

    init {
        val tight = PLATE_INSET + PLATE_LINE + PLATE_ROW_PAD
        plateSide = tight + ((PLATE_SIDE - tight) * value(ConfigKey.PLATE_W_PCT) + 50) / 100
    }

    fun draw(scope: DrawScope) {
        val tabBottom = scope.drawClockTab()
        scope.drawPlate(tabBottom)
        scope.drawArrivalTab()
    }

    private fun halfAtTop(y: Int): Int {
        val limit = 227 - margin
        val dy = 227 - y
        val squared = limit * limit - dy * dy
        return if (squared <= 0) 0 else sqrt(squared.toFloat()).toInt()
    }

    private fun topFit(halfW: Int): Int {
        val limit = 227 - margin
        val squared = limit * limit - halfW * halfW
        return if (squared <= 0) 227 else 227 - sqrt(squared.toFloat()).toInt()
    }

    private fun bottomFit(halfW: Int): Int {
        val limit = 227 - margin
        val squared = limit * limit - halfW * halfW
        return if (squared <= 0) 227 else 227 + sqrt(squared.toFloat()).toInt()
    }

    private fun descend(from: Int, fit: Int) = if (fit <= from) from else fit + (fit - from) % 2

    private fun rise(from: Int, fit: Int) = if (fit >= from) from else fit - (from - fit) % 2

    /** `tab`: a sharp-cornered black cutout. */
    private fun DrawScope.tab(left: Int, top: Int, right: Int, bottom: Int) {
        drawRect(rgb(BACKGROUND), Offset(left.toFloat(), top.toFloat()), Size((right - left).toFloat(), (bottom - top).toFloat()))
    }

    private fun DrawScope.fill(colour: Int, x: Int, y: Int, w: Int, h: Int) {
        drawRect(rgb(colour), Offset(x.toFloat(), y.toFloat()), Size(w.toFloat(), h.toFloat()))
    }

    private fun box(part: Part, left: Number, top: Number, right: Number, bottom: Number) {
        boxes[part] = Rect(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat())
    }

    private fun DrawScope.drawClockTab(): Int {
        val cx = 227
        val text = Scene.CLOCK + Scene.WEATHER
        val w = face.width(text, clockPx, false)
        val pad = TAB_EXTRA / 2
        val top = descend(TAB_TOP + reserve + pad, topFit(w / 2))
        val bottom = top + clockPx + pad
        tab(cx - w / 2 - TAB_PAD, top - pad, cx + w / 2 + TAB_PAD, bottom)
        face.put(text, clockPx, false, cx.toFloat(), (top + clockPx * 8 / 10).toFloat(), SECONDARY, centre = true)
        box(Part.CLOCK, cx - w / 2, top, cx + w / 2, top + clockPx)
        return bottom
    }

    private fun DrawScope.drawPlate(tabBottom: Int) {
        val cx = 227
        val plate = PLATE
        val ink = PRIMARY
        val mainText = "${Scene.TURN_M / 10 * 10}"
        val unitText = "m"
        val mainPx = distPx
        val rowH = if (glyphH > distPx) glyphH else distPx

        // `TurnArrow.bounds`.
        val g = TURN_RIGHT_GLYPH
        val bw = (g[2] - g[0]) * unit / 2.0f
        val bh = (g[3] - g[1]) * unit / 2.0f
        val bounds = floatArrayOf(-bw, -bh, bw, bh)
        val markW = (bounds[2] - bounds[0]).toInt()
        val mainW = face.width(mainText, mainPx, true)
        val unitW = face.width(unitText, unitPx, true)
        val total = mainW + GAP_UNIT + unitW + markW + GAP_ARROW

        var py = PLATE_TOP + reserve
        if (tabBottom + TAB_GAP > py) py = tabBottom + TAB_GAP
        val fit = fitPlateName(Scene.STREET, nameStartPx, 2 * halfAtTop(py) - 2 * plateSide)
        val lines = fit.lines
        val namePx = fit.px
        val nameW = fit.width
        val two = lines.isNotEmpty()

        val line = PLATE_LINE
        val inset = PLATE_INSET
        var h1 = rowH + 2 * PLATE_ROW_PAD + line
        if (h1 < PLATE_ROW_MIN) h1 = PLATE_ROW_MIN
        var h2 = if (two) nameStartPx + PLATE_NAME_EXTRA else 0
        if (plateTall < 100) {
            val pad = 2 * PLATE_ROW_PAD + line
            val textH = mainPx * 72 / 100
            val markH = (bounds[3] - bounds[1] + 0.999f).toInt()
            val row = (if (markH > textH) markH else textH) + pad + (if (two) 0 else line)
            h1 = squeeze(h1, row)
            if (two) h2 = squeeze(h2, (if (lines.size == 1) namePx else 2 * namePx + 4) + pad)
        }
        val height = inset + h1 + (if (two) line + h2 else 0) + inset
        var wide = (if (total > nameW) total else nameW) + 2 * plateSide
        wide += wide % 2
        py = descend(py, topFit(wide / 2))
        val left = cx - wide / 2
        val bottom = py + height
        val divY = py + inset + h1

        fill(plate, left, py, wide, height)
        // The 2 px frame, 5 px inside the border, and the thin line between the lines.
        val fx = left + inset
        val fy = py + inset
        val fw = wide - 2 * inset
        val fh = height - 2 * inset
        fill(ink, fx, fy, fw, line)
        fill(ink, fx, fy + fh - line, fw, line)
        fill(ink, fx, fy, line, fh)
        fill(ink, fx + fw - line, fy, line, fh)
        if (two) fill(ink, fx, divY, fw, line)
        box(Part.PLATE, left, py, left + wide, bottom)

        val cy1 = py + inset + line + (h1 - line) / 2
        val x0 = cx - total / 2
        val arrowCx = (x0 - bounds[0]).toInt()
        val arrowCy = (cy1 - (bounds[1] + bounds[3]) / 2).toInt()
        drawGlyph(arrowCx, arrowCy, ink, plate)
        box(Part.ARROW, arrowCx + bounds[0], arrowCy + bounds[1], arrowCx + bounds[2], arrowCy + bounds[3])
        val textX = x0 + markW + GAP_ARROW
        // The number and the unit share the baseline: 86% of the number's body, centered on the line.
        val baseline = cy1 + mainPx * 36 / 100
        face.put(mainText, mainPx, true, textX.toFloat(), baseline.toFloat(), ink, centre = false)
        face.put(unitText, unitPx, true, (textX + mainW + GAP_UNIT).toFloat(), baseline.toFloat(), ink, centre = false)
        box(Part.DIST, textX, baseline - mainPx * 72 / 100, textX + mainW + GAP_UNIT + unitW, baseline)
        if (two) {
            val cy2 = divY + line + h2 / 2
            if (lines.size == 1) {
                face.put(lines[0], namePx, true, cx.toFloat(), (cy2 - namePx / 2 + namePx * 82 / 100).toFloat(), ink, centre = true)
            } else {
                face.put(lines[0], namePx, true, cx.toFloat(), (cy2 - namePx - 2 + namePx * 82 / 100).toFloat(), ink, centre = true)
                face.put(lines[1], namePx, true, cx.toFloat(), (cy2 + 2 + namePx * 82 / 100).toFloat(), ink, centre = true)
            }
            val nameH = if (lines.size == 1) namePx else 2 * namePx + 4
            box(Part.STREET, cx - nameW / 2, cy2 - nameH / 2, cx + nameW / 2, cy2 + nameH / 2)
        }
    }

    private fun squeeze(full: Int, tight: Int): Int =
        if (full <= tight) full else tight + ((full - tight) * plateTall + 50) / 100

    /** `TurnArrow.paint` of the "turn right", no rotation: the path in `fg`, the rest and the holes. */
    private fun DrawScope.drawGlyph(cx: Int, cy: Int, fg: Int, bg: Int) {
        val g = TURN_RIGHT_GLYPH
        val ox = (g[0] + g[2]) / 2.0f
        val oy = (g[1] + g[3]) / 2.0f
        var at = 5
        repeat(g[4]) {
            val colour = g[at]
            val count = g[at + 1]
            at += 2
            val path = Path()
            repeat(count) { i ->
                val x = cx + round((g[at] - ox) * unit)
                val y = cy + round((g[at + 1] - oy) * unit)
                at += 2
                if (i == 0) path.moveTo(x.toFloat(), y.toFloat()) else path.lineTo(x.toFloat(), y.toFloat())
            }
            path.close()
            drawPath(path, rgb(if (colour == 0) fg else if (colour == 1) ARROW_REST else bg))
        }
    }

    /** `TurnArrow.round`: half away from zero. */
    private fun round(value: Float): Int = (if (value >= 0f) value + 0.5f else value - 0.5f).toInt()

    private class Fit(val px: Int, val width: Int, val lines: List<String>)

    /** `fitPlateName`: the size ladder on one line, and two lines cut if it does not fit. */
    private fun fitPlateName(name: String, start: Int, limit: Int): Fit {
        var px = start
        while (px >= nameMinPx) {
            val w = face.width(name, px, true)
            if (w <= limit) return Fit(px, w, listOf(name))
            px -= PLATE_NAME_STEP
        }
        val lines = twoLines(name).map { cut(it, nameTwoPx, limit) }
        return Fit(nameTwoPx, lines.maxOf { face.width(it, nameTwoPx, true) }, lines)
    }

    /** `twoLines`: breaks at the space nearest the middle. */
    private fun twoLines(name: String): List<String> {
        val n = name.length
        var best = -1
        name.forEachIndexed { i, c ->
            if (c == ' ' && (best < 0 || abs(2 * i - n) < abs(2 * best - n))) best = i
        }
        return if (best < 0) listOf(name) else listOf(name.substring(0, best), name.substring(best + 1))
    }

    /** `cut`: the text with "…" until it fits in `limit`. */
    private fun cut(text: String, px: Int, limit: Int): String {
        val width = face.width(text, px, true)
        if (width <= limit) return text
        var kept = text.substring(0, (text.length * limit / width).coerceAtLeast(1))
        while (kept.length > 1 && face.width("$kept…", px, true) > limit) kept = kept.dropLast(1)
        return "$kept…"
    }

    /** `drawArrivalTab`, stacked: the arrival time, large, and below "time · distance". */
    private fun DrawScope.drawArrivalTab() {
        val cx = 227
        val end = ARRIVAL_END_Y - reserve
        val pad = ARRIVAL_EXTRA / 2
        val mainW = face.width(Scene.ETA, timePx, true)
        val restW = face.width(Scene.REST, clockPx, false)
        val w = if (mainW > restW) mainW else restW
        val bottom = rise(end - pad, bottomFit(w / 2))
        val top = bottom - timePx - restPx
        tab(cx - w / 2 - TAB_PAD, top - pad, cx + w / 2 + TAB_PAD, bottom + pad)

        val base = top + timePx * 84 / 100
        val left = cx - mainW / 2
        face.put(Scene.ETA, timePx, true, left.toFloat(), base.toFloat(), PRIMARY, centre = false)
        face.put(Scene.REST, clockPx, false, cx.toFloat(), (bottom - restPx * 16 / 100).toFloat(), SECONDARY, centre = true)
        box(Part.TIME, left, top, left + mainW, top + timePx)
        box(Part.REST, cx - restW / 2, bottom - restPx, cx + restW / 2, bottom)
    }
}
