package dev.igor.motonav.settings

import android.content.Context
import android.content.res.Resources
import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import dev.igor.motonav.R
import dev.igor.motonav.proto.ConfigKey

/**
 * The twenty-one watch settings of `CONFIG` (C8; the four sizes per group came in C16.5, the sign's
 * breathing room in v1.1.5, the map switches in C16, the street diagnostic lever in 1.2.4 and
 * vibration in 1.2.6). The "Watch settings" screen shows all but the [WatchSettings.bench] ones.
 *
 * **The watch is the authority on the ranges** (`Config.mc`, `05 §CONFIG`): these
 * minimums, maximums and defaults exist only so the screen does not offer what the
 * watch will refuse. `WatchSettingsTest` reads `Config.mc` and fails if the
 * two sides drift apart — duplicating the rule without that test would mean having two
 * to keep equal.
 */
data class WatchSetting(
    val key: ConfigKey,
    /** The name and explanation on screen, in the device's language (C16.8b). */
    @StringRes val label: Int,
    @StringRes val hint: Int,
    val unit: String,
    val min: Int,
    val max: Int,
    val default: Int,
    /** Control step; 1 when there is no reason to skip. */
    val step: Int = 1,
    /** Name per value, for what is not a number (the zoom). Empty = the number itself. */
    val names: List<Int> = emptyList(),
    /** On/off (0 or 1) instead of a slider: the map switches (C16). */
    val switch: Boolean = false,
) {
    fun format(res: Resources, value: Int): String =
        if (names.isNotEmpty()) res.getString(names[(value - min).coerceIn(0, names.lastIndex)]) else "$value $unit".trim()
}

object WatchSettings {

