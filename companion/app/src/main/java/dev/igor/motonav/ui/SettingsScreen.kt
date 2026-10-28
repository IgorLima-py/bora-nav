package dev.igor.motonav.ui

import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
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
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import dev.igor.motonav.R
import dev.igor.motonav.proto.ConfigKey
import dev.igor.motonav.settings.WatchSetting
import dev.igor.motonav.settings.WatchSettings
import dev.igor.motonav.ui.theme.Amber
import dev.igor.motonav.ui.theme.Cyan
import dev.igor.motonav.ui.theme.Fg2
import dev.igor.motonav.ui.theme.OnAmber
import dev.igor.motonav.ui.theme.Surface1
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * "Watch settings" (C8): the `CONFIG` numbers (`05 §CONFIG`) without a cable and without
 * sideload. **Since C16.5 the control sends on its own**, [AUTO_SEND_MS] after the
 * finger stops (Igor asked for a UI "fácil de redimensionar": tweak and see on the wrist, without
 * hunting for the button). **Send again** repeats the last send, and **Everything to default** sends an
 * empty `CONFIG`, which returns the watch to its default.
 *
 * Since 1.2.6 the screen is in groups ([WatchSettings.sections]): Igor found the list of 22
 * lines confusing (2026-10-22). Bench groups stay collapsed and say in the title
 * how many settings are off the default.
 *
 * @param initial what was sent last time ([dev.igor.motonav.settings.WatchSettingsStore]).
 * @param onSend receives the values and returns whether the watch confirmed (ACK 0x09).
 * @param drillArmed the dead-app drill (C16, [dev.igor.motonav.nav.KillDrill]) is armed;
 *   it sits in the tests group, but belongs to the phone, not to `CONFIG`.
 * @param avoidMotorways the "Evitar vias expressas" (C16, [dev.igor.motonav.route.RoutePrefs]), also
 *   the phone's: it applies to the next route request.
 * @param previewActive the control the watch preview starts by highlighting; only the screenshot
 *   (`SettingsScreenTest`) usa.
 */
@Composable
fun SettingsScreen(
    initial: Map<ConfigKey, Int>,
    onSend: suspend (values: Map<ConfigKey, Int>) -> Boolean,
    onReset: suspend () -> Boolean,
    onBack: () -> Unit,
    drillArmed: Boolean = false,
    onDrillArmed: (Boolean) -> Unit = {},
    avoidMotorways: Boolean = true,
    onAvoidMotorways: (Boolean) -> Unit = {},
    previewActive: ConfigKey? = null,
) {
    var values by remember { mutableStateOf(initial) }
    var busy by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<String?>(null) }
    var resultIsError by remember { mutableStateOf(false) }
    // What the watch already confirmed: the automatic send only goes out when the screen differs from this.
    var delivered by remember { mutableStateOf(initial) }
    val scope = rememberCoroutineScope()
    val res = LocalContext.current.resources
    // The control the finger touched last: the preview lights up its part and dims the rest, and
    // goes back to normal [PREVIEW_HOLD_MS] after the last touch.
    var active by remember { mutableStateOf(previewActive) }
    var touches by remember { mutableStateOf(0) }
    LaunchedEffect(touches) {
        if (touches == 0) return@LaunchedEffect
        delay(PREVIEW_HOLD_MS)
        active = null
    }

    fun send(snapshot: Map<ConfigKey, Int>) {
        busy = true
        result = null
        scope.launch {
            val ok = onSend(snapshot)
            resultIsError = !ok
            if (ok) delivered = snapshot
            result = res.getString(if (ok) R.string.settings_sent else R.string.settings_not_confirmed)
            busy = false
        }
    }

    // The automatic send: each change restarts the wait, so only one send goes out per gesture, and
    // what changed during a send goes out when it ends (`busy` is also a key).
    LaunchedEffect(values, busy) {
        if (busy || values == delivered || WatchSettings.conflict(values) != null) return@LaunchedEffect
        delay(AUTO_SEND_MS)
        send(values)
    }

    Surface(modifier = Modifier.fillMaxSize()) {
        // The groups scroll; the send result and the two buttons stay fixed at the bottom.
        Column(
            modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = stringResource(R.string.settings_title),
                    style = MaterialTheme.typography.headlineMedium,
                )
                TextButton(onClick = onBack) { Text(stringResource(R.string.settings_back)) }
            }
            Text(
                text = stringResource(R.string.settings_intro),
                style = MaterialTheme.typography.bodySmall,
                color = Fg2,
            )
            // The preview stays fixed on top, in view while the list scrolls.
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                WatchPreview(values = values, active = active, modifier = Modifier.size(PREVIEW_SIZE))
                val part = active?.let { previewPartName(it) }
                Text(
                    text = part?.let { stringResource(R.string.settings_touching, stringResource(it)) }
                        ?: stringResource(R.string.settings_touch_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = if (part != null) Cyan else Fg2,
                )
            }

            Column(
                modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                WatchSettings.sections.forEach { section ->
                    val isTests = section.keys.contains(ConfigKey.STREET_DIAG)
                    val changed = section.keys.count { values[it] != WatchSettings.of(it).default } +
                        if (isTests && drillArmed) 1 else 0
                    SettingsSection(
                        title = stringResource(section.title),
                        icon = section.icon,
                        startOpen = !section.collapsed,
                        badge = if (changed == 0) null else pluralStringResource(R.plurals.settings_changed, changed, changed),
                    ) {
                        section.keys.forEach { key ->
                            SettingRow(
                                setting = WatchSettings.of(key),
                                values = values,
                                enabled = !busy,
                                onChange = {
                                    values = values + (key to it)
                                    active = key
                                    touches++
                                },
                            )
                        }
                        if (isTests) DrillRow(armed = drillArmed, onChange = onDrillArmed)
                    }
                    // The route belongs to the phone and has no `CONFIG`: it comes right after the map.
                    if (section.keys.contains(ConfigKey.ZOOM)) {
                        SettingsSection(title = stringResource(R.string.section_route), icon = R.drawable.ic_route) {
                            MotorwayRow(on = avoidMotorways, onChange = onAvoidMotorways)
                        }
                    }
                }
            }

            val conflict = WatchSettings.conflict(values)
            conflict?.let {
                Text(text = it.text(res), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = result ?: if (busy) stringResource(R.string.settings_sending) else "",
                    color = if (resultIsError) MaterialTheme.colorScheme.error else Fg2,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = { send(values) }, enabled = !busy && conflict == null) {
                    Text(stringResource(R.string.settings_send))
                }
                TextButton(
                    onClick = {
                        busy = true
                        result = null
                        scope.launch {
                            val ok = onReset()
                            resultIsError = !ok
                            if (ok) {
                                values = WatchSettings.defaults()
                                delivered = values
                                result = res.getString(R.string.settings_reset_done)
                            } else {
                                result = res.getString(R.string.settings_not_confirmed)
                            }
                            busy = false
                        }
                    },
                    enabled = !busy,
                ) {
                    Text(stringResource(R.string.settings_reset))
                }
            }
            // ODbL requires attribution where the data appears: the watch's streets and cameras (C16.6), and
            // the pardal asks for its sources, CET-SP (CC BY) first (C16.7b, `PardalAttributionTest`).
            Text(
                text = stringResource(R.string.osm_attribution),
                style = MaterialTheme.typography.bodySmall,
                color = Fg2,
            )
        }
    }
}

