package dev.igor.motonav.corridor

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.zip.GZIPInputStream

/**
 * **Mapbox Vector Tile (MVT 2.1) reader, only what the corridor uses:** the lines of a layer and their
 * properties (C16).
 *
 * Written by hand from the spec's `vector_tile.proto` (github.com/mapbox/vector-tile-spec,
 * version 2.1), with no protobuf or JTS: the tile has four messages and half a dozen fields, and
 * the JVM MVT libraries pull in JTS's whole geometry stack just to return a polyline. The why and
 * the survey of the libraries are in `DECISIONS.md` §2026-10-17, "the street source".
 *
 * Points and polygons are skipped; only `LINESTRING` comes out of here. A feature with several `MoveTo`
 * (multiline) becomes several [Line].
 */
object MvtReader {

    /** One line of a feature, in tile coordinates (0..[extent], y grows downward). */
    class Line(val properties: Map<String, Any>, val xs: IntArray, val ys: IntArray, val extent: Int)

    /**
     * The lines of layer [layerName] in [bytes] (the raw tile or gzipped: some servers send
     * the `.pbf` compressed without the `Content-Encoding`). Only the properties in [keys] are read.
     * A gzip that expands past [MAX_TILE_BYTES] is refused ([readCapped]).
     */
    fun lines(bytes: ByteArray, layerName: String, keys: Set<String>): List<Line> {
        val raw = if (isGzip(bytes)) {
            GZIPInputStream(ByteArrayInputStream(bytes)).use { readCapped(it, MAX_TILE_BYTES) }
                ?: throw IllegalArgumentException("gzip tile over ${MAX_TILE_BYTES / MB} MB uncompressed")
        } else {
            bytes
        }
        val tile = Pb(raw, 0, raw.size)
        val out = mutableListOf<Line>()
        while (tile.hasMore()) {
            val tag = tile.varint().toInt()
            if (tag == LAYERS_TAG) {
                val layer = tile.message()
                readLayer(layer, layerName, keys, out)
            } else {
                tile.skip(tag)
            }
        }
        return out
    }

    private fun readLayer(layer: Pb, layerName: String, keys: Set<String>, out: MutableList<Line>) {
        // Fields may come in any order: keep the features and resolve at the end.
        var name = ""
        var extent = DEFAULT_EXTENT
        val layerKeys = mutableListOf<String>()
        val values = mutableListOf<Any>()
        val features = mutableListOf<Pb>()
        while (layer.hasMore()) {
            val tag = layer.varint().toInt()
            when (tag) {
                (1 shl 3) or WIRE_LEN -> name = layer.string()
                (2 shl 3) or WIRE_LEN -> features.add(layer.message())
                (3 shl 3) or WIRE_LEN -> layerKeys.add(layer.string())
                (4 shl 3) or WIRE_LEN -> values.add(readValue(layer.message()))
                (5 shl 3) or WIRE_VARINT -> extent = layer.varint().toInt()
                else -> layer.skip(tag)
            }
            if (name.isNotEmpty() && name != layerName) {
                return
            }
        }
        if (name != layerName) {
            return
        }
        for (feature in features) {
            readFeature(feature, layerKeys, values, keys, extent, out)
        }
    }

    private fun readFeature(
        feature: Pb,
        layerKeys: List<String>,
        values: List<Any>,
        keys: Set<String>,
        extent: Int,
        out: MutableList<Line>,
    ) {
        var type = 0
        var tags: Pb? = null
        var geometry: Pb? = null
        while (feature.hasMore()) {
            val tag = feature.varint().toInt()
            when (tag) {
                (2 shl 3) or WIRE_LEN -> tags = feature.message()
                (3 shl 3) or WIRE_VARINT -> type = feature.varint().toInt()
                (4 shl 3) or WIRE_LEN -> geometry = feature.message()
                else -> feature.skip(tag)
            }
        }
        if (type != GEOM_LINESTRING || geometry == null) {
            return
        }
        val properties = HashMap<String, Any>()
        if (tags != null) {
            while (tags.hasMore()) {
                val key = layerKeys.getOrNull(tags.varint().toInt())
                val value = values.getOrNull(tags.varint().toInt())
                if (key != null && value != null && key in keys) {
                    properties[key] = value
                }
            }
        }
        readLines(geometry, properties, extent, out)
    }

    /** The geometry commands (spec §4.3): `MoveTo` opens a line, `LineTo` extends it. */
    private fun readLines(geometry: Pb, properties: Map<String, Any>, extent: Int, out: MutableList<Line>) {
        var x = 0
        var y = 0
        val xs = IntList()
        val ys = IntList()
        fun flush() {
            if (xs.size >= 2) {
                out.add(Line(properties, xs.toArray(), ys.toArray(), extent))
            }
            xs.clear()
            ys.clear()
        }
        while (geometry.hasMore()) {
            val command = geometry.varint().toInt()
            val id = command and 0x7
            val count = command ushr 3
            when (id) {
                CMD_MOVE_TO, CMD_LINE_TO -> {
                    if (id == CMD_MOVE_TO) {
                        flush()
                    }
                    repeat(count) {
                        x += zigzag(geometry.varint().toInt())
                        y += zigzag(geometry.varint().toInt())
                        xs.add(x)
                        ys.add(y)
                    }
                }
                CMD_CLOSE_PATH -> Unit
                else -> throw IllegalArgumentException("invalid geometry command $id in MVT")
            }
        }
        flush()
    }

