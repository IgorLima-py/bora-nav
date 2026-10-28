package dev.igor.motonav.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import dev.igor.motonav.geo.userMessage
import androidx.compose.ui.unit.dp
import dev.igor.motonav.R
import dev.igor.motonav.geo.Place
import dev.igor.motonav.ui.theme.Card
import dev.igor.motonav.ui.theme.Fg
import dev.igor.motonav.ui.theme.Fg2
import kotlinx.coroutines.delay

/**
 * Search with autocomplete (`docs/04 §1`): 300 ms after the last key it goes to Photon, with
 * Mapbox as fallback; tapping a result opens the confirmation, the same as the share's. In
 * sheet 2 it is the 56 dp "Para onde?" field on the `#1B2128` card.
 */
@Composable
internal fun SearchBlock(
    enabled: Boolean,
    onSearch: suspend (String) -> List<Place>,
    onPickPlace: (Place) -> Unit,
) {
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<Place>>(emptyList()) }
    var message by remember { mutableStateOf<String?>(null) }
    val res = LocalContext.current.resources

    LaunchedEffect(query) {
        message = null
        if (query.trim().length < MIN_QUERY) {
            results = emptyList()
            return@LaunchedEffect
        }
        delay(DEBOUNCE_MS)
        try {
            results = onSearch(query)
            if (results.isEmpty()) {
                message = res.getString(R.string.search_nothing, query.trim())
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            results = emptyList()
            message = res.getString(userMessage(e))
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TextField(
            value = query,
            onValueChange = { query = it },
            placeholder = { Text(stringResource(R.string.search_label), color = Fg2) },
            leadingIcon = {
                Icon(painterResource(R.drawable.ic_search), contentDescription = null, tint = Fg, modifier = Modifier.size(24.dp))
            },
            singleLine = true,
            enabled = enabled,
            shape = MaterialTheme.shapes.medium,
            colors = TextFieldDefaults.colors(
                focusedContainerColor = Card,
                unfocusedContainerColor = Card,
                disabledContainerColor = Card,
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent,
                disabledIndicatorColor = Color.Transparent,
            ),
            textStyle = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
        )
        if (!enabled) {
            Text(stringResource(R.string.search_needs_token), style = MaterialTheme.typography.bodySmall, color = Fg2)
        }
        message?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Fg2) }
        results.forEach { place ->
            Surface(
                color = MaterialTheme.colorScheme.surfaceContainer,
                shape = MaterialTheme.shapes.medium,
                modifier = Modifier.fillMaxWidth().clickable { onPickPlace(place) },
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Text(place.name, style = MaterialTheme.typography.bodyLarge)
                    if (place.address.isNotBlank() && place.address != place.name) {
                        Text(place.address, style = MaterialTheme.typography.bodyMedium, color = Fg2)
                    }
                }
            }
        }
    }
}

private const val MIN_QUERY = 3
private const val DEBOUNCE_MS = 300L
