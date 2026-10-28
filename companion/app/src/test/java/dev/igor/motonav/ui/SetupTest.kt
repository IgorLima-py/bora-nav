package dev.igor.motonav.ui

import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import dev.igor.motonav.link.LinkState
import dev.igor.motonav.link.SdkProblem
import dev.igor.motonav.link.WatchDevice
import dev.igor.motonav.ui.theme.BoraTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** First use (C16.8b): whoever installs from GitHub reaches the first route without help. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "en-w412dp-h915dp")
class SetupTest {

    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    /**
     * An invented token, the size of a real one. Without the JWT start of real tokens: the secrets scan
     * in `docs/PUBLICAR.md` looks for it.
     */
    private val fakeToken = "pk.TESTE-nao-e-um-token.0000000000000000000000000000000000"

    // prevents: any text pasted in place of the token, and the first route failing further on
    // with "Mapbox recusou o token" (the public APK carries no token, `docs/PUBLICAR.md`).
    @Test
    fun `only accepts a public Mapbox token`() {
        assertTrue(Setup.looksLikeToken(fakeToken))
        assertTrue(Setup.looksLikeToken("  $fakeToken\n"))
        assertFalse(Setup.looksLikeToken("sk.${fakeToken.drop(3)}"))
        assertFalse(Setup.looksLikeToken("pk.curto"))
        assertFalse(Setup.looksLikeToken("meu login do mapbox"))
    }

    // prevents: the ready screen saying "all set" with the token or the watch missing.
    @Test
    fun `the ready screen lists what is missing`() {
        val res = RuntimeEnvironment.getApplication().resources
        val link = LinkState(initializing = false, devices = listOf(WatchDevice(1, "Venu 4", connected = true)))
        assertEquals(emptyList<String>(), Setup.missing(res, true, true, true, true, link))
        assertEquals(
            listOf("Mapbox token", "Location", "Garmin Connect installed"),
            Setup.missing(res, false, false, true, true, LinkState(initializing = false, problem = SdkProblem.GCM_NOT_INSTALLED)),
        )
    }

    // prevents: the refusal of a wrong text staying on screen after the right token arrived through
    // `TokenReceiver` (the first-use e2e, job 1053, stopped on it).
    @Test
    fun `the token that arrives clears the refusal`() {
        var hasToken by mutableStateOf(false)
        compose.setContent {
            BoraTheme {
                SetupScreen(
                    hasToken = hasToken, onSaveToken = {},
                    location = false, onAllowLocation = {},
                    notifyNeeded = true, notify = false, onAllowNotify = {},
                    battery = false, onAllowBattery = {},
                    link = LinkState(initializing = false), onOpenGcm = {},
                    onTestConnection = { false }, onFinish = {},
                )
            }
        }
        compose.onNodeWithTag("setup_token").performTextInput("pk.curto")
        compose.onNodeWithText("Save token").performClick()
        compose.onNodeWithText("That doesn't look like a Mapbox public token: those start with pk.").assertExists()
        hasToken = true
        compose.onNodeWithText("Token saved.").assertExists()
    }

    // prevents: a step that traps whoever does not have everything at hand (first use has to reach the end by skipping).
    @Test
    fun `the four steps in English to the end`() {
        var saved: String? = null
        var finished = false
        compose.setContent {
            BoraTheme {
                SetupScreen(
                    hasToken = saved != null,
                    onSaveToken = { saved = it },
                    location = false, onAllowLocation = {},
                    notifyNeeded = true, notify = false, onAllowNotify = {},
                    battery = false, onAllowBattery = {},
                    link = LinkState(initializing = false),
                    onOpenGcm = {},
                    onTestConnection = { false },
                    onFinish = { finished = true },
                )
            }
        }
        compose.onNodeWithText("Step 1 of 4").assertExists()
        compose.onNodeWithText("Create a free Mapbox account").assertExists()
        compose.onNodeWithTag("setup_token").performTextInput("not a token")
        compose.onNodeWithText("Save token").performClick()
        compose.onNodeWithText("That doesn't look like a Mapbox public token: those start with pk.").assertExists()
        assertEquals(null, saved)

        compose.onNodeWithTag("setup_next").performClick()
        compose.onNodeWithText("Step 2 of 4").assertExists()
        compose.onNodeWithText("Location").assertExists()
        compose.onNodeWithText("Notifications").assertExists()
        compose.onNodeWithText("Unrestricted battery").assertExists()

        compose.onNodeWithTag("setup_next").performClick()
        compose.onNodeWithText("Step 3 of 4").assertExists()
        compose.onNodeWithText("Watch paired in Garmin Connect").assertExists()
        compose.onNodeWithTag("setup_test").performClick()
        compose.onNodeWithText("The watch didn't answer. Open Bora? on it and try again.").assertExists()

        compose.onNodeWithTag("setup_next").performClick()
        compose.onNodeWithText("Step 4 of 4").assertExists()
        compose.onNodeWithText(
            "Still missing: Mapbox token, Location, Notifications, Unrestricted battery, Watch paired in Garmin Connect. " +
                "You can sort it out later in the Watch tab.",
        ).assertExists()
        compose.onNodeWithTag("setup_finish").performClick()
        assertTrue(finished)
    }
}
