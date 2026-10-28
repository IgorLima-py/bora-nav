package dev.igor.motonav.ui

import dev.igor.motonav.link.LinkState
import dev.igor.motonav.link.SdkProblem
import dev.igor.motonav.link.WatchDevice
import dev.igor.motonav.nav.NavActivity
import dev.igor.motonav.ui.HomeStatus.Action
import dev.igor.motonav.ui.HomeStatus.Icon
import dev.igor.motonav.ui.HomeStatus.Ring
import dev.igor.motonav.ui.HomeStatus.Sign
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * The Início header (`docs/design/telas.md` §5.4): one line per case of the table, in order, and
 * the combinations in which the list shows more than one pending item. In Portuguese: the English is in
 * `TextsTest` (C16.8b).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "pt")
class HomeStatusTest {

    private val venu = WatchDevice(id = 1, name = "Venu 4", connected = true, appInstalled = true)
    private val ready = LinkState(initializing = false, devices = listOf(venu))

    private fun status(
        link: LinkState = ready,
        battery: Boolean = true,
        token: Boolean = true,
        activity: NavActivity = NavActivity.Idle,
    ) = homeStatus(RuntimeEnvironment.getApplication().resources, link, battery, token, activity, "1.2.0")

    private fun HomeStatus.labels() = pending.map { it.label }

    @Test
    fun `1 searching while the SDK comes up`() {
        val s = status(link = LinkState())
        assertEquals(Ring.WORKING, s.ring)
        assertEquals(Sign.NONE, s.sign)
        assertEquals("Procurando o relógio", s.title)
        assertEquals(emptyList<String>(), s.labels())
    }

    @Test
    fun `2 no Garmin Connect asks to install`() {
        val s = status(link = LinkState(initializing = false, problem = SdkProblem.GCM_NOT_INSTALLED))
        assertEquals(Ring.MISSING, s.ring)
        assertEquals(Sign.BANG, s.sign)
        assertEquals("Falta o Garmin Connect", s.title)
        assertEquals(listOf(HomeStatus.Pending(Icon.APPS, "Garmin Connect", Action.INSTALL_GCM, yours = true)), s.pending)
    }

    @Test
    fun `3 old Garmin Connect asks to update`() {
        val s = status(link = LinkState(initializing = false, problem = SdkProblem.GCM_NEEDS_UPGRADE))
        assertEquals("Falta atualizar o Garmin Connect", s.title)
        assertEquals(Action.UPDATE_GCM, s.pending.single().action)
    }

    @Test
    fun `4 error and SDK shutdown ask to open`() {
        for (problem in listOf(SdkProblem.SERVICE_ERROR, SdkProblem.SDK_SHUT_DOWN)) {
            val s = status(link = LinkState(initializing = false, problem = problem))
            assertEquals("O Garmin Connect não respondeu", s.title)
            assertEquals(Action.OPEN_GCM, s.pending.single().action)
        }
    }

    @Test
    fun `5 no paired watch`() {
        val s = status(link = LinkState(initializing = false))
        assertEquals(Ring.NO_WATCH, s.ring)
        assertEquals(Sign.QUESTION, s.sign)
        assertEquals("Cadê o relógio?", s.title)
        assertEquals("Pareie o relógio no Garmin Connect", s.detail)
        assertEquals(listOf("Relógio pareado"), s.labels())
    }

    @Test
    fun `6 watch paired and turned off`() {
        val s = status(link = ready.copy(devices = listOf(venu.copy(connected = false))))
        assertEquals(Ring.NO_WATCH, s.ring)
        assertEquals("Veja o Bluetooth e o Garmin Connect", s.detail)
        assertEquals(listOf("Venu 4 ligado", "Bora? no relógio"), s.labels())
        assertEquals(Action.OPEN_GCM, s.pending.first().action)
        assertTrue(s.pending.none { it.yours })
    }

    @Test
    fun `7 calculating and sending spin the ring with the check`() {
        val calc = status(activity = NavActivity.Calculating("MASP", fromWatch = true))
        assertEquals(Ring.WORKING, calc.ring)
        assertEquals(Sign.CHECK, calc.sign)
        assertEquals("Calculando a rota", calc.title)
        assertEquals("Para MASP, pedido pelo relógio", calc.detail)

        val send = status(activity = NavActivity.Sending("Copan", fromWatch = false))
        assertEquals("Mandando a rota", send.title)
        assertEquals("Para Copan", send.detail)
    }

    @Test
    fun `8 no Bora on the watch`() {
        val s = status(link = ready.copy(devices = listOf(venu.copy(appInstalled = false))))
        assertEquals(Ring.MISSING, s.ring)
        assertEquals("Falta o Bora? no relógio", s.title)
        assertEquals("Instale o Bora? no Venu 4", s.detail)
        assertEquals(listOf("Bora? no relógio"), s.labels())
    }

    @Test
    fun `9 battery with restriction`() {
        val s = status(battery = false)
        assertEquals(Ring.MISSING, s.ring)
        assertEquals("Falta uma coisa", s.title)
        assertEquals(listOf(HomeStatus.Pending(Icon.BATTERY, "Bateria sem restrição", Action.ALLOW_BATTERY, yours = true)), s.pending)
    }

    @Test
    fun `10 no token the route does not go out`() {
        val s = status(token = false)
        assertEquals("Falta o token do Mapbox", s.title)
        assertEquals("Sem ele o celular não calcula a rota", s.detail)
        assertEquals(Action.SAVE_TOKEN, s.pending.single().action)
    }

    @Test
    fun `11 all ready`() {
        val s = status()
        assertEquals(Ring.READY, s.ring)
        assertEquals(Sign.CHECK, s.sign)
        assertEquals("Tudo pronto", s.title)
        assertEquals("Venu 4 ligado · Bora? 1.2.0", s.detail)
        assertEquals(emptyList<String>(), s.labels())
    }

    @Test
    fun `off with battery shows the Cadê and the three pending items`() {
        val s = status(link = ready.copy(devices = listOf(venu.copy(connected = false))), battery = false)
        assertEquals("Cadê o relógio?", s.title)
        assertEquals(listOf("Venu 4 ligado", "Bora? no relógio", "Bateria sem restrição"), s.labels())
    }

    @Test
    fun `route going out with battery spins the ring with the exclamation and lists the battery`() {
        val s = status(battery = false, activity = NavActivity.Sending("Copan", fromWatch = true))
        assertEquals(Ring.WORKING, s.ring)
        assertEquals(Sign.BANG, s.sign)
        assertEquals(listOf("Bateria sem restrição"), s.labels())
    }

    @Test
    fun `everything missing lists everything and Garmin Connect decides the header`() {
        val s = status(link = LinkState(initializing = false, problem = SdkProblem.GCM_NOT_INSTALLED), battery = false, token = false)
        assertEquals("Falta o Garmin Connect", s.title)
        assertEquals(listOf("Garmin Connect", "Bateria sem restrição", "Token do Mapbox"), s.labels())
    }
}