    private fun readValue(value: Pb): Any {
        var result: Any = ""
        while (value.hasMore()) {
            val tag = value.varint().toInt()
            result = when (tag) {
                (1 shl 3) or WIRE_LEN -> value.string()
                (2 shl 3) or WIRE_I32 -> java.lang.Float.intBitsToFloat(value.fixed32())
                (3 shl 3) or WIRE_I64 -> java.lang.Double.longBitsToDouble(value.fixed64())
                (4 shl 3) or WIRE_VARINT -> value.varint()
                (5 shl 3) or WIRE_VARINT -> value.varint()
                (6 shl 3) or WIRE_VARINT -> value.varint().let { (it ushr 1) xor -(it and 1) }
                (7 shl 3) or WIRE_VARINT -> value.varint() != 0L
                else -> {
                    value.skip(tag)
                    result
                }
            }
        }
        return result
    }

    /**
     * Everything from [input], in blocks, or `null` if it exceeds [limit] bytes. Without the cap, a gzip bomb
     * (a few KB that expand to gigabytes) becomes `OutOfMemoryError`, which is an `Error` and slips past every
     * `catch (e: Exception)` on the path to the corridor: the companion crashed mid-navigation.
     */
    fun readCapped(input: InputStream, limit: Int): ByteArray? {
        val out = ByteArrayOutputStream()
        val chunk = ByteArray(64 * 1024)
        while (true) {
            val n = input.read(chunk)
            if (n < 0) {
                return out.toByteArray()
            }
            if (out.size() + n > limit) {
                return null
            }
            out.write(chunk, 0, n)
        }
    }

    private fun zigzag(n: Int): Int = (n ushr 1) xor -(n and 1)

    private fun isGzip(bytes: ByteArray): Boolean =
        bytes.size >= 2 && bytes[0] == 0x1f.toByte() && bytes[1] == 0x8b.toByte()

    /** A protobuf slice: sequential reading from `pos` to `end`. */
    private class Pb(private val buf: ByteArray, private var pos: Int, private val end: Int) {
        fun hasMore(): Boolean = pos < end

        fun varint(): Long {
            var result = 0L
            var shift = 0
            while (true) {
                require(pos < end) { "truncated varint in MVT" }
                val b = buf[pos++].toInt()
                result = result or ((b and 0x7f).toLong() shl shift)
                if (b and 0x80 == 0) {
                    return result
                }
                shift += 7
                require(shift < 64) { "varint too long in MVT" }
            }
        }

        fun message(): Pb {
            val length = varint().toInt()
            require(length in 0..(end - pos)) { "message of $length bytes runs past the end of the MVT" }
            val sub = Pb(buf, pos, pos + length)
            pos += length
            return sub
        }

        fun string(): String {
            val length = varint().toInt()
            require(length in 0..(end - pos)) { "string of $length bytes runs past the end of the MVT" }
            val text = String(buf, pos, length, Charsets.UTF_8)
            pos += length
            return text
        }

        fun fixed32(): Int {
            require(end - pos >= 4) { "truncated fixed32 in MVT" }
            var v = 0
            for (i in 0 until 4) v = v or ((buf[pos + i].toInt() and 0xff) shl (8 * i))
            pos += 4
            return v
        }

        fun fixed64(): Long {
            require(end - pos >= 8) { "truncated fixed64 in MVT" }
            var v = 0L
            for (i in 0 until 8) v = v or ((buf[pos + i].toLong() and 0xff) shl (8 * i))
            pos += 8
            return v
        }

        fun skip(tag: Int) {
            when (tag and 0x7) {
                WIRE_VARINT -> varint()
                WIRE_I64 -> advance(8)
                WIRE_LEN -> advance(varint().toInt())
                WIRE_I32 -> advance(4)
                else -> throw IllegalArgumentException("invalid field type ${tag and 0x7} in MVT")
            }
        }

        private fun advance(n: Int) {
            require(n in 0..(end - pos)) { "field of $n bytes runs past the end of the MVT" }
            pos += n
        }
    }

    /** A growing `IntArray`, so the geometry does not become a list of `Integer`. */
    private class IntList {
        private var data = IntArray(64)
        var size = 0
            private set

        fun add(v: Int) {
            if (size == data.size) data = data.copyOf(size * 2)
            data[size++] = v
        }

        fun clear() {
            size = 0
        }

        fun toArray(): IntArray = data.copyOf(size)
    }

    const val DEFAULT_EXTENT = 4096

    /**
     * A tile's cap, on the downloaded body and on the expanded gzip. The largest VersaTiles z14 tile measured
     * is 711 KB expanded (central SP; Manhattan and Paris sit between 610 and 650 KB), so 4 MB gives
     * more than five times the headroom. With 16 tiles downloading at once, a hostile server reaches
     * ~64 MB, not the whole heap. The measurement is in `DECISIONS.md` §2026-10-17, "o teto do tile".
     */
    const val MAX_TILE_BYTES = 4 * 1024 * 1024
    private const val MB = 1024 * 1024

    private const val WIRE_VARINT = 0
    private const val WIRE_I64 = 1
    private const val WIRE_LEN = 2
    private const val WIRE_I32 = 5

    private const val LAYERS_TAG = (3 shl 3) or WIRE_LEN
    private const val GEOM_LINESTRING = 2

    private const val CMD_MOVE_TO = 1
    private const val CMD_LINE_TO = 2
    private const val CMD_CLOSE_PATH = 7
}
