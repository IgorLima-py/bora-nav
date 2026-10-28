package dev.igor.motonav.corridor

/**
 * **How each vector-tile schema states a road's class**, translated to the OSM `highway` of the
 * `04 §3.2` filter (C16). Whatever is not in the filter returns `null` and stays out of the map, as with
 * Overpass.
 */
object RoadSchemas {

    /** The classes the corridor wants, and that [CorridorBuilder.lodOf] knows how to put in an LOD. */
    private val WANTED = OverpassClient.HIGHWAY_FILTER.split('|').toSet()

    private fun wanted(highway: String?): String? = highway?.takeIf { it in WANTED }

    private fun linkOf(kind: String, link: Boolean): String = if (link && !kind.endsWith("_link")) "${kind}_link" else kind

    private fun truthy(value: Any?): Boolean = when (value) {
        is Boolean -> value
        is Number -> value.toLong() != 0L
        is String -> value == "1" || value == "true" || value == "yes"
        else -> false
    }

    /**
     * OpenMapTiles (OpenFreeMap's), layer `transportation`: `class` with `minor` for the neighborhood
     * streets (OSM's residential, unclassified, living_street and road together) and `ramp = 1` on
     * the ramps.
     */
    val OPENMAPTILES = TileRoadSource.Schema("OpenMapTiles", "transportation", setOf("class", "ramp")) { p ->
        when (val cls = p["class"] as? String) {
            "minor" -> "residential"
            null -> null
            else -> wanted(linkOf(cls, truthy(p["ramp"])))
        }
    }

    /** Shortbread (VersaTiles'), layer `streets`: `kind` is the OSM `highway`, and `link` marks the ramps. */
    val SHORTBREAD = TileRoadSource.Schema("Shortbread", "streets", setOf("kind", "link")) { p ->
        (p["kind"] as? String)?.let { wanted(linkOf(it, truthy(p["link"]))) }
    }

    /** Protomaps basemap, layer `roads`: `kind_detail` is the OSM `highway`, and `is_link` marks the ramps. */
    val PROTOMAPS = TileRoadSource.Schema("Protomaps", "roads", setOf("kind_detail", "is_link")) { p ->
        (p["kind_detail"] as? String)?.let { wanted(linkOf(it, truthy(p["is_link"]))) }
    }
}
