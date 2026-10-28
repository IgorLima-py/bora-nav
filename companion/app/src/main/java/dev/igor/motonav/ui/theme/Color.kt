package dev.igor.motonav.ui.theme

import androidx.compose.material3.darkColorScheme
import androidx.compose.ui.graphics.Color

// The Bora? tokens on the phone (sheets 2 and 3, docs/design/telas.md §2). Each color has a role:
// cyan is standing and forward; amber is up to you; gray is stopped or gone; petrol is home.

val Cyan = Color(0xFF2FD3FF)
val CyanTrack = Color(0xFF0B5A73)
val Amber = Color(0xFFFFB300)

/** The favorites star (Igor, 2026-10-18), the same yellow as the watch's `DesignTokens.STAR`. */
val Star = Color(0xFFFFB300)
val OnAmber = Color(0xFF261A00)
val RingOff = Color(0xFF3A4550)
val Fg = Color(0xFFE8EEF2)
val Fg2 = Color(0xFF9AA6B0)
val Off = Color(0xFF6A7380)
val Petrol = Color(0xFF0F3442)
val PetrolMid = Color(0xFF071A21)
val OnPrimaryContainer = Color(0xFFCFF3FF)
val PrimaryContainer = Color(0xFF0E3A47)
val OnCyan = Color(0xFF00323F)
val Ink = Color(0xFF0B0F13)
val Surface1 = Color(0xFF12181E)
val Card = Color(0xFF1B2128)
val Outline = Color(0xFF2C353E)

val BoraColors = darkColorScheme(
    primary = Cyan,
    onPrimary = OnCyan,
    primaryContainer = PrimaryContainer,
    onPrimaryContainer = OnPrimaryContainer,
    secondary = Cyan,
    onSecondary = OnCyan,
    tertiary = Amber,
    onTertiary = OnAmber,
    error = Amber,
    onError = OnAmber,
    background = Ink,
    onBackground = Fg,
    surface = Ink,
    onSurface = Fg,
    surfaceVariant = Card,
    onSurfaceVariant = Fg2,
    surfaceContainerLowest = Ink,
    surfaceContainerLow = Surface1,
    surfaceContainer = Surface1,
    surfaceContainerHigh = Card,
    surfaceContainerHighest = Card,
    outline = Outline,
    outlineVariant = Outline,
)
