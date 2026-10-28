package dev.igor.motonav.demo

import dev.igor.motonav.corridor.CorridorBuilder
import dev.igor.motonav.corridor.LocalPlane
import dev.igor.motonav.corridor.OverpassClient
import dev.igor.motonav.corridor.RadarClient
import dev.igor.motonav.corridor.RadarFilter
import dev.igor.motonav.proto.PackableCorridor
import dev.igor.motonav.proto.Protocol
import dev.igor.motonav.proto.ProtocolPacker
import dev.igor.motonav.route.MapboxRouteParser
import java.io.File
import java.util.Base64
import kotlin.math.abs
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * real São Paulo for the simulator (C2b of `docs/ROADMAP.md`).
 *
 * Runs the phone's **real** pipeline over the SP fixture — `MapboxRouteParser`,
 * `OverpassClient.parse`, `CorridorBuilder.assemble` + `capped` (the same pair that
 * `build()` uses), `ProtocolPacker.buildRouteBlocks` — and writes each BLE message
 * as a watch string resource, in Base64, exactly as
 * `WatchLink.wire` puts it on the air. The demo build's `DemoFeed` (`watch/demo.jungle`)
 * injects one per second into `onPhoneData`, and `tools/sim.py demo` judges.
 *
 * Why Kotlin and not `packer.py`: the distance-to-route cut
 * (`fitToCaps`) was born here, and the watch has to receive what the phone sends,
 * not what a mirror thinks it sends. `preview_map.py` checks the same
 * corridor per LOD, with the tolerance below.
 *
 * **Only the `tiete_copan` fixture becomes a resource**: a demo resource ends up in git,
 * so the route starts from a public place (Parque Ecológico do Tietê).
 */
class DemoFramesTest {

    private val repo = File("../..")
    private val fixtures = File(repo, "tools/fixtures")
    private val demo = File(repo, "watch/demo")

    private fun frames(): Frames {
        val route = MapboxRouteParser
            .parse(File(fixtures, "route_tiete_copan.json").readText(Charsets.UTF_8), DEST_NAME)
            .toPackable(routeId = ROUTE_ID)
        val ways = OverpassClient().parse(File(fixtures, "corridor_tiete_copan.json").readText(Charsets.UTF_8))
        val assembled = CorridorBuilder { emptyList() }.assemble(ways, route, LocalPlane(route.lat0, route.lon0))
        val (corridor, dropped) = assembled.capped(route.lat0, route.lon0)
        // C16.6: the route's cameras, from the recorded Overpass, through the app's same filter, after the corridor.
        val osm = RadarClient().parse(File(fixtures, "overpass_radars_tiete_copan.json").readText(Charsets.UTF_8))
        val radars = RadarFilter.filter(route, osm)
        val blocks = ProtocolPacker.buildRouteBlocks(route, Protocol.CHUNK_SIZE, corridor) +
            ProtocolPacker.buildRadarsBlock(route.routeId, radars)
        val messages = blocks.flatMap { block -> block.chunks.map { block.msgType to it } }
        return Frames(corridor, dropped, messages)
    }

    private class Frames(
        val corridor: PackableCorridor,
        val dropped: List<String>,
        val messages: List<Pair<Int, ByteArray>>,
    )

    @Test
    fun `the SP corridor reaches the watch with all four LODs`() {
        val frames = frames()
        assertTrue("capped() dropped LODs: ${frames.dropped}", frames.dropped.isEmpty())
        assertEquals(listOf(0, 1, 2, 3), frames.corridor.nonEmptyLods())
    }

    @Test
    fun `ways per LOD match the python mirror`() {
        val reference = Json.parseToJsonElement(
            File(fixtures, "preview/tiete_copan_lods.json").readText(Charsets.UTF_8),
        ).jsonObject
        val corridor = frames().corridor
        compare("ways", corridor.ways.map { it.size }, reference.getValue("ways_per_lod").jsonArray.map { it.jsonPrimitive.int })
        compare("points", corridor.ways.map { lod -> lod.sumOf { it.size } }, reference.getValue("points_per_lod").jsonArray.map { it.jsonPrimitive.int })
    }

