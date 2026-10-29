package dev.igor.motonav.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import dev.igor.motonav.proto.ConfigKey
import dev.igor.motonav.settings.WatchSettings
import dev.igor.motonav.ui.theme.BoraTheme
import java.io.File
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The photo of "Ajustes do relógio" without an emulator: macOS does not run the `pato37` emulator, and a screenshot of the S25 is forbidden.
 * Only runs with `MOTONAV_TELAS=1` (the battery stays the same) and writes to `app/build/screens/`. The screen is tall
 * to fit the whole list in one photo; the width is the S25's (412 dp).
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w412dp-h2400dp-xxhdpi")
class SettingsScreenTest {

    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    /** As it opens: every group closed (2026-10-29). */
    @Test
    fun `photo of the settings screen`() = photo("settings", WatchSettings.defaults())

    /** Vibration on and the sizes at the limit, two groups open: the "back to default" and the limit warning show up. */
    @Test
    fun `photo of the adjusted settings screen`() = photo(
        "settings-adjusted",
        WatchSettings.defaults() + mapOf(
            ConfigKey.VIBE_ON to 1,
            ConfigKey.HUD_PCT to 112,
            ConfigKey.DIST_PCT to 110,
        ),
        open = listOf("Turn alerts", "Size on screen"),
    )

    /** The finger on "Distância da curva": the preview lights up the number and turns off the rest. */
    @Test
    fun `photo of the preview highlighting the distance`() = photo(
        "settings-highlight",
        WatchSettings.defaults() + (ConfigKey.DIST_PCT to 112),
        ConfigKey.DIST_PCT,
        open = listOf("Size on screen"),
    )

    /** All groups closed, with vibration and one size changed: the "off the default" badge shows up. */
    @Test
    fun `photo of the screen with the groups closed`() = photo(
        "settings-closed",
        WatchSettings.defaults() + mapOf(ConfigKey.VIBE_ON to 1, ConfigKey.DIST_PCT to 110),
    )

    private fun photo(
        name: String,
        values: Map<ConfigKey, Int>,
        active: ConfigKey? = null,
        open: List<String> = emptyList(),
    ) {
        assumeTrue(System.getenv("MOTONAV_TELAS") == "1")
        compose.setContent {
            BoraTheme {
                SettingsScreen(
                    initial = values,
                    onSend = { true },
                    onReset = { true },
                    onBack = {},
                    previewActive = active,
                )
            }
        }
        open.forEach { compose.onNodeWithText(it).performClick() }
        compose.waitForIdle()
        // `captureToImage` waits for a redraw that Robolectric does not deliver; drawing the window
        // to a bitmap gives the same photo.
        val view = compose.activity.window.decorView
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        val out = File("build/screens/$name.png").apply { parentFile?.mkdirs() }
        out.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
