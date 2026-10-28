package dev.igor.motonav.geo

import dev.igor.motonav.route.LatLng
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * The last known position (C16.5), the favorite's origin when Fused does not
 * answer. The place here is public (Praça da Sé), never an address of Igor's.
 */
class LastPositionStoreTest {

    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("motonav-last-position").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun store() = LastPositionStore(LastPositionStore.defaultFile(dir))

    // prevents: at 15:51 on 2026-10-16 the phone process was born 1 s before the watch's request
    // (`DECISIONS.md` §2026-10-16); an in-memory-only position would have died with the previous process.
    @Test
    fun `the last position survives a new process, and a cut file is no position`() {
        assertNull("first run", store().load())

        store().save(LatLng(-23.5505, -46.6333), atMs = 1_700_000_000_000L)

        assertEquals(KnownPosition(LatLng(-23.5505, -46.6333), 1_700_000_000_000L), store().load())

        LastPositionStore.defaultFile(dir).writeText("{\"lat\": -23.55", Charsets.UTF_8)
        assertNull("file cut in the middle of the write", store().load())
    }
}
