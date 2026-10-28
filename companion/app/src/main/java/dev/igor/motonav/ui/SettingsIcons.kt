package dev.igor.motonav.ui

import androidx.annotation.DrawableRes
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import dev.igor.motonav.R
import dev.igor.motonav.proto.ConfigKey
import dev.igor.motonav.ui.theme.Fg

/**
 * One icon per setting (Igor's request, 2026-10-22), on the Bora? geometry like those of sheet 2.
 * The `when` covers all of [ConfigKey]: a new key without an icon does not compile.
 */
@DrawableRes
fun settingIcon(key: ConfigKey): Int = when (key) {
    ConfigKey.VIBE_ON -> R.drawable.ic_vibrate
    ConfigKey.LEAD_S -> R.drawable.ic_schedule
    ConfigKey.LEAD_MIN_M -> R.drawable.ic_ruler
    ConfigKey.NEAR_M -> R.drawable.ic_stop_line
    ConfigKey.PULSE_MS -> R.drawable.ic_pulse
    ConfigKey.ZOOM -> R.drawable.ic_zoom_in
    ConfigKey.CORRIDOR_PCT -> R.drawable.ic_sun
    ConfigKey.HUD_PCT -> R.drawable.ic_size
    ConfigKey.DIST_PCT -> R.drawable.ic_hash
    ConfigKey.ETA_PCT -> R.drawable.ic_flag
    ConfigKey.TEXT_PCT -> R.drawable.ic_text
    ConfigKey.ARROW_PCT -> R.drawable.ic_arrow_up
    ConfigKey.PLATE_W_PCT -> R.drawable.ic_width
    ConfigKey.PLATE_H_PCT -> R.drawable.ic_height
    ConfigKey.ORBIT_PX -> R.drawable.ic_move
    ConfigKey.ORBIT_S -> R.drawable.ic_hourglass
    ConfigKey.GPS_DRILL_MIN -> R.drawable.ic_gps_off
    ConfigKey.STREET_IMG -> R.drawable.ic_image
    ConfigKey.MAP_TILT -> R.drawable.ic_tilt
    ConfigKey.STREET_16BIT -> R.drawable.ic_grid
    ConfigKey.STREET_DIAG -> R.drawable.ic_tune
    ConfigKey.RADAR_VIBE -> R.drawable.ic_radar
}

/** Icon and name side by side: a group's title or a setting's name. */
@Composable
fun IconLabel(
    @DrawableRes icon: Int?,
    text: String,
    style: TextStyle,
    tint: Color,
    modifier: Modifier = Modifier,
    iconSize: Int = 20,
) {
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        icon?.let {
            Icon(
                painterResource(it),
                contentDescription = null,
                tint = tint,
                modifier = Modifier.padding(end = 10.dp).size(iconSize.dp),
            )
        }
        Text(text, style = style, color = Fg)
    }
}