/**
 * A screen group: a card that opens and closes by its title (Igor's request, 2026-10-22). Closed,
 * it shows in the title how many of its settings are off the default, so no test lever
 * gets forgotten.
 */
@Composable
private fun SettingsSection(
    title: String,
    @DrawableRes icon: Int,
    startOpen: Boolean = true,
    badge: String? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    var open by rememberSaveable(title) { mutableStateOf(startOpen) }
    Surface(color = Surface1, shape = MaterialTheme.shapes.medium, modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { open = !open },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconLabel(
                    icon = icon,
                    text = title,
                    style = MaterialTheme.typography.titleMedium,
                    tint = Cyan,
                    modifier = Modifier.weight(1f),
                    iconSize = 22,
                )
                badge?.takeIf { !open }?.let {
                    Text(
                        text = it,
                        style = MaterialTheme.typography.labelMedium,
                        color = OnAmber,
                        modifier = Modifier
                            .background(Amber, RoundedCornerShape(50))
                            .padding(horizontal = 8.dp, vertical = 2.dp),
                    )
                }
                Text(
                    text = if (open) "▴" else "▾",
                    color = Fg2,
                    modifier = Modifier.padding(start = 10.dp),
                )
            }
            if (open) content()
        }
    }
}

@Composable
private fun SettingRow(
    setting: WatchSetting,
    values: Map<ConfigKey, Int>,
    enabled: Boolean,
    onChange: (Int) -> Unit,
) {
    val value = values[setting.key] ?: setting.default
    if (setting.switch) {
        SwitchRow(setting, value, enabled, onChange)
        return
    }
    if (setting.radio) {
        RadioRow(setting, value, enabled, onChange)
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconLabel(
                icon = settingIcon(setting.key),
                text = stringResource(setting.label),
                style = MaterialTheme.typography.titleSmall,
                tint = Fg2,
                modifier = Modifier.weight(1f),
            )
            Text(setting.format(LocalContext.current.resources, value), style = MaterialTheme.typography.titleSmall, color = Cyan)
        }
        // With more than 20 positions the dots become a dotted strip that does not help aiming
        // (63..112 % has 49): the control stays smooth and the value still jumps step by step.
        val positions = (setting.max - setting.min) / setting.step
        val steps = if (positions > MAX_TICKS) 0 else (positions - 1).coerceAtLeast(0)
        Slider(
            value = value.toFloat(),
            onValueChange = { raw ->
                val snapped = setting.min + ((raw - setting.min) / setting.step).roundToInt() * setting.step
                onChange(snapped.coerceIn(setting.min, setting.max))
            },
            valueRange = setting.min.toFloat()..setting.max.toFloat(),
            steps = steps,
            enabled = enabled,
        )
        Text(text = stringResource(setting.hint), style = MaterialTheme.typography.bodySmall, color = Fg2)
        if (setting.key in WatchSettings.groupKeys) {
            EffectiveSize(setting.key, values)
        }
        if (value != setting.default) {
            BackToDefault(setting, enabled, onChange)
        }
    }
}

