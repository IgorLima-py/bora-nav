package dev.igor.motonav.geo

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.Looper
import androidx.core.content.ContextCompat
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import dev.igor.motonav.route.LatLng
import kotlin.coroutines.resume
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Where the ride starts from. Uses the last known fix when it is recent enough
 * and asks for a fresh one otherwise (docs/04-COMPANION-APP.md §Favoritos).
 *
 * Every position that comes out of here is kept in [LastPositionStore] (C16.5): it is what the
 * favorite uses when Fused does not answer with the app off screen.
 */
class LocationSource(private val context: Context) {

    private val client by lazy { LocationServices.getFusedLocationProviderClient(context) }

    private val remembered by lazy { LastPositionStore.of(context) }

    /** The last position this app saw, from any path, with the time. */
    fun lastKnown(): KnownPosition? = remembered.load()

    fun hasPermission(): Boolean = ContextCompat.checkSelfPermission(
        context,
        Manifest.permission.ACCESS_FINE_LOCATION,
    ) == PackageManager.PERMISSION_GRANTED

    /**
     * The last known position, with no new fix: serves as a bias for the address
     * search, where waiting 8 s for GPS on every keystroke makes no sense.
     */
    @SuppressLint("MissingPermission")
    suspend fun currentOrNull(): LatLng? {
        if (!hasPermission()) {
            return null
        }
        val last = withTimeoutOrNull(LAST_FIX_TIMEOUT_MS) {
            suspendCancellableCoroutine<android.location.Location?> { continuation ->
                client.lastLocation
                    .addOnSuccessListener { continuation.resume(it) }
                    .addOnFailureListener { continuation.resume(null) }
            }
        } ?: return null
        return LatLng(last.latitude, last.longitude).also { remembered.save(it, last.time) }
    }

    @SuppressLint("MissingPermission")
    suspend fun current(): LatLng? {
        if (!hasPermission()) {
            return null
        }
        val last = withTimeoutOrNull(LAST_FIX_TIMEOUT_MS) {
            suspendCancellableCoroutine { continuation ->
                client.lastLocation
                    .addOnSuccessListener { continuation.resume(it) }
                    .addOnFailureListener { continuation.resume(null) }
            }
        }
        val age = last?.let { System.currentTimeMillis() - it.time }
        if (last != null && age != null && age < MAX_FIX_AGE_MS) {
            return LatLng(last.latitude, last.longitude).also { remembered.save(it, last.time) }
        }

        val request = CurrentLocationRequest.Builder()
            .setPriority(Priority.PRIORITY_HIGH_ACCURACY)
            .setDurationMillis(FRESH_FIX_TIMEOUT_MS)
            .build()
        val fresh = withTimeoutOrNull(FRESH_FIX_TIMEOUT_MS) {
            suspendCancellableCoroutine { continuation ->
                client.getCurrentLocation(request, null)
                    .addOnSuccessListener { continuation.resume(it) }
                    .addOnFailureListener { continuation.resume(null) }
            }
        }
        val fix = fresh ?: last ?: return null
        return LatLng(fix.latitude, fix.longitude).also { remembered.save(it, fix.time) }
    }

    /**
     * One Fused fix per second at high accuracy, **while someone is collecting** (C13b):
     * the phone's GPS as a backup for the watch's (`05 §PHONE_FIX`). The pace is that of the watch's
     * GPS (`03 §GPS`). Cancelling the collection withdraws the request, and that is what turns off
     * the phone's GPS: nothing here stays on by itself.
     *
     * With the app off screen, Android only delivers while a foreground service of type
     * `location` is up (`NavForegroundService`). Without permission, or if Play
     * Services refuses the request, the flow closes with the exception.
     */
    @SuppressLint("MissingPermission")
    fun updates(): Flow<PhoneFix> = callbackFlow {
        if (!hasPermission()) {
            close(SecurityException("no ACCESS_FINE_LOCATION"))
            awaitClose { }
            return@callbackFlow
        }
        val callback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                val location = result.lastLocation ?: return
                PhoneFix.of(
                    latitude = location.latitude,
                    longitude = location.longitude,
                    speedMps = if (location.hasSpeed()) location.speed else null,
                    bearingDeg = if (location.hasBearing()) location.bearing else null,
                    accuracyM = if (location.hasAccuracy()) location.accuracy else null,
                    fixElapsedMs = location.elapsedRealtimeNanos / 1_000_000,
                )?.let { trySend(it) }
            }
        }
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, UPDATE_INTERVAL_MS)
            .setMinUpdateIntervalMillis(UPDATE_INTERVAL_MS)
            .build()
        client.requestLocationUpdates(request, callback, Looper.getMainLooper())
            .addOnFailureListener { close(it) }
        awaitClose { client.removeLocationUpdates(callback) }
    }

    private companion object {
        /** One per second, like the watch's GPS (`03 §GPS`). */
        const val UPDATE_INTERVAL_MS = 1_000L
        const val MAX_FIX_AGE_MS = 60_000L // 04 §Favoritos: last known if newer than 60 s
        const val LAST_FIX_TIMEOUT_MS = 2_000L
        const val FRESH_FIX_TIMEOUT_MS = 8_000L
    }
}
