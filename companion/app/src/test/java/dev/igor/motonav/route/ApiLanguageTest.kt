package dev.igor.motonav.route

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

class ApiLanguageTest {

    // prevents: the route and the search always being requested in Portuguese (`language=pt-BR` fixed until 1.3.3, C16.8 item 2).
    @Test
    fun `the device language goes to Mapbox`() {
        assertEquals("pt-BR", ApiLanguage.route(Locale.forLanguageTag("pt-BR")))
        assertEquals("pt-BR", ApiLanguage.route(Locale.forLanguageTag("pt-PT")))
        assertEquals("pt", ApiLanguage.geocode(Locale.forLanguageTag("pt-BR")))
        assertEquals("en", ApiLanguage.route(Locale.US))
        assertEquals("en", ApiLanguage.geocode(Locale.forLanguageTag("es-AR")))
    }
}