    private fun compare(what: String, actual: List<Int>, expected: List<Int>) {
        println("$what per LOD: kotlin $actual · python $expected · tolerance $LOD_TOLERANCE")
        for (lod in 0 until Protocol.CORRIDOR_LOD_COUNT) {
            val diff = abs(actual[lod] - expected[lod])
            assertTrue(
                "$what at LOD $lod: kotlin ${actual[lod]} × python ${expected[lod]} (difference $diff > $LOD_TOLERANCE)",
                diff <= LOD_TOLERANCE,
            )
        }
    }

    /**
     * Writes the resources and checks that generating again gives the same text: a demo
     * resource that changes by itself between two rounds becomes a git diff with nobody
     * having touched anything.
     */
    @Test
    fun `writes one Base64 string resource per BLE message`() {
        val frames = frames()
        val xml = resourcesXml(frames)
        val mc = framesMc(frames)
        assertEquals(xml, resourcesXml(frames()))

        File(demo, "resources/strings").mkdirs()
        File(demo, "source").mkdirs()
        File(demo, "resources/strings/demo_frames.xml").writeText(xml, Charsets.UTF_8)
        File(demo, "source/DemoFrames.mc").writeText(mc, Charsets.UTF_8)

        val byType = frames.messages.groupingBy { it.first }.eachCount().toSortedMap()
        println("demo: ${frames.messages.size} messages $byType → ${demo.canonicalPath}")
        assertTrue(frames.messages.all { it.second.size <= Protocol.CHUNK_SIZE })
    }

    private fun resourcesXml(frames: Frames): String = buildString {
        append("<!-- $STAMP -->\n<strings>\n")
        frames.messages.forEachIndexed { i, (_, bytes) ->
            append("    <string id=\"${id(i)}\">")
            append(Base64.getEncoder().encodeToString(bytes))
            append("</string>\n")
        }
        append("</strings>\n")
    }

    private fun framesMc(frames: Frames): String = buildString {
        val byType = frames.messages.groupingBy { it.first }.eachCount().toSortedMap()
        append("// $STAMP\n")
        append("// Fixture tiete_copan, routeId $ROUTE_ID: ${frames.messages.size} messages by type $byType;\n")
        append("// ways per LOD ${frames.corridor.ways.map { it.size }}, ${frames.corridor.segmentCount()} segments.\n")
        append("import Toybox.Lang;\n\n")
        append("module DemoFrames {\n\n")
        append("    const ROUTE_ID = $ROUTE_ID;\n")
        append("    const LOD_COUNT = ${frames.corridor.nonEmptyLods().size};\n\n")
        append("    //! The messages in BLE order (META, POLY, TURNS, CORRIDOR per LOD, RADARS).\n")
        append("    function all() as Array<ResourceId> {\n        return [\n")
        frames.messages.indices.forEach { append("            Rez.Strings.${id(it)},\n") }
        append("        ] as Array<ResourceId>;\n    }\n}\n")
    }

    private fun id(i: Int) = "demo_%03d".format(i)

    private companion object {
        const val ROUTE_ID = 42
        const val DEST_NAME = "Copan"
        // No "--": XML forbids two hyphens inside a comment, and monkeyc
        // rejects the whole resource.
        const val STAMP = "GENERATED by DemoFramesTest (companion), do not edit; regenerate with " +
            "gradlew testDebugUnitTest, filter *DemoFramesTest*"

        /**
         * Accepted difference between Kotlin and `preview_map.py`, per LOD, in ways and
         * in points. **Zero, measured:** on 2026-09-29 both gave exactly
         * [454, 596, 112, 399] ways and [1378, 1490, 270, 1023] points. Both
         * quantize to integers (1e-5 degree) before any math, so there is no
         * floating-point noise to absorb; a difference here is a rule that
         * diverged between the mirrors, and slack would only hide it.
         */
        const val LOD_TOLERANCE = 0
    }
}
