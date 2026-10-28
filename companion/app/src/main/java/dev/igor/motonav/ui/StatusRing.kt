package dev.igor.motonav.ui

import android.provider.Settings
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.igor.motonav.ui.theme.Amber
import dev.igor.motonav.ui.theme.BoraSigns
import dev.igor.motonav.ui.theme.Cyan
import dev.igor.motonav.ui.theme.CyanTrack
import dev.igor.motonav.ui.theme.Fg2
import dev.igor.motonav.ui.theme.Off
import dev.igor.motonav.ui.theme.RingOff

/** The language's curve (rule 7): quick exit, nothing bounces. */
private val BoraEasing = CubicBezierEasing(0.16f, 0.84f, 0.24f, 1f)

/**
 * The ring with the sign (sheet 2, `docs/design/telas.md` §5.5): the ring says the activity, the sign says
 * the health. The measurements come from the side: ring of radius 0.434, stroke 0.092 and sign 0.684 of it.
 *
 * On entering Ready from another state, the ring sweeps the lap in 760 ms. With the system's animation
 * scale at 0 (reduce motion), it shows up whole and the arc stays still.
 */
@Composable
fun StatusRing(ring: HomeStatus.Ring, sign: HomeStatus.Sign, description: String, side: Dp = 76.dp) {
    val context = LocalContext.current
    val still = remember {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    val sweep = remember { Animatable(360f) }
    var last by remember { mutableStateOf<HomeStatus.Ring?>(null) }
    LaunchedEffect(ring) {
        val before = last
        last = ring
        if (ring == HomeStatus.Ring.READY && before != null && before != HomeStatus.Ring.READY && !still) {
            sweep.snapTo(0f)
            sweep.animateTo(360f, tween(760, easing = BoraEasing))
        } else {
            sweep.snapTo(360f)
        }
    }
    val spin = rememberInfiniteTransition(label = "anel")
    val angle by spin.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(1600, easing = LinearEasing), RepeatMode.Restart),
        label = "arco",
    )

    Canvas(modifier = Modifier.size(side).semantics { contentDescription = description }) {
        val w = size.minDimension * 0.092f
        val r = size.minDimension * 0.434f
        val topLeft = Offset(center.x - r, center.y - r)
        val box = Size(r * 2, r * 2)
        when (ring) {
            HomeStatus.Ring.READY -> {
                if (sweep.value < 360f) {
                    drawCircle(CyanTrack, r, style = Stroke(w))
                    drawArc(Cyan, -90f, sweep.value, false, topLeft, box, style = Stroke(w, cap = StrokeCap.Butt))
                } else {
                    drawCircle(Cyan, r, style = Stroke(w))
                }
            }
            HomeStatus.Ring.WORKING -> {
                drawCircle(CyanTrack, r, style = Stroke(w))
                val start = if (still) -90f else angle - 90f
                drawArc(Cyan, start, 90f, false, topLeft, box, style = Stroke(w, cap = StrokeCap.Butt))
            }
            HomeStatus.Ring.NO_WATCH -> drawCircle(
                RingOff,
                r,
                style = Stroke(w, pathEffect = PathEffect.dashPathEffect(floatArrayOf(0.45f * w, 0.9f * w))),
            )
            HomeStatus.Ring.MISSING -> drawCircle(Amber, r, style = Stroke(w))
        }
        val signSide = size.minDimension * 0.684f
        when (sign) {
            HomeStatus.Sign.NONE -> Unit
            HomeStatus.Sign.CHECK -> drawSign(BoraSigns.CHECK, signSide, Color.White, Cyan)
            HomeStatus.Sign.QUESTION -> drawSign(BoraSigns.QUESTION, signSide, Fg2, Off)
            HomeStatus.Sign.BANG -> drawSign(BoraSigns.BANG, signSide, Color.White, Amber)
        }
    }
}

/** A [BoraSigns] sign in the 190 frame, scaled to `side` and centered. */
private fun DrawScope.drawSign(sign: BoraSigns.Sign, side: Float, color: Color, dot: Color) {
    val stroke = PathParser().parsePathString(sign.stroke).toPath()
    val fill = PathParser().parsePathString(sign.fill).toPath()
    val k = side / BoraSigns.FRAME
    withTransform({
        translate(center.x, center.y)
        scale(k, k, pivot = Offset.Zero)
    }) {
        drawPath(stroke, color, style = Stroke(BoraSigns.STROKE, cap = StrokeCap.Butt, join = StrokeJoin.Miter))
        drawPath(fill, color, style = Fill)
        drawCircle(dot, BoraSigns.DOT_R, Offset(sign.dotX, sign.dotY))
    }
}
