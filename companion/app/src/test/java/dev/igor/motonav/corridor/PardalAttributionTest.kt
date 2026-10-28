package dev.igor.motonav.corridor

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pardal's attribution (C16.7b): its ODbL asks to "citar as fontes" (cite the sources) (pardal README, §Licença), and
 * CET-SP, where almost all the cameras it puts on Igor's routes come from, is `cc-by`.
 */
class PardalAttributionTest {

    // prevents: the pardal and its sources only in `NOTICE`, with the settings screen and the README without CET,
    // and `PUBLICAR.md` ticking `[x]` something the screen did not have (C16.7b second opinion, 2026-10-28).
    @Test
    fun theScreenTheNoticeAndTheReadmeNameThePardalAndTheCet() {
        // C16.8b: the English screen (`values/`) and the Portuguese one (`values-pt/`) cite the same sources.
        fun screen(dir: String) = Regex("""<string name="osm_attribution">(.*)</string>""")
            .find(File("src/main/res/$dir/strings.xml").readText(Charsets.UTF_8))!!.groupValues[1]
        val places = mapOf(
            "settings screen in English" to screen("values"),
            "settings screen in Portuguese" to screen("values-pt"),
            "NOTICE" to File("../../NOTICE").readText(Charsets.UTF_8),
            "README" to File("../../README.md").readText(Charsets.UTF_8).substringAfter("## License and third-party data"),
        )
        for ((where, text) in places) {
            for (needed in listOf("OpenStreetMap", "pardal", "CET-SP", "CC BY", "DER-SP", "ANTT", "DNIT")) {
                assertTrue("$where without «$needed»: $text", needed in text)
            }
        }
    }
}
