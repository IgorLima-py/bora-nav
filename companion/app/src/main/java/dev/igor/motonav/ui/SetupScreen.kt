package dev.igor.motonav.ui

import android.content.Context
import android.content.res.Resources
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.igor.motonav.R
import dev.igor.motonav.link.LinkState
import dev.igor.motonav.link.SdkProblem
import dev.igor.motonav.ui.theme.Amber
import dev.igor.motonav.ui.theme.Cyan
import dev.igor.motonav.ui.theme.Fg2
import dev.igor.motonav.ui.theme.Ink
import dev.igor.motonav.ui.theme.Surface1
import kotlinx.coroutines.launch

/**
 * First use (C16.8b): the public APK carries no Mapbox token (`docs/PUBLICAR.md`), so whoever
 * installs it needs a path to the first route without help. There are four steps: the token, the
 * permissions, the watch and done. No step traps you: you can skip and sort it out later in the
 * Watch tab, which also redoes first use.
 */
object Setup {

    enum class Step { TOKEN, PERMISSIONS, WATCH, DONE }

    /** Where to create the free account and copy the "Default public token". */
    const val MAPBOX_SIGNUP = "https://account.mapbox.com/auth/signup/"

    /**
     * Mapbox's public token starts with `pk.` and has a JWT behind it (Igor's has 90 characters).
     * An `sk.` (secret) would also work, but must not go on a phone.
     */
    fun looksLikeToken(text: String): Boolean {
        val t = text.trim()
        return t.startsWith("pk.") && t.length >= MIN_TOKEN && t.none { it.isWhitespace() }
    }

    /** The minimum size accepted: `pk.` plus two JWT pieces. A choice, not a measurement. */
    private const val MIN_TOKEN = 40

    /** What is still missing, in the words of each step, for the done screen. */
    fun missing(
        res: Resources,
        hasToken: Boolean,
        location: Boolean,
        notify: Boolean,
        battery: Boolean,
        link: LinkState,
    ): List<String> = buildList {
        if (!hasToken) add(res.getString(R.string.token_label))
        if (!location) add(res.getString(R.string.setup_perm_location))
        if (!notify) add(res.getString(R.string.setup_perm_notify))
        if (!battery) add(res.getString(R.string.setup_perm_battery))
        if (link.problem == SdkProblem.GCM_NOT_INSTALLED) add(res.getString(R.string.setup_watch_gcm))
        else if (!link.initializing && link.devices.isEmpty()) add(res.getString(R.string.setup_watch_paired))
    }
}

/** Whether first use has been done (or skipped to the end). Stays on the device, outside the backup. */
class SetupPrefs(context: Context) {
    private val prefs = context.getSharedPreferences("motonav_setup", Context.MODE_PRIVATE)

    var done: Boolean
        get() = prefs.getBoolean(KEY_DONE, false)
        set(value) = prefs.edit().putBoolean(KEY_DONE, value).apply()

    private companion object {
        const val KEY_DONE = "done"
    }
}

/**
 * @param notifyNeeded false below Android 13, where the notification does not ask for permission.
 * @param onSaveToken saves a token that passed [Setup.looksLikeToken].
 * @param onTestConnection sends the favorites to the watch and returns whether it confirmed (ACK).
 */
@Composable
fun SetupScreen(
    hasToken: Boolean,
    onSaveToken: (String) -> Unit,
    location: Boolean,
    onAllowLocation: () -> Unit,
    notifyNeeded: Boolean,
    notify: Boolean,
    onAllowNotify: () -> Unit,
    battery: Boolean,
    onAllowBattery: () -> Unit,
    link: LinkState,
    onOpenGcm: () -> Unit,
    onTestConnection: suspend () -> Boolean,
    onFinish: () -> Unit,
) {
    var step by rememberSaveable { mutableStateOf(Setup.Step.TOKEN) }
    val steps = Setup.Step.entries
    val index = steps.indexOf(step)

    Surface(modifier = Modifier.fillMaxSize(), color = Ink) {
        Column(
            modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp, vertical = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(stringResource(R.string.setup_title), style = MaterialTheme.typography.headlineMedium)
            Text(
                stringResource(R.string.setup_step, index + 1, steps.size),
                style = MaterialTheme.typography.labelMedium,
                color = Cyan,
                modifier = Modifier.testTag("setup_step"),
            )
            Column(
                modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                when (step) {
                    Setup.Step.TOKEN -> TokenStep(hasToken, onSaveToken)
                    Setup.Step.PERMISSIONS -> PermissionsStep(
                        location, onAllowLocation, notifyNeeded, notify, onAllowNotify, battery, onAllowBattery,
                    )
                    Setup.Step.WATCH -> WatchStep(link, onOpenGcm, onTestConnection)
                    Setup.Step.DONE -> DoneStep(
                        Setup.missing(
                            LocalContext.current.resources, hasToken, location, notify || !notifyNeeded, battery, link,
                        ),
                    )
                }
            }
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                if (index > 0) {
                    TextButton(onClick = { step = steps[index - 1] }) { Text(stringResource(R.string.setup_back)) }
                }
                Spacer(Modifier.weight(1f))
                if (step == Setup.Step.DONE) {
                    Button(onClick = onFinish, modifier = Modifier.testTag("setup_finish")) {
                        Text(stringResource(R.string.setup_finish))
                    }
                } else {
                    Button(onClick = { step = steps[index + 1] }, modifier = Modifier.testTag("setup_next")) {
                        Text(stringResource(R.string.setup_next))
                    }
                }
            }
        }
    }
}

