package dev.igor.motonav

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.pm.PackageManager
import android.os.Build
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.favorites.Favorite
import dev.igor.motonav.favorites.FavoritesStore
import dev.igor.motonav.geo.LocationSource
import dev.igor.motonav.geo.MapboxGeocoder
import dev.igor.motonav.geo.PhotonGeocoder
import dev.igor.motonav.geo.Place
import dev.igor.motonav.geo.PlaceSearch
import dev.igor.motonav.link.WatchLink
import dev.igor.motonav.nav.NavActivityBus
import dev.igor.motonav.nav.NavForegroundService
import dev.igor.motonav.nav.RerouteHub
import dev.igor.motonav.proto.ConfigKey
import dev.igor.motonav.route.LatLng
import dev.igor.motonav.route.RoutePrefs
import dev.igor.motonav.settings.BatteryExemption
import dev.igor.motonav.settings.TokenStore
import dev.igor.motonav.settings.WatchSettings
import dev.igor.motonav.settings.WatchSettingsStore
import dev.igor.motonav.share.ShareReceiverActivity
import dev.igor.motonav.trips.TripRecorder
import dev.igor.motonav.ui.FavoritesScreen
import dev.igor.motonav.ui.HomeStatus
import dev.igor.motonav.ui.MainScreen
import dev.igor.motonav.ui.SettingsScreen
import dev.igor.motonav.ui.SetupPrefs
import dev.igor.motonav.ui.SetupScreen
import dev.igor.motonav.ui.TripsScreen
import dev.igor.motonav.ui.WatchScreen
import dev.igor.motonav.ui.homeRecents
import dev.igor.motonav.ui.homeStatus
import dev.igor.motonav.ui.theme.BoraTheme
import dev.igor.motonav.ui.theme.Fg
import dev.igor.motonav.ui.theme.Fg2
import dev.igor.motonav.ui.theme.Ink
import dev.igor.motonav.ui.theme.OnPrimaryContainer
import dev.igor.motonav.ui.theme.PrimaryContainer
import dev.igor.motonav.ui.theme.Surface1
import java.util.Calendar
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** The three tabs of sheet 2 (`docs/design/telas.md` §5.2). */
private enum class Tab { HOME, TRIPS, WATCH }

class MainActivity : ComponentActivity() {

    private lateinit var watchLink: WatchLink
    private lateinit var tokens: TokenStore
    private lateinit var settingsStore: WatchSettingsStore
    private lateinit var geocoder: PlaceSearch
    private lateinit var location: LocationSource
    private lateinit var favorites: FavoritesStore

