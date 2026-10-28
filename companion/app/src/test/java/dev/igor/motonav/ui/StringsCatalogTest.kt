package dev.igor.motonav.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The phone's two catalogs (C16.8b), as `tools/idioma.py` does on the watch: English
 * (`values/`) and Portuguese (`values-pt/`) with the same keys and the same arguments, and no
 * Portuguese screen text written directly in Kotlin.
 */
class StringsCatalogTest {

    private val res = File("src/main/res")
    private val code = File("src/main/java/dev/igor/motonav")

    /** name -> the arguments (`%1$s`, `%d`...) of each text; plurals come in as `name#quantity`. */
    private fun catalog(dir: String): Map<String, List<String>> {
        val xml = File(res, "$dir/strings.xml").readText(Charsets.UTF_8)
        val out = mutableMapOf<String, List<String>>()
        Regex("""<string name="(\w+)"( translatable="false")?>(.*?)</string>""").findAll(xml).forEach {
            if (it.groupValues[2].isEmpty()) out[it.groupValues[1]] = args(it.groupValues[3])
        }
        Regex("""<plurals name="(\w+)">(.*?)</plurals>""", RegexOption.DOT_MATCHES_ALL).findAll(xml).forEach { p ->
            Regex("""<item quantity="(\w+)">(.*?)</item>""").findAll(p.groupValues[2]).forEach {
                out["${p.groupValues[1]}#${it.groupValues[1]}"] = args(it.groupValues[2])
            }
        }
        return out
    }

    private fun args(text: String) = Regex("""%(\d+\$)?[sdf]""").findAll(text).map { it.value }.sorted().toList()

    // prevents: a new key in only one language (the screen falls back to English in the middle of Portuguese, or the build breaks).
    @Test
    fun `both languages have the same keys and the same arguments`() {
        val en = catalog("values")
        val pt = catalog("values-pt")
        assertTrue("empty catalog", en.size > 200)
        assertEquals("keys in only one of the two", en.keys.sorted(), pt.keys.sorted())
        for ((key, enArgs) in en) {
            assertEquals("different arguments in $key", enArgs, pt[key])
        }
    }

    // prevents: a screen text in Portuguese written directly in Kotlin, which English would never translate
    // (there were ~200 before C16.8b). The log stays in Portuguese and is left out.
    @Test
    fun `no Portuguese screen text in the code`() {
        val accented = Regex(""""[^"\n]*[ãáéíóúâêôçõàÃÁÉÍÓÚÂÊÔÇÕ][^"\n]*"""")
        // The log and the technical message of exceptions stay in Portuguese; so does the log argument of `fail`.
        // A line that continues the one above (the text split in two) follows whatever the one above is.
        val logOrError = Regex("""EventLog\.|Log\.|log\(|Exception\(|check\(|require\(|error\(|stop\(|port\.log|fail\(|// log$|"[^"]*"\s*\+\s*$""")
        val screens = listOf("ui", "share", "settings").flatMap { File(code, it).walk().filter { f -> f.extension == "kt" }.toList() } +
            File(code, "MainActivity.kt")
        val found = mutableListOf<String>()
        for (file in screens) {
            var inComment = false
            var previous = ""
            file.readLines(Charsets.UTF_8).forEachIndexed { i, line ->
                val t = line.trim()
                if (t.startsWith("/*")) inComment = true
                val skip = inComment || t.startsWith("//") || t.startsWith("*") || logOrError.containsMatchIn(line) ||
                    logOrError.containsMatchIn(previous)
                previous = line
                if (t.contains("*/")) inComment = false
                if (!skip && accented.containsMatchIn(line)) found += "${file.name}:${i + 1}: $t"
            }
        }
        assertEquals("screen text outside strings.xml", emptyList<String>(), found)
    }
}