/**
 * The size the part actually has on the watch, when it differs from the control: the overall
 * size multiplies, and the watch stops at the limit (`Config.groupPct`).
 */
@Composable
private fun EffectiveSize(key: ConfigKey, values: Map<ConfigKey, Int>) {
    val own = values[key] ?: WatchSettings.of(key).default
    val hud = values[ConfigKey.HUD_PCT] ?: WatchSettings.of(ConfigKey.HUD_PCT).default
    val effective = WatchSettings.effectivePct(values, key)
    val raw = (hud * own + 50) / 100
    when {
        effective != raw -> Text(
            text = stringResource(R.string.settings_effective_capped, effective),
            style = MaterialTheme.typography.bodySmall,
            color = Amber,
        )
        effective != own -> Text(
            text = stringResource(R.string.settings_effective, effective, hud),
            style = MaterialTheme.typography.bodySmall,
            color = Fg2,
        )
    }
}

@Composable
private fun BackToDefault(setting: WatchSetting, enabled: Boolean, onChange: (Int) -> Unit) {
    Text(
        text = stringResource(R.string.settings_default, setting.format(LocalContext.current.resources, setting.default)),
        style = MaterialTheme.typography.bodySmall,
        color = Cyan,
        modifier = Modifier
            .clickable(enabled = enabled) { onChange(setting.default) }
            .padding(vertical = 4.dp),
    )
}

/** A watch 0/1 setting as a switch (C16): 1 on, 0 off. */
@Composable
private fun SwitchRow(
    setting: WatchSetting,
    value: Int,
    enabled: Boolean,
    onChange: (Int) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconLabel(
                icon = settingIcon(setting.key),
                text = stringResource(setting.label),
                style = MaterialTheme.typography.titleSmall,
                tint = Fg2,
                modifier = Modifier.weight(1f),
            )
            Switch(checked = value == 1, onCheckedChange = { onChange(if (it) 1 else 0) }, enabled = enabled)
        }
        Text(text = stringResource(setting.hint), style = MaterialTheme.typography.bodySmall, color = Fg2)
    }
}

/** The "Evitar vias expressas" (C16): the phone's, without `CONFIG`, like [DrillRow]. */
@Composable
private fun MotorwayRow(on: Boolean, onChange: (Boolean) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconLabel(
                icon = R.drawable.ic_highway,
                text = stringResource(R.string.settings_motorway),
                style = MaterialTheme.typography.titleSmall,
                tint = Fg2,
                modifier = Modifier.weight(1f),
            )
            Switch(checked = on, onCheckedChange = onChange)
        }
        Text(
            text = stringResource(R.string.settings_motorway_hint),
            style = MaterialTheme.typography.bodySmall,
            color = Fg2,
        )
    }
}

/** A watch setting with options, one per line and only one selected (the street levers, C16). */
@Composable
private fun RadioRow(
    setting: WatchSetting,
    value: Int,
    enabled: Boolean,
    onChange: (Int) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        IconLabel(
            icon = settingIcon(setting.key),
            text = stringResource(setting.label),
            style = MaterialTheme.typography.titleSmall,
            tint = Fg2,
        )
        Text(text = stringResource(setting.hint), style = MaterialTheme.typography.bodySmall, color = Fg2)
        for (option in setting.min..setting.max) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .selectable(selected = value == option, enabled = enabled, role = Role.RadioButton) {
                        onChange(option)
                    },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(selected = value == option, onClick = null, enabled = enabled)
                Text(setting.format(LocalContext.current.resources, option), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

/** The dead-app drill (C16): the phone's, without `CONFIG`, so it changes right away, with no send. */
@Composable
private fun DrillRow(armed: Boolean, onChange: (Boolean) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconLabel(
                icon = R.drawable.ic_bolt,
                text = stringResource(R.string.settings_drill),
                style = MaterialTheme.typography.titleSmall,
                tint = Fg2,
                modifier = Modifier.weight(1f),
            )
            Switch(checked = armed, onCheckedChange = onChange)
        }
        Text(
            text = stringResource(R.string.settings_drill_hint, (dev.igor.motonav.nav.KillDrill.AFTER_MS / 60_000).toInt()),
            style = MaterialTheme.typography.bodySmall,
            color = Fg2,
        )
    }
}

/**
 * How long the control waits stopped before sending on its own. A `CONFIG` send takes ~1 s over
 * BLE (one chunk); less than that and dragging the finger would become a queue of sends. A choice, not a
 * measurement.
 */
private const val AUTO_SEND_MS = 700L

/** Up to how many positions the control shows the dots for each step. */
private const val MAX_TICKS = 20

/** The watch preview's side: big enough to read the sign, without taking the screen. */
private val PREVIEW_SIZE = 200.dp

/** How long the preview holds the highlight after the last touch. A choice, not a measurement. */
private const val PREVIEW_HOLD_MS = 2500L
