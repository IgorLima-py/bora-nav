package dev.igor.motonav.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.igor.motonav.R
import dev.igor.motonav.favorites.Favorite
import dev.igor.motonav.favorites.FavoritesStore
import dev.igor.motonav.geo.Place

/**
 * Favorites (C12, `04 §Favoritos`): the list the watch shows, edited here.
 * Each change goes to the watch right away (`FAVORITES` carries the whole list).
 *
 * The seeds "Casa", "Academia" and "Escritório" appear without an address: Igor
 * fills them in on first run, and a favorite without an address **does not go** to the watch.
 *
 * @param status the line of the last send to the watch, or `null`.
 * @param onSearch the address search (Photon, with Mapbox as fallback), the same as the main screen's.
 */
@Composable
fun FavoritesScreen(
    favorites: List<Favorite>,
    hasToken: Boolean,
    status: String?,
    onSearch: suspend (String) -> List<Place>,
    onSave: (Favorite) -> Unit,
    onDelete: (Int) -> Unit,
    onBack: () -> Unit,
) {
    var editing by remember { mutableStateOf<Favorite?>(null) }

    Surface(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(stringResource(R.string.action_favorites), style = MaterialTheme.typography.headlineMedium)
                TextButton(onClick = onBack) { Text(stringResource(R.string.settings_back)) }
            }
            Text(
                stringResource(R.string.fav_intro),
                style = MaterialTheme.typography.bodySmall,
            )
            status?.let { Text(it, style = MaterialTheme.typography.bodySmall) }

            val current = editing
            if (current != null) {
                Editor(
                    favorite = current,
                    hasToken = hasToken,
                    onSearch = onSearch,
                    onSave = {
                        onSave(it)
                        editing = null
                    },
                    onDelete = {
                        onDelete(current.id)
                        editing = null
                    },
                    onCancel = { editing = null },
                )
            } else {
                favorites.forEach { favorite ->
                    FavoriteRow(favorite, onClick = { editing = favorite })
                }
                if (favorites.size < FavoritesStore.MAX) {
                    Button(
                        onClick = { editing = Favorite(id = 0, name = "") },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(stringResource(R.string.home_add_favorite))
                    }
                } else {
                    Text(stringResource(R.string.fav_max), style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}

@Composable
private fun FavoriteRow(favorite: Favorite, onClick: () -> Unit) {
    Card(modifier = Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(favorite.name, style = MaterialTheme.typography.titleMedium)
            val detail = when {
                !favorite.hasPlace -> stringResource(R.string.fav_no_place)
                favorite.address.isNullOrBlank() -> stringResource(R.string.fav_place_saved)
                else -> favorite.address
            }
            Text(detail, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun Editor(
    favorite: Favorite,
    hasToken: Boolean,
    onSearch: suspend (String) -> List<Place>,
    onSave: (Favorite) -> Unit,
    onDelete: () -> Unit,
    onCancel: () -> Unit,
) {
    var name by remember { mutableStateOf(favorite.name) }
    var lat by remember { mutableStateOf(favorite.lat) }
    var lon by remember { mutableStateOf(favorite.lon) }
    var address by remember { mutableStateOf(favorite.address) }
    val hasPlace = lat != null && lon != null

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedTextField(
            value = name,
            onValueChange = { name = it.take(MAX_NAME_CHARS) },
            label = { Text(stringResource(R.string.fav_name)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            text = if (hasPlace) {
                stringResource(R.string.fav_address, address ?: stringResource(R.string.fav_address_saved))
            } else {
                stringResource(R.string.fav_search_below)
            },
            style = MaterialTheme.typography.bodyMedium,
        )
        SearchBlock(
            enabled = hasToken,
            onSearch = onSearch,
            onPickPlace = { place ->
                lat = place.position.lat
                lon = place.position.lon
                address = place.address.ifBlank { place.name }
                if (name.isBlank()) {
                    name = place.name.take(MAX_NAME_CHARS)
                }
            },
        )
        Button(
            onClick = { onSave(favorite.copy(name = name.trim(), lat = lat, lon = lon, address = address)) },
            enabled = name.isNotBlank() && hasPlace,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(stringResource(R.string.fav_save))
        }
        if (favorite.id != 0) {
            OutlinedButton(onClick = onDelete, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.fav_delete)) }
        }
        TextButton(onClick = onCancel) { Text(stringResource(R.string.fav_cancel)) }
    }
}

/** Over 20 B on the watch it gets cut (05 §FAVORITES); 20 characters avoids the cut for most names. */
private const val MAX_NAME_CHARS = 20
