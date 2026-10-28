package dev.igor.motonav.share

import android.Manifest
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import dev.igor.motonav.BuildConfig
import dev.igor.motonav.R
import dev.igor.motonav.link.NOT_CONNECTED
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.geo.MapboxGeocoder
import dev.igor.motonav.geo.LocationSource
import dev.igor.motonav.geo.Place
import dev.igor.motonav.link.TransferProgress
import dev.igor.motonav.link.WatchLink
import dev.igor.motonav.nav.NavActivityBus
import dev.igor.motonav.nav.RerouteHub
import dev.igor.motonav.nav.RerouteSession
import dev.igor.motonav.nav.RouteIds
import dev.igor.motonav.proto.PackableRoute
import dev.igor.motonav.route.LatLng
import dev.igor.motonav.route.MapboxProvider
import dev.igor.motonav.route.RouteException
import dev.igor.motonav.route.RoutePrefs
import dev.igor.motonav.route.straightLineKm
import dev.igor.motonav.settings.TokenStore
import dev.igor.motonav.trips.TripRecorder
import dev.igor.motonav.ui.ConfirmDestinationScreen
import dev.igor.motonav.ui.theme.BoraTheme
import dev.igor.motonav.ui.theme.Ink
import java.util.Calendar
import kotlin.math.roundToInt
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * "Share -> Bora?" from Google Maps or Waze (docs/02 §Flows), and the
 * input of the main screen's address search (`EXTRA_DEST_*` extras).
 *
 * C8, in three steps, each with its own screen: resolve the destination, **confirm**
 * (name, approximate address, distance, Start/Cancel — `docs/04 §1`) and
 * then route + send, reporting each stage.
 *
 * `launchMode="singleTop"` delivers the second share to **this same
 * instance** when the screen is still open, and without [onNewIntent] it was
 * ignored: it was the "second share only works by closing the app" (measured
 * on the PC by `tools/e2e.py --dupla`, 2026-10-09: `am start` answered
 * "intent has been delivered to currently running top-most instance" and the
 * companion wrote no line at all.
 */
class ShareReceiverActivity : ComponentActivity() {

    private lateinit var watchLink: WatchLink
    private lateinit var tokens: TokenStore
    private lateinit var location: LocationSource
    private lateinit var geocoder: MapboxGeocoder
    private lateinit var resolver: LinkResolver

    private var status by mutableStateOf("")
    private var detail by mutableStateOf("")
    private var failed by mutableStateOf(false)

    /** Finished (well or badly) — only then does the close button appear. */
    private var finished by mutableStateOf(false)

    /** Destination resolved, waiting for the tap on Start. Null outside the confirmation. */
    private var confirmation by mutableStateOf<Confirmation?>(null)

    /** One job per step: a new share cancels all three. */
    private var resolveJob: Job? = null
    private var routeJob: Job? = null

    private class Confirmation(
        val destination: Destination,
        val address: String?,
        val distanceKm: Int?,
        /** From the tap on share: the RF-01 acceptance stopwatch. */
        val sharedAt: Long,
    )

    private val requestLocation = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            resolveDestination()
        } else {
            fail(getString(R.string.share_no_location_permission), "no location permission")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        EventLog.init(applicationContext)
        watchLink = WatchLink.of(applicationContext)
        tokens = TokenStore(applicationContext)
        location = LocationSource(applicationContext)
        geocoder = MapboxGeocoder(
            tokenProvider = { tokens.mapboxToken },
            onRequest = { tokens.countRouteRequest(currentYearMonth()) },
        )
        resolver = LinkResolver(
            mapboxGeocode = { query, near -> geocoder.search(query, near).firstOrNull()?.position },
        )

        setContent {
            BoraTheme {
                val pending = confirmation
                if (pending != null) {
                    ConfirmDestinationScreen(
                        label = pending.destination.label,
                        address = pending.address,
                        distanceKm = pending.distanceKm,
                        onStart = { startRoute(pending) },
                        onCancel = {
                            EventLog.i(TAG, "cancelled at the confirmation")
                            finish()
                        },
                    )
                } else {
                    ProgressScreen()
                }
            }
        }

        begin()
    }

    /**
     * Share with the screen already open (`singleTop`). Without this the new `Intent`
     * was swallowed and the watch stayed with the old route.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        EventLog.i(TAG, "new share with the screen open (onNewIntent)")
        begin()
    }

    // Without `watchLink.stop()`: this was exactly what forced closing the app
    // to be able to share again — the `shutdown` fell on the singleton of the
    // ConnectIQ and took the MainActivity link along.

    @Composable
    private fun ProgressScreen() {
        Surface(modifier = Modifier.fillMaxSize(), color = Ink) {
            Column(
                modifier = Modifier.fillMaxSize().systemBarsPadding().padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(stringResource(R.string.app_name), style = MaterialTheme.typography.headlineSmall)
                // Build of this APK — the watch screen shows its own.
                Text(
                    text = stringResource(R.string.app_version, BuildConfig.VERSION_NAME),
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(
                    text = status,
                    color = if (failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
                )
                if (detail.isNotBlank()) {
                    Text(detail, style = MaterialTheme.typography.bodySmall)
                }
                // The button only closes the screen — and closing in the middle of the
                // transfer cancels the send along with the
                // lifecycleScope. So it does not exist while
                // sending: it was a silent way to kill the route.
                if (finished) {
                    Button(onClick = { finish() }) {
                        Text(stringResource(R.string.share_close))
                    }
                }
            }
        }
    }

    /** Starts (or restarts) with the current `Intent`, dropping what was in progress. */
    private fun begin() {
        resolveJob?.cancel()
        routeJob?.cancel()
        status = getString(R.string.share_reading)
        detail = ""
        failed = false
        finished = false
        confirmation = null

        if (location.hasPermission()) {
            resolveDestination()
        } else {
            requestLocation.launch(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }

    /** Step 1: from what came in the `Intent` to the destination, stopping at the confirmation. */
    private fun resolveDestination() {
        val chosen = placeFromExtras(intent)
        val shared = sharedText()
        if (chosen == null && shared.isNullOrBlank()) {
            fail(getString(R.string.share_nothing), "empty share")
            return
        }
        if (!tokens.hasMapboxToken) {
            fail(getString(R.string.share_no_token), "no Mapbox token")
            return
        }

        resolveJob = lifecycleScope.launch {
            // Stopwatch of what Igor actually feels: from the tap on share
            // to the route being drawable on the watch. The log had the time of each
            // stage and **did not have the total**, which is precisely the acceptance number
            // of F1 (≤10 s) and what answers "why did it take so long?".
            val sharedAt = System.currentTimeMillis()
            try {
                status = getString(R.string.share_locating)
                val origin = location.current()
                    ?: throw RouteException("no current position", userText = R.string.share_no_fix)

                val destination: Destination
                var address: String? = null
                if (chosen != null) {
                    EventLog.i(TAG, "destination chosen from the search: ${EventLog.place("'${chosen.name}'")}")
                    destination = Destination(chosen.position, chosen.name)
                    address = chosen.address
                } else {
                    status = getString(R.string.share_resolving)
                    destination = resolver.resolve(shared.orEmpty(), origin)
                }
                detail = destination.label

                // A Maps link that falls into the wrong regex once asked for a route from São
                // Paulo to Bosnia, and the only clue was an "HTTP 422" from
                // Mapbox. Blocking here gives the right message and spends no request.
                val straight = straightLineKm(origin, destination.position)
                EventLog.i(TAG, "destination ${EventLog.place("'${destination.label}'")} at ${straight.roundToInt()} km in a straight line")
                if (straight > MAX_STRAIGHT_KM) {
                    throw ShareException(
                        "destination ${straight.roundToInt()} km from here: the shared link should not be this one",
                        R.string.share_too_far,
                        listOf(straight.roundToInt()),
                    )
                }

                // Approximate address is a courtesy: without it the confirmation looks the same.
                if (address == null) {
                    address = withTimeoutOrNull(ADDRESS_TIMEOUT_MS) { geocoder.reverse(destination.position) }
                }

                EventLog.i(TAG, "awaiting confirmation: ${EventLog.place("'${destination.label}' (${address ?: "no address"})")}")
                confirmation = Confirmation(destination, address, straight.roundToInt(), sharedAt)
            } catch (e: ShareException) {
                fail(getString(e.userText, *e.userArgs.toTypedArray()), e.message)
            } catch (e: RouteException) {
                fail(getString(e.userText), e.message)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                fail(getString(R.string.share_unexpected, e.message.orEmpty()), "unexpected error: ${e.message}")
            }
        }
    }

    /** Step 2, after Start: Mapbox route and send to the watch. */
    private fun startRoute(pending: Confirmation) {
        // Two taps before the screen recomposes must not open two routes.
        if (confirmation !== pending) {
            return
        }
        confirmation = null
        status = getString(R.string.share_locating)
        detail = pending.destination.label
        val tappedAt = System.currentTimeMillis()
        EventLog.i(TAG, "Start tapped ${tappedAt - pending.sharedAt} ms after the share")

        routeJob = lifecycleScope.launch {
            fun since() = System.currentTimeMillis() - pending.sharedAt
            val destination = pending.destination

            try {
                // New reading: the person may have moved while reading the screen, and the
                // the route starts from where it is now (the recent fix comes back right away).
                val origin = location.current()
                    ?: throw RouteException("no current position", userText = R.string.share_no_fix)

                status = getString(R.string.share_calculating)
                NavActivityBus.calculating(destination.label, fromWatch = false)
                val provider = MapboxProvider(
                    tokenProvider = { tokens.mapboxToken },
                    onRequest = { tokens.countRouteRequest(currentYearMonth()) },
                    avoidMotorways = { RoutePrefs.avoidMotorways(applicationContext) },
                )
                val result = provider.route(origin, null, destination.position, destination.via)
                // C16: the time here is the watch's, with Igor's pace, not Mapbox's car time.
                val watchS = TripRecorder.of(applicationContext).toWatchS(result.durationS)
                detail = "${destination.label} · ${result.distanceM / 1000} km · ${watchS / 60} min"
                EventLog.i(TAG, "Mapbox route ready in ${since()} ms since the share")

                val packable = result.toPackable(
                    routeId = RouteIds(applicationContext).next(),
                    destNameOverride = destination.label,
                    watchS = watchS,
                )

                // **The route goes first, alone.** The corridor is scenery and public
                // Overpass answered once in six in the street tests —
                // each failure cost 25–27 s of waiting before the route went out. It is what
                // `01 §RNF-02` always asked for: a usable route in ≤10 s,
                // corridor arriving in the background.
                status = getString(R.string.share_sending)
                NavActivityBus.sending(destination.label, fromWatch = false)
                // Only here are the previous route's recalculation and corridor dropped: if the
                // share dies before (cancelled, no position, Mapbox down), the
                // old route keeps navigating and can still be recalculated.
                val controller = RerouteHub.of(applicationContext)
                // C16.5: the corridor already starts being fetched here, while the route travels.
                controller.supersede(packable)
                var sent = false
                try {
                    sendToWatch(packable)
                    sent = true
                } finally {
                    // Cancelled or with an exception in the middle of the send: the old session is valid again.
                    if (!sent) controller.endSupersede()
                }

                // With the confirmation, the time to read the screen is the person's: the acceptance
                // of RF-01 (10,000 ms) counts **from Start**; the total since the
                // share stays in the log to compare with the F1 rounds.
                EventLog.i(
                    TAG,
                    "TOTAL share -> route on watch: ${since()} ms" +
                        (if (failed) " (FAILED)" else "") + " - RF-01 acceptance is 10,000 ms since Start",
                )
                EventLog.i(TAG, "since Start: ${System.currentTimeMillis() - tappedAt} ms")

                if (!failed) {
                    controller.register(RerouteSession.of(packable.routeId, destination, result))
                    controller.startCorridor(packable)
                } else {
                    controller.endSupersede()
                }
            } catch (e: ShareException) {
                fail(getString(e.userText, *e.userArgs.toTypedArray()), e.message)
            } catch (e: RouteException) {
                fail(getString(e.userText), e.message)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                fail(getString(R.string.share_unexpected, e.message.orEmpty()), "unexpected error: ${e.message}")
            } finally {
                NavActivityBus.idle()
            }
        }
    }

    private suspend fun sendToWatch(route: PackableRoute) {
        val ok = watchLink.sendRoute(route) { progress -> status = describe(progress) }
        if (!ok) {
            failed = true
        }
        finished = true
    }

    private fun describe(progress: TransferProgress): String = when {
        // The send error is technical and in English (goes to the log); the screen shows the one in its language.
        progress.error == NOT_CONNECTED -> getString(R.string.watch_not_connected)
        progress.error != null -> getString(R.string.share_send_failed)
        progress.done -> getString(R.string.share_done, progress.sentBytes, progress.elapsedMs)
        else -> getString(R.string.share_progress, progress.sentChunks, progress.totalChunks)
    }

    private fun sharedText(): String? = when (intent?.action) {
        Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
        Intent.ACTION_VIEW -> intent.dataString
        else -> null
    }

    /** [message] goes to the screen; [log], technical and in English, goes to `motonav.log` (C16.8b). */
    private fun fail(message: String, log: String? = null) {
        // The failure only appeared on screen: `motonav.log` stopped in the middle without saying
        // why, and whoever reads the log (Igor does not transcribe the screen) was left without the
        // cause. `tools/e2e.py` decides the exit code from this line.
        EventLog.w(TAG, "failed: ${log ?: message}")
        failed = true
        finished = true
        status = message
    }

    private fun currentYearMonth(): String {
        val now = Calendar.getInstance()
        return "%04d-%02d".format(now.get(Calendar.YEAR), now.get(Calendar.MONTH) + 1)
    }

    companion object {
        private const val TAG = "ShareReceiver"

        /** Above this the resolved destination is a parsing error, not a trip. */
        private const val MAX_STRAIGHT_KM = 500

        /**
         * How long to wait for the approximate address of the confirmation. It is a courtesy: the
         * screen cannot be stuck on a public service.
         */
        private const val ADDRESS_TIMEOUT_MS = 3_000L

        // Destination picked in the main screen's search: goes by extras, and the
        // confirmation is the same as the share's.
        private const val EXTRA_DEST_LAT = "dev.igor.motonav.DEST_LAT"
        private const val EXTRA_DEST_LON = "dev.igor.motonav.DEST_LON"
        private const val EXTRA_DEST_NAME = "dev.igor.motonav.DEST_NAME"
        private const val EXTRA_DEST_ADDRESS = "dev.igor.motonav.DEST_ADDRESS"

        /** The `Intent` that the main screen's search sends to the confirmation. */
        fun intentFor(context: Context, place: Place): Intent =
            Intent(context, ShareReceiverActivity::class.java)
                .putExtra(EXTRA_DEST_LAT, place.position.lat)
                .putExtra(EXTRA_DEST_LON, place.position.lon)
                .putExtra(EXTRA_DEST_NAME, place.name)
                .putExtra(EXTRA_DEST_ADDRESS, place.address)

        private fun placeFromExtras(intent: Intent?): Place? {
            if (intent == null || !intent.hasExtra(EXTRA_DEST_LAT) || !intent.hasExtra(EXTRA_DEST_LON)) {
                return null
            }
            val lat = intent.getDoubleExtra(EXTRA_DEST_LAT, Double.NaN)
            val lon = intent.getDoubleExtra(EXTRA_DEST_LON, Double.NaN)
            if (lat.isNaN() || lon.isNaN()) {
                return null
            }
            val name = intent.getStringExtra(EXTRA_DEST_NAME).orEmpty().ifBlank { "Destino" }
            return Place(name, intent.getStringExtra(EXTRA_DEST_ADDRESS).orEmpty(), LatLng(lat, lon))
        }
    }
}
