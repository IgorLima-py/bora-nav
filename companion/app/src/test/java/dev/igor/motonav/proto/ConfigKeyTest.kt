package dev.igor.motonav.proto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/** What the debug receiver does with the extras of `adb shell am broadcast` (C5). */
class ConfigKeyTest {

    @Test
    fun `names become key ids in id order`() {
        assertEquals(listOf(1 to 10, 7 to 110), ConfigKey.parse(mapOf("hud_pct" to 110, "lead_s" to 10)))
    }

    @Test
    fun `the ids mirror packer py`() {
        // tools/packer.py CONFIG_KEYS: changed there, change here (05 §CONFIG).
        val ids = ConfigKey.values().associate { it.wireName to it.id }
        assertEquals(
            mapOf(
                "lead_s" to 1, "lead_min_m" to 2, "near_m" to 3, "pulse_ms" to 4,
                "zoom" to 5, "corridor_pct" to 6, "hud_pct" to 7,
                "orbit_px" to 8, "orbit_s" to 9,
                "dist_pct" to 10, "eta_pct" to 11, "text_pct" to 12, "arrow_pct" to 13,
                "plate_w_pct" to 14, "plate_h_pct" to 15, "gps_drill_min" to 16,
                "street_img" to 17, "map_tilt" to 18, "street_16bit" to 19, "street_diag" to 20,
                "vibe_on" to 21, "radar_vibe" to 22,
            ),
            ids,
        )
    }

    @Test
    fun `an unknown name or a value past uint16 is refused on the phone`() {
        assertThrows(IllegalArgumentException::class.java) { ConfigKey.parse(mapOf("lead" to 10)) }
        assertThrows(IllegalArgumentException::class.java) { ConfigKey.parse(mapOf("lead_s" to 70000)) }
    }
}
