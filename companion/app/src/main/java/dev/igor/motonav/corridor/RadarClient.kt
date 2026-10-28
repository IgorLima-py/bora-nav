package dev.igor.motonav.corridor

import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.proto.PackableRoute
import dev.igor.motonav.proto.PointE5
import dev.igor.motonav.proto.Protocol
import dev.igor.motonav.proto.WireRadar
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** An OSM speed camera (`highway=speed_camera`), with the tags that [RadarFilter] reads. */
data class OsmCamera(val id: Long, val point: PointE5, val maxspeed: String?, val direction: String?)

/** A way that passes through a camera's node: gives the drawing direction and whether it is one-way. */
data class OsmCameraWay(val nodes: List<Long>, val points: List<PointE5>, val oneway: String?, val maxspeed: String?)

/** The result of the camera query: the nodes and the ways that pass through them. */
data class OsmRadars(val cameras: List<OsmCamera>, val ways: List<OsmCameraWay>)

/**
 * **The route's speed cameras, from OpenStreetMap** (C16.6, `06-APIS-DATA.md` §Radares), and the official ones that
 * are missing from it, from pardal ([PardalSource], C16.7b). Both are ODbL and the attribution is in `NOTICE`,
 * in the README and on the settings screen. MapaRadar never gets in (license, `docs/PUBLICAR.md`).
 *
 * One query per route, on the same polygon as the corridor ([CorridorBuilder.bufferPolygon]) and through the
 * same mirrors, with the same hedge ([OverpassClient.hedged]). Together come the ways that pass through the
 * camera's node (`way(bn)`), which give the one-way flag and the direction of `direction=forward|backward`.
 *
 * **An empty list is an answer, not a failure**, unlike the corridor's streets: a route with no camera
 * exists. The [OverpassClient.DEFAULT_ENDPOINTS] mirrors carry the whole planet (measured on
 * 2026-08-01), so an empty result from them is OSM with no camera there.
 */
