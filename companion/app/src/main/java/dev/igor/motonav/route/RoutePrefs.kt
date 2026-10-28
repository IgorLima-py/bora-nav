package dev.igor.motonav.route

import android.content.Context

/**
 * What the phone asks Mapbox beyond the destination (C16, 2026-10-21). Today only "Evitar vias
 * expressas" (avoid expressways), on by default: Mapbox has no motorcycle profile, and in OSM the express lane of
 * Marginal Pinheiros, forbidden to motorcycles, is `motorway` ([MapboxProvider.directionsUrl]).
 * Turning it off is for the highway, where the `motorway` road is the right way.
 */
object RoutePrefs {

    private const val PREFS = "rota"
    private const val KEY_AVOID_MOTORWAYS = "evitar_vias_expressas"

    fun avoidMotorways(context: Context): Boolean =
        prefs(context).getBoolean(KEY_AVOID_MOTORWAYS, true)

    fun setAvoidMotorways(context: Context, on: Boolean) {
        prefs(context).edit().putBoolean(KEY_AVOID_MOTORWAYS, on).apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