    /** Re-read on `onResume`: the exemption also changes through the system settings. */
    private var batteryExempt by mutableStateOf(false)
    private val batteryRequest = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        batteryExempt = BatteryExemption.granted(this)
        EventLog.i("MainActivity", "battery exemption after the request: ${if (batteryExempt) "yes" else "no"}")
    }

    /** First use (C16.8b): shown until completed, and the Watch tab redoes it. */
    private lateinit var setupPrefs: SetupPrefs
    private var inSetup by mutableStateOf(false)
    private var locationGranted by mutableStateOf(false)
    private var notifyGranted by mutableStateOf(false)
    private val locationRequest = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        locationGranted = it
        EventLog.i("MainActivity", "location after the request: ${if (it) "yes" else "no"}")
    }
    private val notifyRequest = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        notifyGranted = it
        EventLog.i("MainActivity", "notification after the request: ${if (it) "yes" else "no"}")
    }

    /** Goes up on every `onResume`: recents and the token are re-read when coming back from the confirmation. */
    private var resumes by mutableIntStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        // The header gradient runs behind the status bar (§5.1); the screen is always dark.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)

        EventLog.init(applicationContext)
        watchLink = WatchLink.of(applicationContext)
        tokens = TokenStore(applicationContext)
        settingsStore = WatchSettingsStore(applicationContext)
        location = LocationSource(applicationContext)
        favorites = FavoritesStore.of(applicationContext)
        setupPrefs = SetupPrefs(applicationContext)
        inSetup = !setupPrefs.done
        if (inSetup) EventLog.i("MainActivity", "first run: opened")
        // The hub receives the watch's NAV_START_REQ and resends the favorites on every connection;
        // without touching it here it would only be created on the first share.
        RerouteHub.of(applicationContext)
        // Photon first: the search destination is kept in `trips.json`, and the Mapbox geocode cannot
        // be stored (2.7.2). Mapbox stays as a fallback, for when Photon finds nothing or is down.
        geocoder = PlaceSearch.of(
            photon = PhotonGeocoder(),
            mapbox = MapboxGeocoder(
                tokenProvider = { tokens.mapboxToken },
                onRequest = {
                    val now = Calendar.getInstance()
                    tokens.countRouteRequest("%04d-%02d".format(now.get(Calendar.YEAR), now.get(Calendar.MONTH) + 1))
                },
            ),
            hasMapboxToken = { tokens.hasMapboxToken },
        )

        setContent {
            BoraTheme {
                val state = watchLink.state.collectAsStateWithLifecycle()
                val activity = NavActivityBus.state.collectAsStateWithLifecycle()
                var hasToken by remember { mutableStateOf(tokens.hasMapboxToken) }
                var tab by rememberSaveable { mutableStateOf(Tab.HOME) }
                var inSettings by remember { mutableStateOf(false) }
                var inFavorites by remember { mutableStateOf(false) }
                var favoriteList by remember { mutableStateOf(favorites.list()) }
                var favoriteStatus by remember { mutableStateOf<String?>(null) }

                // Back from the inner screens returns to the tab; on a tab that is not Home, returns to
                // Home; on Home it leaves the app.
                BackHandler(enabled = inSettings || inFavorites || tab != Tab.HOME) {
                    when {
                        inSettings -> inSettings = false
                        inFavorites -> inFavorites = false
                        else -> tab = Tab.HOME
                    }
                }

                fun openFavorites() {
                    favoriteList = favorites.list()
                    favoriteStatus = null
                    inFavorites = true
                }

                Surface(modifier = Modifier.fillMaxSize(), color = Ink) {
                    if (inSetup) {
                        // The token may arrive from outside (the `sim` variant's `TokenReceiver`, which the e2e uses to
                        // never type the real token): re-read every second while the step is open.
                        LaunchedEffect(resumes) {
                            while (true) {
                                hasToken = tokens.hasMapboxToken
                                delay(TOKEN_POLL_MS)
                            }
                        }
                        Box(modifier = Modifier.systemBarsPadding()) {
                            SetupScreen(
                                hasToken = hasToken,
                                onSaveToken = { value ->
                                    tokens.mapboxToken = value
                                    hasToken = tokens.hasMapboxToken
                                    EventLog.i("MainActivity", "first run: token saved (${value.length} characters)")
                                },
                                location = locationGranted,
                                onAllowLocation = { locationRequest.launch(Manifest.permission.ACCESS_FINE_LOCATION) },
                                notifyNeeded = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU,
                                notify = notifyGranted,
                                onAllowNotify = {
                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                        notifyRequest.launch(Manifest.permission.POST_NOTIFICATIONS)
                                    }
                                },
                                battery = batteryExempt,
                                onAllowBattery = { requestBatteryExemption() },
                                link = state.value,
                                onOpenGcm = { openGarminConnect() },
                                onTestConnection = { testConnection() },
                                onFinish = {
                                    setupPrefs.done = true
                                    inSetup = false
                                    tab = Tab.HOME
                                    EventLog.i("MainActivity", "first run: done")
                                },
                            )
                        }
                    } else if (inFavorites) {
                        Box(modifier = Modifier.systemBarsPadding()) {
                            FavoritesScreen(
                                favorites = favoriteList,
                                hasToken = hasToken,
                                status = favoriteStatus,
                                onSearch = { text -> geocoder.search(text, location.currentOrNull()) },
                                onSave = { favorite ->
                                    val saved = favorites.save(favorite)
                                    favoriteList = favorites.list()
                                    favoriteStatus = getString(R.string.fav_sending)
                                    lifecycleScope.launch {
                                        favoriteStatus = pushFavorites("saved ${saved.id}")
                                    }
                                },
                                onDelete = { id ->
                                    favorites.delete(id)
                                    favoriteList = favorites.list()
                                    favoriteStatus = getString(R.string.fav_sending)
                                    lifecycleScope.launch {
                                        favoriteStatus = pushFavorites("deleted $id")
                                    }
                                },
                                onBack = { inFavorites = false },
                            )
                        }
                    } else if (inSettings) {
                        var avoidMotorways by remember { mutableStateOf(RoutePrefs.avoidMotorways(applicationContext)) }
                        Box(modifier = Modifier.systemBarsPadding()) {
                            SettingsScreen(
                                initial = remember { settingsStore.load() },
                                onSend = { values -> sendSettings(values) },
                                onReset = { resetSettings() },
                                onBack = { inSettings = false },
                                avoidMotorways = avoidMotorways,
                                onAvoidMotorways = { on ->
                                    RoutePrefs.setAvoidMotorways(applicationContext, on)
                                    avoidMotorways = on
                                    EventLog.i("Settings", "avoid highways ${if (on) "on" else "off"}")
                                },
                            )
                        }
                    } else {
                        Column(modifier = Modifier.fillMaxSize()) {
                            Box(modifier = Modifier.weight(1f)) {
                                when (tab) {
                                    Tab.HOME -> {
                                        val recorder = remember { TripRecorder.of(applicationContext) }
                                        val recents = remember(resumes) {
                                            homeRecents(resources, recorder.recents(), recorder.list(), System.currentTimeMillis())
                                        }
                                        MainScreen(
                                            status = homeStatus(
                                                resources,
                                                state.value,
                                                batteryExempt,
                                                hasToken,
                                                activity.value,
                                                BuildConfig.VERSION_NAME,
                                            ),
                                            favorites = favoriteList,
                                            recents = recents,
                                            onSearch = { text -> geocoder.search(text, location.currentOrNull()) },
                                            onPickPlace = { place -> startNavigation(place) },
                                            onPickFavorite = { favorite -> pickFavorite(favorite) { openFavorites() } },
                                            onEditFavorites = { openFavorites() },
                                            onOpenTrips = { tab = Tab.TRIPS },
                                            onAction = { action ->
                                                when (action) {
                                                    HomeStatus.Action.INSTALL_GCM,
                                                    HomeStatus.Action.UPDATE_GCM,
                                                    HomeStatus.Action.OPEN_GCM,
                                                    -> openGarminConnect()
                                                    HomeStatus.Action.ALLOW_BATTERY -> requestBatteryExemption()
                                                    HomeStatus.Action.SAVE_TOKEN -> tab = Tab.WATCH
                                                }
                                            },
                                        )
                                    }
                                    Tab.TRIPS -> Box(modifier = Modifier.statusBarsPadding()) {
                                        TripsScreen(
                                            trips = remember(resumes) { TripRecorder.of(applicationContext).list() },
                                            onBack = { tab = Tab.HOME },
                                        )
                                    }
                                    Tab.WATCH -> WatchScreen(
                                        state = state.value,
                                        hasToken = hasToken,
                                        batteryExempt = batteryExempt,
                                        onRefresh = { watchLink.refreshDevices() },
                                        onOpenGarminConnect = { openGarminConnect() },
                                        onOpenSettings = { inSettings = true },
                                        onSaveToken = { value ->
                                            tokens.mapboxToken = value
                                            hasToken = tokens.hasMapboxToken
                                        },
                                        onAllowBattery = { requestBatteryExemption() },
                                        onRedoSetup = {
                                            inSetup = true
                                            EventLog.i("MainActivity", "first run: redone from the Watch tab")
                                        },
                                    )
                                }
                            }
                            BoraNavigationBar(tab) { tab = it }
                        }
                    }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        batteryExempt = BatteryExemption.granted(this)
        locationGranted = granted(Manifest.permission.ACCESS_FINE_LOCATION)
        notifyGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            granted(Manifest.permission.POST_NOTIFICATIONS)
        resumes++
        // With the app on screen the service starts with the `location` type, and keeps listening to the watch (C16.5).
        NavForegroundService.listen(this)
    }

    private fun requestBatteryExemption() {
        try {
            batteryRequest.launch(BatteryExemption.request(this))
        } catch (e: ActivityNotFoundException) {
            // Some devices lack this screen; the path is then through the system settings.
            EventLog.w("MainActivity", "the system has no battery exemption dialog")
        }
    }

    /**
     * Sends the whole list to the watch (`FAVORITES`, `05 §FAVORITES`) and returns the
     * line the screen shows. No watch nearby is not an error: the list goes out
     * again on the next connection (`RerouteHub`, `onWatchReady`).
     */
    private suspend fun pushFavorites(why: String): String {
        withTimeoutOrNull(SDK_READY_TIMEOUT_MS) { watchLink.state.first { !it.initializing } }
        val items = favorites.wire()
        val ok = watchLink.sendFavorites(items) { progress ->
            progress.error?.let { EventLog.w("MainActivity", "favorites: $it") }
        }
        // Only the count: a favorite's name and address are sensitive data.
        EventLog.i("MainActivity", "favorites ($why): ${items.size} on the watch, ${if (ok) "delivered" else "NOT delivered"}")
        return if (ok) {
            resources.getQuantityString(R.plurals.fav_sent, items.size, items.size)
        } else {
            getString(R.string.fav_not_sent)
        }
    }

    private fun granted(permission: String): Boolean =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /**
     * The first-use link test: the favorites list, which the watch confirms with an ACK. It
     * is harmless (it is the same one sent on every connection) and proves both directions.
     */
    private suspend fun testConnection(): Boolean {
        withTimeoutOrNull(SDK_READY_TIMEOUT_MS) { watchLink.state.first { !it.initializing } }
        val ok = watchLink.sendFavorites(favorites.wire()) { progress ->
            progress.error?.let { EventLog.w("MainActivity", "link test: $it") }
        }
        EventLog.i("MainActivity", "first run: link test ${if (ok) "confirmed" else "no response"}")
        return ok
    }

    /** Search result -> the same confirmation as the share. */
    private fun startNavigation(place: Place) {
        EventLog.i("MainActivity", "search destination: ${EventLog.place("'${place.name}'")}")
        startActivity(ShareReceiverActivity.intentFor(this, place))
    }

    /** A favorite with a place opens the confirmation; with no place yet, it opens the edit to pick one. */
    private fun pickFavorite(favorite: Favorite, edit: () -> Unit) {
        val lat = favorite.lat
        val lon = favorite.lon
        if (lat == null || lon == null) {
            edit()
            return
        }
        startNavigation(Place(favorite.name, favorite.address ?: "", LatLng(lat, lon)))
    }

    /** `CONFIG` with all the screen's values. The SDK may still be starting: waits for it. */
    private suspend fun sendSettings(values: Map<ConfigKey, Int>): Boolean {
        val entries = WatchSettings.entries(values)
        val ok = deliverConfig(entries)
        if (ok) {
            settingsStore.save(values)
        }
        return ok
    }

    /** Empty list = the watch goes back to its defaults. */
    private suspend fun resetSettings(): Boolean {
        val ok = deliverConfig(emptyList())
        if (ok) {
            settingsStore.save(WatchSettings.defaults())
        }
        return ok
    }

    private suspend fun deliverConfig(entries: List<Pair<Int, Int>>): Boolean {
        withTimeoutOrNull(SDK_READY_TIMEOUT_MS) { watchLink.state.first { !it.initializing } }
        val ok = watchLink.sendConfig(entries) { progress ->
            progress.error?.let { EventLog.w("MainActivity", "config: $it") }
        }
        val what = if (entries.isEmpty()) "default" else entries.joinToString(" ") { (id, v) -> "$id=$v" } // log
        EventLog.i("MainActivity", "watch settings $what ${if (ok) "delivered" else "NOT delivered"}")
        return ok
    }

    // No `watchLink.stop()`: the link is unique per process and tearing it down here
    // also killed the share screen's one (see WatchLink §instance).

    private companion object {
        const val SDK_READY_TIMEOUT_MS = 10_000L

        /** Re-reading the token on first use: one prefs read per second. A choice, not a measurement. */
        const val TOKEN_POLL_MS = 1_000L
    }

    /** Opens Garmin Connect Mobile, falling back to its store page when missing. */
    private fun openGarminConnect() {
        val launch = packageManager.getLaunchIntentForPackage(MotoNavIds.GCM_PACKAGE)
        if (launch != null) {
            startActivity(launch)
            return
        }
        val market = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=${MotoNavIds.GCM_PACKAGE}"))
        try {
            startActivity(market)
        } catch (e: ActivityNotFoundException) {
            startActivity(
                Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("https://play.google.com/store/apps/details?id=${MotoNavIds.GCM_PACKAGE}"),
                ),
            )
        }
    }
}