class RadarClient(
    private val overpass: OverpassClient = OverpassClient(),
    /** Where the good response is kept for the route that goes out with Overpass down ([cached]). */
    private val store: RadarStore? = null,
    /** The official cameras missing from OSM; without it, the list is just OSM's. */
    private val pardal: PardalSource? = null,
) {

    private val json = Json { ignoreUnknownKeys = true }

    /** The route's cameras, ready for RADARS. A network failure propagates as [OverpassException]. */
    suspend fun fetch(route: PackableRoute): List<WireRadar> {
        // Before Overpass: with it down, the file downloaded here is what [cached] reads.
        val official = pardal?.cameras().orEmpty()
        val polygon = CorridorBuilder { emptyList() }.bufferPolygon(route, LocalPlane(route.lat0, route.lon0))
        val found = overpass.hedged(buildQuery(polygon), { parse(it) }) {
            "${it.cameras.size} radares e ${it.ways.size} vias"
        }
        store?.let { withContext(Dispatchers.IO) { it.merge(found) } }
        return logged(route, RadarFilter.judge(route, found, official), "osm")
    }

    /**
     * The route's cameras from what the phone already downloaded ([RadarStore]), without network. The [RadarFilter] is the
     * same as in the search: the distance to the track picks the ones that count, and the cache may hold the whole city.
     */
    suspend fun cached(route: PackableRoute): List<WireRadar> {
        val official = pardal?.cameras(network = false).orEmpty()
        val known = store?.let { withContext(Dispatchers.IO) { it.all() } } ?: OsmRadars(emptyList(), emptyList())
        if (known.cameras.isEmpty() && official.isEmpty()) {
            return emptyList()
        }
        return withContext(Dispatchers.IO) { logged(route, RadarFilter.judge(route, known, official), "cache") }
    }

    /**
     * **Every camera in the list goes to the log, with the OSM id** (C16.7): `tools/relatorio.py` cross-references these
     * lines with the track and with the watch's warning, which gives the camera's `d` ([radarLine]). Without the camera's
     * position you cannot tell what is missing from OSM from what the filter removed and from what the watch silenced.
     * The camera is public data and does not go through `EventLog.place`: the route already goes in the track of the same log.
     */
    private fun logged(route: PackableRoute, verdicts: List<RadarFilter.Verdict>, source: String): List<WireRadar> {
        val kept = verdicts.filter { it.reason == RadarFilter.Reason.KEPT }
        kept.forEachIndexed { i, v -> EventLog.i(TAG, radarLine(route.routeId, i, kept.size, v, source)) }
        val cut = verdicts.filter { it.reason != RadarFilter.Reason.KEPT }.groupingBy { it.reason }.eachCount()
        if (cut.isNotEmpty()) {
            EventLog.i(
                TAG,
                "radars cut route ${route.routeId} source $source: " +
                    RadarFilter.Reason.entries.filter { it in cut }.joinToString(", ") { "${it.label} ${cut[it]}" },
            )
        }
        return kept.map { it.radar!! }
    }

    companion object {
        private const val TAG = "RadarClient"

        /**
         * `radar <i>/<n> route <R> osm <id> d <distAlong> e5 <lat>,<lon> lim <km/h> bearing <deg> direction <fwd|?> source <osm|cache|pardal>`.
         * `RADAR_PHONE` in `tools/relatorio.py` reads this line; if it changes here, change it there. A pardal camera
         * goes with the negative key from [RadarFilter.pardalKey] in place of the OSM id.
         */
        fun radarLine(routeId: Int, index: Int, count: Int, v: RadarFilter.Verdict, source: String): String {
            val radar = v.radar!!
            val way = if (radar.flags and Protocol.RADAR_FLAG_DIRECTION != 0) "fwd" else "?"
            return "radar $index/$count route $routeId osm ${v.camera.id} d ${radar.distAlongM} " +
                "e5 ${v.camera.point.lat},${v.camera.point.lon} lim ${radar.limitKmh} bearing ${v.bearingDeg} " +
                "direction $way source ${if (v.source == RadarFilter.Source.PARDAL) "pardal" else source}"
        }
    }

    fun buildQuery(polygon: List<PointE5>): String = """
        [out:json][timeout:${OverpassClient.TIMEOUT_S}];
        node[highway=speed_camera](poly:"${OverpassClient.poly(polygon)}")->.cams;
        .cams out;
        way(bn.cams)[highway];
        out geom;
    """.trimIndent()

    fun parse(body: String): OsmRadars {
        val response = try {
            json.decodeFromString<Response>(body)
        } catch (e: Exception) {
            throw OverpassException("unreadable Overpass response: ${body.take(200)}", e)
        }
        val cameras = response.elements.filter { it.type == "node" && it.lat != null && it.lon != null }.map {
            OsmCamera(
                id = it.id,
                point = PointE5(OverpassClient.quantize(it.lat!!), OverpassClient.quantize(it.lon!!)),
                maxspeed = it.tags["maxspeed"],
                direction = it.tags["direction"],
            )
        }
        val ways = response.elements.filter {
            it.type == "way" && it.nodes.size >= 2 && it.geometry.size == it.nodes.size
        }.map { way ->
            OsmCameraWay(
                nodes = way.nodes,
                points = way.geometry.map { PointE5(OverpassClient.quantize(it.lat), OverpassClient.quantize(it.lon)) },
                oneway = way.tags["oneway"],
                maxspeed = way.tags["maxspeed"],
            )
        }
        return OsmRadars(cameras, ways)
    }

    @Serializable
    private data class Response(val elements: List<Element> = emptyList())

    @Serializable
    private data class Element(
        val type: String = "",
        val id: Long = 0,
        val lat: Double? = null,
        val lon: Double? = null,
        val tags: Map<String, String> = emptyMap(),
        val nodes: List<Long> = emptyList(),
        val geometry: List<Point> = emptyList(),
    )

    @Serializable
    private data class Point(val lat: Double = 0.0, val lon: Double = 0.0)
}
