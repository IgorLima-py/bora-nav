package dev.igor.motonav.ui

import android.content.res.Resources
import java.util.Locale

/**
 * The language of the texts these resources resolve (C16.8b). The numbers ("11,4 km" and "11.4 km") and the
 * dates follow the same language as the words, not `Locale.getDefault()`: with Android 13's
 * per-app language, the two can differ.
 */
fun Resources.locale(): Locale = configuration.locales[0] ?: Locale.getDefault()
