package dev.igor.motonav.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.igor.motonav.R
import dev.igor.motonav.favorites.Favorite
import dev.igor.motonav.geo.Place
import dev.igor.motonav.ui.theme.Amber
import dev.igor.motonav.ui.theme.Card
import dev.igor.motonav.ui.theme.Cyan
import dev.igor.motonav.ui.theme.Fg
import dev.igor.motonav.ui.theme.Fg2
import dev.igor.motonav.ui.theme.Ink
import dev.igor.motonav.ui.theme.Off
import dev.igor.motonav.ui.theme.OnAmber
import dev.igor.motonav.ui.theme.OnCyan
import dev.igor.motonav.ui.theme.Outline
import dev.igor.motonav.ui.theme.Petrol
import dev.igor.motonav.ui.theme.PetrolMid
import dev.igor.motonav.ui.theme.Star
import dev.igor.motonav.ui.theme.Surface1

/** A destination in the Home "Recentes" list: the name, the newest trip's line and the place. */
data class HomeRecent(val name: String, val line: String, val place: Place)

/**
 * The Home tab (sheet 2, direction 3; `docs/design/telas.md` §5.3), top to bottom: the
 * header with the ring, what is missing, search, favorites and recents. The phone's
 * diagnostics (device, token, battery) live in the Watch tab.
 *
 * The order comes from Igor's use (2026-10-17): first check that the watch is on and the route
 * went, then search or share, and last favorites and trips.
 *
 * @param onSearch returns the places for a text (Photon, with Mapbox as fallback); throws
 *   [dev.igor.motonav.geo.GeocodeException] with the message for the person.
 */