/**
 * The tab bar (§5.2): 80 dp, background `#12181E`, indicator `#0E3A47`. The icon is filled only on the
 * current tab (home); the other two have no filled version in the brand geometry.
 */
@Composable
private fun BoraNavigationBar(tab: Tab, onSelect: (Tab) -> Unit) {
    val colors = NavigationBarItemDefaults.colors(
        selectedIconColor = OnPrimaryContainer,
        selectedTextColor = Fg,
        indicatorColor = PrimaryContainer,
        unselectedIconColor = Fg2,
        unselectedTextColor = Fg2,
    )
    NavigationBar(containerColor = Surface1) {
        NavigationBarItem(
            selected = tab == Tab.HOME,
            onClick = { onSelect(Tab.HOME) },
            icon = { Icon(painterResource(if (tab == Tab.HOME) R.drawable.ic_home_fill else R.drawable.ic_home), contentDescription = null) },
            label = { Text(stringResource(R.string.tab_home), style = MaterialTheme.typography.labelMedium) },
            colors = colors,
        )
        NavigationBarItem(
            selected = tab == Tab.TRIPS,
            onClick = { onSelect(Tab.TRIPS) },
            icon = { Icon(painterResource(R.drawable.ic_route), contentDescription = null) },
            label = { Text(stringResource(R.string.tab_trips), style = MaterialTheme.typography.labelMedium) },
            colors = colors,
        )
        NavigationBarItem(
            selected = tab == Tab.WATCH,
            onClick = { onSelect(Tab.WATCH) },
            icon = { Icon(painterResource(R.drawable.ic_watch), contentDescription = null) },
            label = { Text(stringResource(R.string.watch_tab), style = MaterialTheme.typography.labelMedium) },
            colors = colors,
        )
    }
}
