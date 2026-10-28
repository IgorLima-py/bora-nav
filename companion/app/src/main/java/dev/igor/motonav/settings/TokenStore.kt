package dev.igor.motonav.settings

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Holds the Mapbox access token (docs/04-COMPANION-APP.md §Settings).
 * Encrypted at rest and never logged — it is the one credential this app has.
 */
class TokenStore(context: Context) {

    private val prefs by lazy {
        val key = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            "motonav.secrets",
            key,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    var mapboxToken: String
        get() = prefs.getString(KEY_MAPBOX, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_MAPBOX, value.trim()).apply()

    val hasMapboxToken: Boolean get() = mapboxToken.isNotBlank()

    /** Monthly request counter, so the 100k free tier stays visible (06 §Roteamento). */
    fun countRouteRequest(yearMonth: String): Int {
        val key = "$KEY_QUOTA:$yearMonth"
        val next = prefs.getInt(key, 0) + 1
        prefs.edit().putInt(key, next).apply()
        return next
    }

    fun routeRequests(yearMonth: String): Int = prefs.getInt("$KEY_QUOTA:$yearMonth", 0)

    private companion object {
        const val KEY_MAPBOX = "mapbox_token"
        const val KEY_QUOTA = "route_requests"
    }
}