@Composable
fun MainScreen(
    status: HomeStatus,
    favorites: List<Favorite>,
    recents: List<HomeRecent>,
    onSearch: suspend (String) -> List<Place>,
    onPickPlace: (Place) -> Unit,
    onPickFavorite: (Favorite) -> Unit,
    onEditFavorites: () -> Unit,
    onOpenTrips: () -> Unit,
    onAction: (HomeStatus.Action) -> Unit,
) {
    Surface(modifier = Modifier.fillMaxSize(), color = Ink) {
        Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Header(status)
            if (status.pending.isNotEmpty()) {
                PendingCard(status.pending, onAction)
            }
            Column(modifier = Modifier.padding(horizontal = 16.dp)) {
                SearchBlock(enabled = true, onSearch = onSearch, onPickPlace = onPickPlace)
                Row(
                    modifier = Modifier.padding(top = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(painterResource(R.drawable.ic_share), contentDescription = null, tint = Fg2, modifier = Modifier.size(18.dp))
                    Text(stringResource(R.string.home_share_hint), color = Fg2, fontSize = 13.sp)
                }

                SectionTitle(stringResource(R.string.action_favorites), stringResource(R.string.home_edit), onEditFavorites)
                FavoriteGrid(favorites, onPickFavorite, onEditFavorites)

                SectionTitle(stringResource(R.string.home_recents), stringResource(R.string.action_trips), onOpenTrips)
                if (recents.isEmpty()) {
                    Text(stringResource(R.string.home_recents_empty), style = MaterialTheme.typography.bodyMedium, color = Fg2)
                }
                recents.forEach { recent -> RecentRow(recent) { onPickPlace(recent.place) } }
                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

/** The home gradient passes behind the status bar: the brand, the ring and the two lines. */
@Composable
private fun Header(status: HomeStatus) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(Brush.verticalGradient(0f to Petrol, 0.6f to PetrolMid, 1f to Ink))
            .statusBarsPadding()
            .padding(start = 16.dp, end = 16.dp, top = 6.dp, bottom = 18.dp),
    ) {
        Image(
            painter = painterResource(R.drawable.ic_bora_marca),
            contentDescription = stringResource(R.string.app_name),
            modifier = Modifier.align(Alignment.CenterHorizontally).width(99.dp).height(30.dp),
        )
        Spacer(Modifier.height(16.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            StatusRing(status.ring, status.sign, status.title)
            Column {
                Text(status.title, style = MaterialTheme.typography.headlineSmall, color = Fg)
                Text(
                    status.detail,
                    style = MaterialTheme.typography.bodyMedium,
                    color = Fg2,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
    }
}

/** One line per pending item; amber only on what is up to you. */
@Composable
private fun PendingCard(pending: List<HomeStatus.Pending>, onAction: (HomeStatus.Action) -> Unit) {
    Surface(
        color = Surface1,
        shape = MaterialTheme.shapes.medium,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 16.dp),
    ) {
        Column {
            pending.forEachIndexed { index, item ->
                if (index > 0) {
                    HorizontalDivider(color = Outline)
                }
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Icon(
                        painterResource(iconOf(item.icon)),
                        contentDescription = null,
                        tint = if (item.yours) Amber else Off,
                        modifier = Modifier.size(20.dp),
                    )
                    Text(item.label, style = MaterialTheme.typography.bodyMedium, color = Fg, modifier = Modifier.weight(1f))
                    item.action?.let { action ->
                        val fill = if (item.yours) Amber else Cyan
                        val ink = if (item.yours) OnAmber else OnCyan
                        Box(
                            modifier = Modifier
                                .background(fill, MaterialTheme.shapes.small)
                                .clickable { onAction(action) }
                                .padding(horizontal = 12.dp, vertical = 6.dp),
                        ) {
                            Text(stringResource(action.label), color = ink, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            }
        }
    }
}

private fun iconOf(icon: HomeStatus.Icon): Int = when (icon) {
    HomeStatus.Icon.WATCH_OFF -> R.drawable.ic_watch_off
    HomeStatus.Icon.APPS -> R.drawable.ic_apps
    HomeStatus.Icon.BATTERY -> R.drawable.ic_battery_alert
    HomeStatus.Icon.TOKEN -> R.drawable.ic_route
}

@Composable
private fun SectionTitle(title: String, link: String, onLink: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 22.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium, color = Fg, modifier = Modifier.weight(1f))
        Text(
            link,
            color = Cyan,
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.clickable(onClick = onLink).padding(vertical = 4.dp, horizontal = 2.dp),
        )
    }
}

/**
 * Up to five favorites in three columns, and the dashed "+" tile that opens editing. The tiles are 48 dp
 * (they were 60 in 1.2.0: "os favoritos tão muito gordos", Igor, 2026-10-18), with the same text, and the
 * star is yellow.
 */
@Composable
private fun FavoriteGrid(favorites: List<Favorite>, onPick: (Favorite) -> Unit, onAdd: () -> Unit) {
    val tiles: List<Favorite?> = favorites.take(5) + listOf(null)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        tiles.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { favorite ->
                    val tile = Modifier.weight(1f).height(48.dp)
                    if (favorite == null) {
                        Box(
                            modifier = tile
                                .border(BorderStroke(1.dp, Outline), MaterialTheme.shapes.medium)
                                .clickable(onClick = onAdd),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                painterResource(R.drawable.ic_add),
                                contentDescription = stringResource(R.string.home_add_favorite),
                                tint = Fg2,
                            )
                        }
                    } else {
                        Row(
                            modifier = tile
                                .background(Card, MaterialTheme.shapes.medium)
                                .clickable { onPick(favorite) }
                                .padding(horizontal = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(painterResource(R.drawable.ic_star), contentDescription = null, tint = Star, modifier = Modifier.size(20.dp))
                            Text(
                                favorite.name,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium,
                                color = Fg,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
                repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

@Composable
private fun RecentRow(recent: HomeRecent, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier.size(40.dp).background(Card, MaterialTheme.shapes.small),
            contentAlignment = Alignment.Center,
        ) {
            Icon(painterResource(R.drawable.ic_schedule), contentDescription = null, tint = Fg, modifier = Modifier.size(22.dp))
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(recent.name, style = MaterialTheme.typography.bodyLarge, color = Fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (recent.line.isNotEmpty()) {
                Text(recent.line, style = MaterialTheme.typography.bodySmall, color = Fg2)
            }
        }
        Icon(painterResource(R.drawable.ic_near_me), contentDescription = null, tint = Cyan, modifier = Modifier.size(22.dp))
    }
}
