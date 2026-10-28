package dev.igor.motonav.route

import java.util.Locale

/**
 * The language requested from Mapbox (C16.8b): the device's. Up to 1.3.3 it was always Portuguese (`pt-BR` for the
 * route, `pt` for search). Mapbox only uses it for the maneuver text and place names; the route is the
 * same. Portuguese from any country becomes Brazil's, which is the variant Mapbox has.
 */
object ApiLanguage {

    /** The Directions `language`: `pt-BR` or `en`. */
    fun route(locale: Locale = Locale.getDefault()): String = if (isPortuguese(locale)) "pt-BR" else "en"

    /** The geocode `language`: `pt` or `en`. */
    fun geocode(locale: Locale = Locale.getDefault()): String = if (isPortuguese(locale)) "pt" else "en"

    private fun isPortuguese(locale: Locale) = locale.language == "pt"
}
