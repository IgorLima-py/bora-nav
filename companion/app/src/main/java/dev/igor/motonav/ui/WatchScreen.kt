package dev.igor.motonav.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import dev.igor.motonav.BuildConfig
import dev.igor.motonav.R
import dev.igor.motonav.link.LinkState
import dev.igor.motonav.link.SdkProblem
import dev.igor.motonav.link.WatchDevice
import dev.igor.motonav.ui.theme.Amber
import dev.igor.motonav.ui.theme.Cyan
import dev.igor.motonav.ui.theme.Fg
import dev.igor.motonav.ui.theme.Fg2
import dev.igor.motonav.ui.theme.Ink
import dev.igor.motonav.ui.theme.Off
import dev.igor.motonav.ui.theme.Surface1

/**
 * The Watch tab (sheet 2, `docs/design/telas.md` §5.2): it is where the phone's diagnostics live. The
 * connection (the device, the app on it, the phone's version and "Procurar de novo" (search again)), the
 * watch settings, the Mapbox token and the battery. Before sheet 2 all of this was on the main screen.
 */
@Composable
fun WatchScreen(
    state: LinkState,
    hasToken: Boolean,
    batteryExempt: Boolean,
    onRefresh: () -> Unit,
    onOpenGarminConnect: () -> Unit,
    onOpenSettings: () -> Unit,
    onSaveToken: (String) -> Unit,
    onAllowBattery: () -> Unit,
    onRedoSetup: () -> Unit = {},
) {
    Surface(modifier = Modifier.fillMaxSize(), color = Ink) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(stringResource(R.string.watch_tab), style = MaterialTheme.typography.titleLarge, color = Fg)

            Section(stringResource(R.string.watch_link)) {
                when {
                    state.initializing -> Text(stringResource(R.string.link_initializing), color = Fg2)
                    state.problem != null -> ProblemBlock(state.problem, onOpenGarminConnect)
                    state.devices.isEmpty() -> Text(stringResource(R.string.link_no_devices), color = Fg2)
                    else -> state.devices.forEach { DeviceCard(it) }
                }
                Text(
                    stringResource(R.string.app_version, BuildConfig.VERSION_NAME),
                    style = MaterialTheme.typography.bodySmall,
                    color = Fg2,
                )
                OutlinedButton(onClick = onRefresh) { Text(stringResource(R.string.action_refresh)) }
            }

            Section(stringResource(R.string.action_watch_settings)) {
                Text(stringResource(R.string.watch_settings_hint), style = MaterialTheme.typography.bodyMedium, color = Fg2)
                OutlinedButton(onClick = onOpenSettings, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.action_watch_settings))
                }
            }

            Section(stringResource(R.string.token_label)) { TokenBlock(hasToken, onSaveToken) }

            Section(stringResource(R.string.watch_battery)) { BatteryBlock(batteryExempt, onAllowBattery) }

            // First use again (C16.8b): whoever skipped a step comes back to it from here.
            TextButton(onClick = onRedoSetup) { Text(stringResource(R.string.setup_again)) }
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Surface(color = Surface1, shape = MaterialTheme.shapes.medium, modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, color = Fg)
            content()
        }
    }
}

/** The device: connected in cyan, gone in gray; the app on it, as text. */
@Composable
private fun DeviceCard(device: WatchDevice) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(
            painterResource(if (device.connected) R.drawable.ic_watch else R.drawable.ic_watch_off),
            contentDescription = null,
            tint = if (device.connected) Cyan else Off,
            modifier = Modifier.size(24.dp),
        )
        Column {
            Text(device.name, style = MaterialTheme.typography.bodyLarge, color = Fg)
            Text(
                stringResource(if (device.connected) R.string.device_connected else R.string.device_disconnected),
                style = MaterialTheme.typography.bodyMedium,
                color = Fg2,
            )
            val appStatus = when (device.appInstalled) {
                true -> R.string.device_app_installed
                false -> R.string.device_app_missing
                null -> R.string.device_app_unknown
            }
            Text(stringResource(appStatus), style = MaterialTheme.typography.bodySmall, color = Fg2)
        }
    }
}

/**
 * The battery exemption (C13a). It only informs and offers: the system dialog opens on tap, never
 * on its own.
 */
@Composable
private fun BatteryBlock(exempt: Boolean, onAllow: () -> Unit) {
    if (exempt) {
        Text(stringResource(R.string.battery_exempt), style = MaterialTheme.typography.bodyMedium, color = Fg2)
        return
    }
    Text(stringResource(R.string.battery_restricted), style = MaterialTheme.typography.bodyMedium, color = Fg)
    Button(onClick = onAllow) { Text(stringResource(R.string.battery_allow_long)) }
}

/** The Mapbox token is masked and never shown back (docs/08 §Conventions). */
@Composable
private fun TokenBlock(hasToken: Boolean, onSaveToken: (String) -> Unit) {
    var editing by remember { mutableStateOf(!hasToken) }
    var token by remember { mutableStateOf("") }

    if (!editing) {
        Text(stringResource(R.string.token_saved), style = MaterialTheme.typography.bodyMedium, color = Fg2)
        TextButton(onClick = { editing = true }) { Text(stringResource(R.string.token_change)) }
        return
    }
    Text(stringResource(R.string.token_why), style = MaterialTheme.typography.bodyMedium, color = Fg2)
    OutlinedTextField(
        value = token,
        onValueChange = { token = it },
        label = { Text(stringResource(R.string.token_label)) },
        singleLine = true,
        visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
        modifier = Modifier.fillMaxWidth(),
    )
    Button(
        onClick = {
            onSaveToken(token)
            token = ""
            editing = false
        },
        enabled = token.isNotBlank(),
    ) {
        Text(stringResource(R.string.token_save))
    }
}

@Composable
private fun ProblemBlock(problem: SdkProblem, onOpenGarminConnect: () -> Unit) {
    val message = when (problem) {
        SdkProblem.GCM_NOT_INSTALLED -> R.string.link_gcm_missing
        SdkProblem.GCM_NEEDS_UPGRADE -> R.string.link_gcm_outdated
        SdkProblem.SERVICE_ERROR -> R.string.link_service_error
        SdkProblem.SDK_SHUT_DOWN -> R.string.link_sdk_shutdown
    }
    Text(stringResource(message), color = Amber)
    Button(onClick = onOpenGarminConnect) { Text(stringResource(R.string.action_open_gcm)) }
}