    /** In the order of `ConfigKey` (and of the screen). */
    val all: List<WatchSetting> = listOf(
        WatchSetting(
            key = ConfigKey.LEAD_S,
            label = R.string.set_lead_s,
            hint = R.string.set_lead_s_hint,
            unit = "s", min = 4, max = 15, default = 8,
        ),
        WatchSetting(
            key = ConfigKey.LEAD_MIN_M,
            label = R.string.set_lead_min_m,
            hint = R.string.set_lead_min_m_hint,
            unit = "m", min = 30, max = 200, default = 80, step = 10,
        ),
        WatchSetting(
            key = ConfigKey.NEAR_M,
            label = R.string.set_near_m,
            hint = R.string.set_near_m_hint,
            unit = "m", min = 10, max = 60, default = 25, step = 5,
        ),
        WatchSetting(
            key = ConfigKey.PULSE_MS,
            label = R.string.set_pulse_ms,
            hint = R.string.set_pulse_ms_hint,
            unit = "ms", min = 100, max = 500, default = 200, step = 50,
        ),
        WatchSetting(
            key = ConfigKey.ZOOM,
            label = R.string.set_zoom,
            hint = R.string.set_zoom_hint,
            unit = "", min = 0, max = 3, default = 1,
            names = listOf(R.string.zoom_0, R.string.zoom_1, R.string.zoom_2, R.string.zoom_3),
        ),
        WatchSetting(
            key = ConfigKey.CORRIDOR_PCT,
            label = R.string.set_corridor_pct,
            hint = R.string.set_corridor_pct_hint,
            unit = "%", min = 50, max = 160, default = 100, step = 10,
        ),
        WatchSetting(
            key = ConfigKey.HUD_PCT,
            label = R.string.set_hud_pct,
            hint = R.string.set_hud_pct_hint,
            unit = "%", min = 63, max = 112, default = 100,
        ),
        WatchSetting(
            key = ConfigKey.ORBIT_PX,
            label = R.string.set_orbit_px,
            hint = R.string.set_orbit_px_hint,
            unit = "px", min = 0, max = 6, default = 6,
        ),
        WatchSetting(
            key = ConfigKey.ORBIT_S,
            label = R.string.set_orbit_s,
            hint = R.string.set_orbit_s_hint,
            unit = "s", min = 10, max = 60, default = 60, step = 10,
        ),
        // C16.5: the floor (63%) is that of no text below 13 px, and the ceiling that of everything fitting in the
        // glass with the 6 px orbit; both come from tools/design_tokens.py. The ceiling went from 102
        // to 112% in watch v1.1.5, when the warning sign took the place of the cards.
        WatchSetting(
            key = ConfigKey.DIST_PCT,
            label = R.string.set_dist_pct,
            hint = R.string.set_dist_pct_hint,
            unit = "%", min = 63, max = 112, default = 100,
        ),
        WatchSetting(
            key = ConfigKey.ETA_PCT,
            label = R.string.set_eta_pct,
            hint = R.string.set_eta_pct_hint,
            unit = "%", min = 63, max = 112, default = 100,
        ),
        WatchSetting(
            key = ConfigKey.TEXT_PCT,
            label = R.string.set_text_pct,
            hint = R.string.set_text_pct_hint,
            unit = "%", min = 63, max = 112, default = 100,
        ),
        WatchSetting(
            key = ConfigKey.ARROW_PCT,
            label = R.string.set_arrow_pct,
            hint = R.string.set_arrow_pct_hint,
            unit = "%", min = 63, max = 112, default = 100,
        ),
        // v1.1.5: the sign's breathing room, at the sides and top and bottom, each its own (Igor,
        // 2026-10-18). 100% is the sign that design_tokens.py proves on the glass at the scale ceiling, and
        // 0% pushes the arrow, the number and the name against the frame. The height comes out at 0% (Igor's choice
        // looking at the 100, 50 and 0% photos), the width at 100%.
        WatchSetting(
            key = ConfigKey.PLATE_W_PCT,
            label = R.string.set_plate_w_pct,
            hint = R.string.set_plate_w_pct_hint,
            unit = "%", min = 0, max = 100, default = 100, step = 10,
        ),
        WatchSetting(
            key = ConfigKey.PLATE_H_PCT,
            label = R.string.set_plate_h_pct,
            hint = R.string.set_plate_h_pct_hint,
            unit = "%", min = 0, max = 100, default = 0, step = 10,
        ),
        // C16: a bench tool for the laps of 2026-10-19 and 20, not a riding setting.
        WatchSetting(
            key = ConfigKey.GPS_DRILL_MIN,
            label = R.string.set_gps_drill_min,
            hint = R.string.set_gps_drill_min_hint,
            unit = "min", min = 0, max = 30, default = 0,
        ),
        // C16: the map test switches, the same as the watch menu, here for Igor
        // to compare on the wrist without ending the route (2026-10-19: the streets did not show on the first
        // lap with the image). The watch applies it right away.
        WatchSetting(
            key = ConfigKey.STREET_IMG,
            label = R.string.set_street_img,
            hint = R.string.set_street_img_hint,
            unit = "", min = 0, max = 1, default = 1, switch = true,
        ),
        WatchSetting(
            key = ConfigKey.MAP_TILT,
            label = R.string.set_map_tilt,
            hint = R.string.set_map_tilt_hint,
            unit = "", min = 0, max = 1, default = 1, switch = true,
        ),
        WatchSetting(
            key = ConfigKey.STREET_16BIT,
            label = R.string.set_street_16bit,
            hint = R.string.set_street_16bit_hint,
            unit = "", min = 0, max = 1, default = 1, switch = true,
        ),
        // C16 (watch v1.2.5; probes and grids in v1.2.9): on the wrist the 454 and 480 px images show up and the
        // 512 and up do not. The probes (4 to 7) hold several 480 images at once to tell whether the
        // cap is per image or per pool; the grids (8 to 10) are the streets in tiles. The watch writes "D" and the
        // number on the map. The names must match the watch's `StreetCache.DIAG_NAMES`.
        WatchSetting(
            key = ConfigKey.STREET_DIAG,
            label = R.string.set_street_diag,
            hint = R.string.set_street_diag_hint,
            unit = "", min = 0, max = 10, default = 0,
            names = listOf(
                R.string.diag_0, R.string.diag_1, R.string.diag_2, R.string.diag_3, R.string.diag_4, R.string.diag_5,
                R.string.diag_6, R.string.diag_7, R.string.diag_8, R.string.diag_9, R.string.diag_10,
            ),
        ),
        // C16 (watch v1.2.7, phone 1.2.6): vibration had been off in the code since the bench of
        // 2026-10-02; it became an option for Igor to turn on and decide on the street whether he likes it. Ships off, as it was.
        WatchSetting(
            key = ConfigKey.VIBE_ON,
            label = R.string.set_vibe_on,
            hint = R.string.set_vibe_on_hint,
            unit = "", min = 0, max = 1, default = 0, switch = true,
        ),
        // C16.6 (watch v1.2.9, phone 1.2.8): the camera warning has its own vibration (Igor chose a key
        // separate from 21). Ships on: a camera is the warning that costs the most to miss.
        WatchSetting(
            key = ConfigKey.RADAR_VIBE,
            label = R.string.set_radar_vibe,
            hint = R.string.set_radar_vibe_hint,
            unit = "", min = 0, max = 1, default = 1, switch = true,
        ),
    )

    /**
     * A screen group: title, icon and the keys, in the order they appear. The icon lives here since C16.8b:
     * before, it came through the Portuguese title.
     */
    data class Section(
        @StringRes val title: Int,
        @DrawableRes val icon: Int,
        val keys: List<ConfigKey>,
    )

