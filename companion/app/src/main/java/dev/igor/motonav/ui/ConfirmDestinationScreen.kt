package dev.igor.motonav.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.igor.motonav.BuildConfig
import dev.igor.motonav.R
import dev.igor.motonav.ui.theme.Fg
import dev.igor.motonav.ui.theme.Fg2
import dev.igor.motonav.ui.theme.Ink

/**
 * RF-01's one-tap screen (`docs/04 §1`): where to, where the
 * estimate came from (approximate address and straight-line distance) and **Bora**.
 *
 * No map: speed is everything. The distance is there so the person notices a link
 * that landed in the wrong place before spending the Mapbox request. The texts
 * are those of sheet 3 (`docs/design/telas.md` §5.6): "Ride to %1$s?", "Let's go" and
 * "Not now".
 */
@Composable
fun ConfirmDestinationScreen(
    label: String,
    address: String?,
    distanceKm: Int?,
    onStart: () -> Unit,
    onCancel: () -> Unit,
) {
    Surface(modifier = Modifier.fillMaxSize(), color = Ink) {
        Column(
            modifier = Modifier.fillMaxSize().systemBarsPadding().padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Image(
                painter = painterResource(R.drawable.ic_bora_marca),
                contentDescription = stringResource(R.string.app_name),
                modifier = Modifier.width(99.dp).height(30.dp),
            )
            Text(
                text = stringResource(R.string.app_version, BuildConfig.VERSION_NAME),
                style = MaterialTheme.typography.bodySmall,
                color = Fg2,
            )
            Spacer(Modifier.height(16.dp))
            Text(stringResource(R.string.confirm_title, label), style = MaterialTheme.typography.headlineSmall, color = Fg)
            if (!address.isNullOrBlank() && !address.startsWith(label)) {
                Text(address, style = MaterialTheme.typography.bodyLarge, color = Fg2)
            }
            if (distanceKm != null) {
                Text(
                    text = stringResource(R.string.confirm_distance, distanceKm),
                    style = MaterialTheme.typography.bodyMedium,
                    color = Fg2,
                )
            }
            Column(
                modifier = Modifier.weight(1f).fillMaxWidth(),
                verticalArrangement = Arrangement.Bottom,
            ) {
                Button(
                    onClick = onStart,
                    shape = MaterialTheme.shapes.medium,
                    modifier = Modifier.fillMaxWidth().height(64.dp),
                ) {
                    Text(stringResource(R.string.confirm_start), style = MaterialTheme.typography.titleLarge)
                }
                Spacer(Modifier.height(8.dp))
                TextButton(
                    onClick = onCancel,
                    modifier = Modifier.fillMaxWidth().height(52.dp),
                ) {
                    Text(stringResource(R.string.confirm_cancel))
                }
            }
        }
    }
}