@Composable
private fun StepTitle(title: Int, body: Int) {
    Text(stringResource(title), style = MaterialTheme.typography.titleLarge)
    Text(stringResource(body), style = MaterialTheme.typography.bodyMedium, color = Fg2)
}

@Composable
private fun TokenStep(hasToken: Boolean, onSaveToken: (String) -> Unit) {
    StepTitle(R.string.setup_token_title, R.string.setup_token_body)
    val uri = LocalUriHandler.current
    OutlinedButton(onClick = { uri.openUri(Setup.MAPBOX_SIGNUP) }) {
        Text(stringResource(R.string.setup_token_link))
    }
    var text by rememberSaveable { mutableStateOf("") }
    var bad by remember { mutableStateOf(false) }
    // A token that arrives from outside (the `TokenReceiver`, or pasted again) clears the earlier refusal.
    LaunchedEffect(hasToken) { if (hasToken) bad = false }
    OutlinedTextField(
        value = text,
        onValueChange = {
            text = it
            bad = false
        },
        label = { Text(stringResource(R.string.token_label)) },
        singleLine = true,
        isError = bad,
        modifier = Modifier.fillMaxWidth().testTag("setup_token"),
    )
    Button(
        onClick = {
            if (Setup.looksLikeToken(text)) {
                onSaveToken(text.trim())
                text = ""
            } else {
                bad = true
            }
        },
        enabled = text.isNotBlank(),
    ) {
        Text(stringResource(R.string.token_save))
    }
    when {
        bad -> Text(stringResource(R.string.setup_token_bad), color = MaterialTheme.colorScheme.error)
        hasToken -> Done(stringResource(R.string.setup_token_ok))
    }
}

@Composable
private fun PermissionsStep(
    location: Boolean,
    onAllowLocation: () -> Unit,
    notifyNeeded: Boolean,
    notify: Boolean,
    onAllowNotify: () -> Unit,
    battery: Boolean,
    onAllowBattery: () -> Unit,
) {
    StepTitle(R.string.setup_perms_title, R.string.setup_perms_body)
    Permission(R.drawable.ic_route, R.string.setup_perm_location, R.string.setup_perm_location_why, location, onAllowLocation)
    if (notifyNeeded) {
        Permission(R.drawable.ic_watch, R.string.setup_perm_notify, R.string.setup_perm_notify_why, notify, onAllowNotify)
    }
    Permission(R.drawable.ic_bolt, R.string.setup_perm_battery, R.string.setup_perm_battery_why, battery, onAllowBattery)
}

@Composable
private fun Permission(icon: Int, title: Int, why: Int, granted: Boolean, onAllow: () -> Unit) {
    Surface(color = Surface1, shape = MaterialTheme.shapes.medium, modifier = Modifier.fillMaxWidth()) {
        Row(modifier = Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                painterResource(icon),
                contentDescription = null,
                tint = if (granted) Cyan else Amber,
                modifier = Modifier.padding(end = 12.dp).size(22.dp),
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(stringResource(title), style = MaterialTheme.typography.titleSmall)
                Text(stringResource(why), style = MaterialTheme.typography.bodySmall, color = Fg2)
            }
            if (granted) {
                Text(stringResource(R.string.setup_granted), color = Cyan)
            } else {
                TextButton(onClick = onAllow) { Text(stringResource(R.string.setup_allow)) }
            }
        }
    }
}

@Composable
private fun WatchStep(link: LinkState, onOpenGcm: () -> Unit, onTestConnection: suspend () -> Boolean) {
    StepTitle(R.string.setup_watch_title, R.string.setup_watch_body)
    val gcm = link.problem != SdkProblem.GCM_NOT_INSTALLED && link.problem != SdkProblem.GCM_NEEDS_UPGRADE
    val device = link.devices.firstOrNull { it.connected } ?: link.devices.firstOrNull()
    Check(R.string.setup_watch_gcm, if (link.initializing) null else gcm)
    Check(R.string.setup_watch_paired, if (link.initializing) null else device != null)
    Check(R.string.setup_watch_app, device?.appInstalled)
    if (!gcm || device == null) {
        OutlinedButton(onClick = onOpenGcm) { Text(stringResource(R.string.action_open_gcm)) }
    }
    val scope = rememberCoroutineScope()
    var testing by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<Boolean?>(null) }
    Button(
        onClick = {
            testing = true
            result = null
            scope.launch {
                result = onTestConnection()
                testing = false
            }
        },
        enabled = !testing,
        modifier = Modifier.testTag("setup_test"),
    ) {
        Text(stringResource(if (testing) R.string.setup_watch_testing else R.string.setup_watch_test))
    }
    when (result) {
        true -> Done(stringResource(R.string.setup_watch_test_ok))
        false -> Text(stringResource(R.string.setup_watch_test_fail), color = MaterialTheme.colorScheme.error)
        null -> Unit
    }
}

/** A watch line: yes (cyan), no (amber) or not known yet (gray). */
@Composable
private fun Check(label: Int, ok: Boolean?) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = when (ok) {
                true -> "✓"
                false -> "!"
                null -> "…"
            },
            color = when (ok) {
                true -> Cyan
                false -> Amber
                null -> Fg2
            },
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.padding(end = 12.dp),
        )
        Text(stringResource(label), style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun Done(text: String) {
    Text(text, color = Cyan, style = MaterialTheme.typography.bodyMedium)
}

@Composable
private fun DoneStep(missing: List<String>) {
    StepTitle(R.string.setup_done_title, R.string.setup_done_body)
    if (missing.isNotEmpty()) {
        Text(
            stringResource(R.string.setup_done_missing, missing.joinToString(", ")),
            color = Amber,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}