    /**
     * The screen groups (Igor's request, 2026-10-22: "muitas opções e não fica claro o que faz o quê").
     * Riding comes first. [all] stays in the order of `ConfigKey`, which is the wire's and `Config.mc`'s.
     */
    val sections: List<Section> = listOf(
        Section(R.string.section_turns, R.drawable.ic_turn, listOf(
            ConfigKey.VIBE_ON, ConfigKey.LEAD_S, ConfigKey.LEAD_MIN_M, ConfigKey.NEAR_M, ConfigKey.PULSE_MS,
        )),
        Section(R.string.section_radars, R.drawable.ic_radar, listOf(ConfigKey.RADAR_VIBE)),
        Section(R.string.section_map, R.drawable.ic_map, listOf(ConfigKey.ZOOM, ConfigKey.CORRIDOR_PCT)),
        Section(R.string.section_size, R.drawable.ic_watch, listOf(
            ConfigKey.HUD_PCT, ConfigKey.DIST_PCT, ConfigKey.ETA_PCT, ConfigKey.TEXT_PCT, ConfigKey.ARROW_PCT,
            ConfigKey.PLATE_W_PCT, ConfigKey.PLATE_H_PCT,
        )),
        Section(R.string.section_burn_in, R.drawable.ic_shield, listOf(ConfigKey.ORBIT_PX, ConfigKey.ORBIT_S)),
    )

    /**
     * The C16 bench levers (GPS gap, the map switches and the street lever), off the screen since 1.4.3 at
     * Igor's request (2026-10-29: "deixa o padrão"). They still go in every `CONFIG`, always at the default, and
     * [WatchSettingsStore.load] ignores what was saved: the "D2" an old lever left on the watch goes away
     * with the next send. Watch v1.5.1 ignores them anyway (`Config.mc`).
     */
    val bench: Set<ConfigKey> = setOf(
        ConfigKey.GPS_DRILL_MIN, ConfigKey.STREET_IMG, ConfigKey.MAP_TILT, ConfigKey.STREET_16BIT,
        ConfigKey.STREET_DIAG,
    )

    /** The four sizes per part, which `hud_pct` multiplies (`Config.groupPct`). */
    val groupKeys = setOf(ConfigKey.DIST_PCT, ConfigKey.ETA_PCT, ConfigKey.TEXT_PCT, ConfigKey.ARROW_PCT)

    /**
     * The size the part actually has on the watch, in %: `Config.groupPct`, `hud_pct` times the
     * part's, clamped to the HUD range. Showing this is what explains a control that "does nothing": with the
     * overall size at the ceiling, raising the part does not change the screen.
     */
    fun effectivePct(values: Map<ConfigKey, Int>, key: ConfigKey): Int {
        val hud = of(ConfigKey.HUD_PCT)
        val pct = ((values[ConfigKey.HUD_PCT] ?: hud.default) * (values[key] ?: of(key).default) + 50) / 100
        return pct.coerceIn(hud.min, hud.max)
    }

    fun of(key: ConfigKey): WatchSetting = all.first { it.key == key }

    /** Values in use -> the (id, value) entries of `ProtocolPacker.packConfig`. */
    fun entries(values: Map<ConfigKey, Int>): List<Pair<Int, Int>> =
        all.map { it.key.id to (values[it.key] ?: it.default) }

    /**
     * The rule that crosses two keys (`Config.mc` `merge`, `05 §CONFIG`): the watch
     * refuses the **whole** message if `near_m >= lead_min_m`, and still sends
     * the ACK (it is transport). Without this the screen would say "sent" for a setting the
     * watch did not apply. Returns the two distances, or null if the combination is valid.
     */
    fun conflict(values: Map<ConfigKey, Int>): Conflict? {
        val near = values[ConfigKey.NEAR_M] ?: of(ConfigKey.NEAR_M).default
        val leadMin = values[ConfigKey.LEAD_MIN_M] ?: of(ConfigKey.LEAD_MIN_M).default
        return if (near >= leadMin) Conflict(near, leadMin) else null
    }

    /** The `near_m` that does not fit below `lead_min_m`, in meters. */
    data class Conflict(val nearM: Int, val leadMinM: Int) {
        fun text(res: Resources): String = res.getString(R.string.settings_conflict, nearM, leadMinM)
    }

    /** The defaults, indexed by key. */
    fun defaults(): Map<ConfigKey, Int> = all.associate { it.key to it.default }
}

/**
 * What was last sent to the watch. `CONFIG` only writes (the watch
 * does not answer with its state), so the screen shows the last value sent,
 * and not "the value the watch has now".
 */
class WatchSettingsStore(context: Context) {

    private val prefs = context.getSharedPreferences("motonav_watch_settings", Context.MODE_PRIVATE)

    fun load(): Map<ConfigKey, Int> = WatchSettings.all.associate { setting ->
        val saved = when (setting.key) {
            in WatchSettings.bench -> setting.default
            else -> prefs.getInt(setting.key.wireName, setting.default)
        }
        setting.key to saved.coerceIn(setting.min, setting.max)
    }

    fun save(values: Map<ConfigKey, Int>) {
        prefs.edit().apply {
            WatchSettings.all.forEach { putInt(it.key.wireName, values[it.key] ?: it.default) }
        }.apply()
    }
}
