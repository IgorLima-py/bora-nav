package dev.igor.motonav.ui

import dev.igor.motonav.favorites.Favorite
import dev.igor.motonav.trips.Trip
import java.util.Calendar
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** The "Recentes" row on Início (`docs/design/telas.md` §5.3): "ontem · 23 min · 11,4 km". */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "pt")
class HomeRecentsTest {

    private val res = RuntimeEnvironment.getApplication().resources

    private val zone = TimeZone.getTimeZone("America/Sao_Paulo")

    private fun at(day: Int, hour: Int): Long = Calendar.getInstance(zone).apply {
        clear()
        set(2026, Calendar.OCTOBER, day, hour, 0)
    }.timeInMillis

    private val now = at(18, 20)

    private fun trip(label: String, startMs: Long, realS: Int?, plannedS: Int = 1500, distanceM: Int = 11_000, riddenM: Int = 0) = Trip(
        startMs = startMs,
        lastMs = startMs + (realS ?: 0) * 1000L,
        endMs = realS?.let { startMs + it * 1000L },
        label = label,
        plannedS = plannedS,
        distanceM = distanceM,
        riddenM = riddenM,
    )

    @Test
    fun `yesterday with the time and distance ridden`() {
        val line = recentLine(res, trip("MASP", at(17, 9), realS = 23 * 60, riddenM = 11_400), now, zone)
        assertEquals("ontem · 23 min · 11,4 km", line)
    }

    @Test
    fun `today with no end uses the plan and the Mapbox distance`() {
        val line = recentLine(res, trip("Copan", at(18, 8), realS = null, plannedS = 25 * 60), now, zone)
        assertEquals("hoje · 25 min · 11,0 km", line)
    }

    @Test
    fun `older shows the day and goes past an hour`() {
        val line = recentLine(res, trip("Ibirapuera", at(3, 9), realS = 65 * 60), now, zone)
        assertEquals("03/10 · 1h05 · 11,0 km", line)
    }

    @Test
    fun `each place takes the newest trip with the same name and stops at three`() {
        val places = listOf("MASP", "Copan", "Ibirapuera", "Pinacoteca").mapIndexed { i, name ->
            Favorite(id = i, name = name, lat = -23.56 + i * 0.01, lon = -46.65)
        }
        val trips = listOf(
            trip("MASP", at(18, 9), realS = 10 * 60),
            trip("MASP", at(10, 9), realS = 40 * 60),
            trip("Copan", at(17, 9), realS = 20 * 60),
        )
        val out = homeRecents(res, places, trips, now, zone)
        assertEquals(listOf("MASP", "Copan", "Ibirapuera"), out.map { it.name })
        assertEquals("hoje · 10 min · 11,0 km", out[0].line)
        assertEquals("", out[2].line)
        assertEquals(-23.56, out[0].place.position.lat, 1e-9)
    }
}
