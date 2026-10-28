package dev.igor.motonav.ui

import android.content.res.Resources
import dev.igor.motonav.link.LinkState
import dev.igor.motonav.link.WatchDevice
import dev.igor.motonav.nav.NavActivity
import dev.igor.motonav.proto.ConfigKey
import dev.igor.motonav.settings.WatchSettings
import dev.igor.motonav.trips.Trip
import java.util.Calendar
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * The phone in both languages (C16.8b): the same screen in English (`values/`, the default for whoever is not from
 * Brazil) and in Portuguese (`values-pt/`). The number follows the language of the words: "11.4 km" and "11,4 km".
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class TextsTest {

    private val res: Resources get() = RuntimeEnvironment.getApplication().resources
    private val zone = TimeZone.getTimeZone("America/Sao_Paulo")
    private val venu = WatchDevice(id = 1, name = "Venu 4", connected = true, appInstalled = true)

    private fun at(day: Int, hour: Int): Long = Calendar.getInstance(zone).apply {
        clear()
        set(2026, Calendar.OCTOBER, day, hour, 0)
    }.timeInMillis

    private val trip = Trip(
        startMs = at(17, 9),
        lastMs = at(17, 9) + 23 * 60_000L,
        endMs = at(17, 9) + 23 * 60_000L,
        label = "MASP",
        plannedS = 25 * 60,
        distanceM = 11_000,
        riddenM = 11_400,
        reroutes = 2,
        end = Trip.End.ARRIVED,
        watchBatStart = 80,
        watchBatEnd = 79,
    )

    private fun ready() = homeStatus(res, LinkState(initializing = false, devices = listOf(venu)), true, true, NavActivity.Idle, "1.4.0")

    // prevents: the phone only in Portuguese for whoever installs from GitHub outside Brazil (C16.8, item 2).
    @Test
    @Config(qualifiers = "en")
    fun `in English the Início, the recents, the trips and the settings`() {
        assertEquals("All set", ready().title)
        assertEquals("Venu 4 connected · Bora? 1.4.0", ready().detail)
        assertEquals("yesterday · 23 min · 11.4 km", recentLine(res, trip, at(18, 20), zone))
        assertEquals(
            listOf("23 min (-2:00 vs. plan) · arrived", "11.4 km ridden of 11.0 km planned · avg 30 km/h · 2 reroutes", "watch 80 → 79% (1 point) · 2.6 %/h"),
            TripText.lines(res, trip),
        )
        assertEquals("1.2 m/px", WatchSettings.of(ConfigKey.ZOOM).format(res, 1))
        assertEquals("8 s", WatchSettings.of(ConfigKey.LEAD_S).format(res, 8))
        assertEquals(
            "The second alert (30 m) must come closer to the turn than “never alert closer than” (30 m); the watch would reject it.",
            WatchSettings.conflict(mapOf(ConfigKey.LEAD_MIN_M to 30, ConfigKey.NEAR_M to 30))!!.text(res),
        )
    }

    // prevents: the translation breaking the Portuguese of whoever already uses it (the texts from before C16.8b).
    @Test
    @Config(qualifiers = "pt-rBR")
    fun `in Portuguese it stays as it was`() {
        assertEquals("Tudo pronto", ready().title)
        assertEquals("Venu 4 ligado · Bora? 1.4.0", ready().detail)
        assertEquals("ontem · 23 min · 11,4 km", recentLine(res, trip, at(18, 20), zone))
        assertEquals(
            listOf("23 min (-2:00 do plano) · chegou", "11,4 km rodados de 11,0 km planejados · média 30 km/h · 2 recálculos", "relógio 80 → 79% (1 ponto) · 2,6 %/h"),
            TripText.lines(res, trip),
        )
        assertEquals("1,2 m/px", WatchSettings.of(ConfigKey.ZOOM).format(res, 1))
        assertEquals(
            "O segundo aviso (30 m) tem de vir mais perto da curva que o «nunca avisar a menos de» (30 m); o relógio recusaria o envio.",
            WatchSettings.conflict(mapOf(ConfigKey.LEAD_MIN_M to 30, ConfigKey.NEAR_M to 30))!!.text(res),
        )
    }

    // prevents: Portugal's Portuguese falling into the English of `values/` (the folder is `values-pt`, not `-rBR`).
    @Test
    @Config(qualifiers = "pt-rPT")
    fun `Portugal Portuguese reads Portuguese`() {
        assertEquals("Tudo pronto", ready().title)
    }

    // prevents: a language with no folder (Spanish) having no text at all, instead of the default English.
    @Test
    @Config(qualifiers = "es")
    fun `another language falls back to English`() {
        assertEquals("All set", ready().title)
    }
}
