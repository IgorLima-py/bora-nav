package dev.igor.motonav.nav

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The dead-app drill (C16): kills once, disarmed before killing, and nothing when
 * not armed.
 */
class KillDrillTest {

    private class Memory(override var armed: Boolean) : KillDrill.Store

    @Test
    fun `armed kills once and is already disarmed when it kills`() {
        val store = Memory(armed = true)
        val drill = KillDrill(store)
        val lines = mutableListOf<String>()
        var kills = 0
        var armedAtKill: Boolean? = null

        val fired = drill.fire(log = { lines += it }, kill = { kills++; armedAtKill = store.armed })

        assertTrue(fired)
        assertEquals(1, kills)
        // The process born after the kill reads this: still armed would be a loop of deaths.
        assertEquals(false, armedAtKill)
        assertEquals(1, lines.size)
        assertTrue(lines[0], lines[0].startsWith("drill: the app kills itself now"))

        assertFalse("only once", drill.fire(log = { lines += it }, kill = { kills++ }))
        assertEquals(1, kills)
    }

    @Test
    fun `disarmed neither kills nor logs`() {
        val drill = KillDrill(Memory(armed = false))
        var kills = 0
        val lines = mutableListOf<String>()

        assertFalse(drill.fire(log = { lines += it }, kill = { kills++ }))
        assertEquals(0, kills)
        assertTrue(lines.isEmpty())
    }
}
