package dev.igor.motonav.proto

/**
 * The keys of the CONFIG message (05 §CONFIG), with the id that goes on the wire and the name
 * that `sim.py` and `adb shell am broadcast` use. Mirror of `CONFIG_KEYS` in
 * tools/packer.py.
 *
 * The phone only packs: **the ranges live on the watch** (`Config.mc`), which is
 * what refuses and logs. Duplicating the rule here would mean keeping two in sync.
 */
enum class ConfigKey(val id: Int, val wireName: String) {
    LEAD_S(1, "lead_s"),
    LEAD_MIN_M(2, "lead_min_m"),
    NEAR_M(3, "near_m"),
    PULSE_MS(4, "pulse_ms"),
    ZOOM(5, "zoom"),
    CORRIDOR_PCT(6, "corridor_pct"),
    HUD_PCT(7, "hud_pct"),
    ORBIT_PX(8, "orbit_px"),
    ORBIT_S(9, "orbit_s"),
    DIST_PCT(10, "dist_pct"),
    ETA_PCT(11, "eta_pct"),
    TEXT_PCT(12, "text_pct"),
    ARROW_PCT(13, "arrow_pct"),
    PLATE_W_PCT(14, "plate_w_pct"),
    PLATE_H_PCT(15, "plate_h_pct"),
    GPS_DRILL_MIN(16, "gps_drill_min"),
    STREET_IMG(17, "street_img"),
    MAP_TILT(18, "map_tilt"),
    STREET_16BIT(19, "street_16bit"),
    STREET_DIAG(20, "street_diag"),
    VIBE_ON(21, "vibe_on"),
    RADAR_VIBE(22, "radar_vibe"),
    ;

    companion object {
        fun byName(name: String): ConfigKey? = values().firstOrNull { it.wireName == name }

        /**
         * Name -> value (the debug broadcast's extras) as (id, value) entries
         * ready for [ProtocolPacker.packConfig]. Empty map = "back to
         * default". An unknown name or a value outside uint16 is an error here: whoever
         * typed the command is looking at the screen and can fix it.
         */
        fun parse(values: Map<String, Int>): List<Pair<Int, Int>> = values.map { (name, value) ->
            val key = requireNotNull(byName(name)) {
                "unknown key: $name (known: ${values().joinToString { it.wireName }})"
            }
            require(value in 0..0xFFFF) { "$name=$value does not fit in a uint16" }
            key.id to value
        }.sortedBy { it.first }
    }
}
