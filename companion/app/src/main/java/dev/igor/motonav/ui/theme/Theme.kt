package dev.igor.motonav.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable

/** O tema do Bora? (folhas 2 e 3): sempre escuro, na tinta `#0B0F13`. */
@Composable
fun BoraTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = BoraColors, typography = BoraType, shapes = BoraShapes, content = content)
}
