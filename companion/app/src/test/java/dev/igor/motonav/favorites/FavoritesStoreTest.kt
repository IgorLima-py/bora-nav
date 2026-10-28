package dev.igor.motonav.favorites

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The favorites storage (C12, `04 §Favorites`). Igor's address is sensitive
 * data: it can only exist in the app's private file, and never in what leaves it.
 * The places here are public (Copan, MASP) — never a real address.
 */
class FavoritesStoreTest {

    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("motonav-favorites").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun store() = FavoritesStore(FavoritesStore.defaultFile(dir))

    // prevents: the watch receiving "Casa" without a coordinate (seed not yet filled in) and trying to
    // navigate to 0,0 — the seed exists in the phone's list, but does not go in FAVORITES.
    @Test
    fun `the first run offers the three seeds, none with a place, none on the wire`() {
        val store = store()

        assertEquals(listOf("Casa", "Academia", "Escritório"), store.list().map { it.name })
        assertTrue(store.list().none { it.hasPlace })
        assertTrue(store.wire().isEmpty())
    }

    // prevents: a favorite that vanishes when the app closes (Igor fills in Casa and the next time it opens
    // it is empty) — the state has to survive a new storage instance.
    @Test
    fun `a saved favorite survives a new instance and reaches the wire`() {
        val saved = store().save(Favorite(id = 0, name = "Copan", lat = -23.54522, lon = -46.64218, icon = 2))

        val reopened = store()

        assertEquals(saved, reopened.find(saved.id))
        val wire = reopened.wire().single { it.favId == saved.id }
        assertEquals(-2354522, wire.latE5)
        assertEquals(-4664218, wire.lonE5)
        assertEquals("Copan", wire.name)
        assertEquals(2, wire.icon)
    }

    // prevents: a favId reused after deleting — the watch keeps the id; a deleted "Casa" whose
    // id passed to the next favorite would send Igor to the wrong place.
    @Test
    fun `an id is not reused after a delete`() {
        val store = store()
        val first = store.save(Favorite(id = 0, name = "Copan", lat = -23.54522, lon = -46.64218))
        store.delete(first.id)

        val second = store.save(Favorite(id = 0, name = "MASP", lat = -23.56135, lon = -46.65589))

        assertTrue("id novo", second.id > first.id)
        assertNull(store.find(first.id))
    }

    // prevents: after 255 creations the favId went past 0xFF and packFavorites threw inside a
    // coroutine with no handler, taking the app down on every watch connection (C12 second opinion).
    @Test
    fun `ids stay inside the one byte the protocol allows`() {
        val store = store()
        repeat(300) {
            val saved = store.save(Favorite(id = 0, name = "F", lat = -23.5, lon = -46.6))
            assertTrue("id ${saved.id} fits in one byte", saved.id in 1..255)
            store.delete(saved.id)
        }
        assertTrue(store.wire().all { it.favId in 0..255 })
    }

    // prevents: the 7th favorite entering the storage and FAVORITES being refused whole by the
    // watch (05 §FAVORITES: at most 6) — its list would be stuck on the old version.
    @Test
    fun `a seventh favorite is refused`() {
        val store = store()
        // the 3 seeds + 3 new = 6
        repeat(3) { store.save(Favorite(id = 0, name = "F$it", lat = -23.5, lon = -46.6)) }

        assertEquals(FavoritesStore.MAX, store.list().size)
        assertThrows(IllegalStateException::class.java) {
            store.save(Favorite(id = 0, name = "Sete", lat = -23.5, lon = -46.6))
        }
        // editing an existing one with the list full still works
        val copy = store.list().first().copy(name = "Casa nova")
        assertEquals("Casa nova", store.save(copy).name)
    }

    // prevents: the app crashing on open with a cut-off file (process killed in the middle of the
    // write): the bad file becomes the seeds, not an exception in MainActivity.
    @Test
    fun `a corrupt file falls back to the seeds instead of crashing`() {
        FavoritesStore.defaultFile(dir).writeText("{ this is not json")

        assertEquals(3, store().list().size)
    }

    // prevents: the favorite ending up outside the private storage (card, public folder, log):
    // RF-02 says "só no armazenamento do app" (only in the app's storage). Writing creates a single file, inside the
    // given directory, and nothing temporary is left behind.
    @Test
    fun `a favorite is written only to the private file and leaves no temp behind`() {
        val store = store()
        store.save(Favorite(id = 0, name = "Copan", lat = -23.54522, lon = -46.64218))

        val files = dir.walkTopDown().filter { it.isFile }.map { it.name }.toList()
        assertEquals(listOf(FavoritesStore.FILE_NAME), files)
        assertEquals(dir.canonicalFile, FavoritesStore.defaultFile(dir).canonicalFile.parentFile)
        assertTrue("Copan" in FavoritesStore.defaultFile(dir).readText())
        assertFalse("no .tmp", dir.walkTopDown().any { it.name.endsWith(".tmp") })
    }
}
