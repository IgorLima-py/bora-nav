package dev.igor.motonav.net

import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.GZIPOutputStream
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.asResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import okio.GzipSource
import okio.buffer

/**
 * The two bodies that blow a [cap]-byte ceiling, with [content] at the start and spaces to the end.
 * The JSON (or the page) stays valid: without the ceiling, the client **would accept** the response, so the
 * test only passes because the ceiling refused it.
 *
 * - `acima do teto` (above the cap): [cap] + 1 bytes, with known size (the `Content-Length` already says it);
 * - `gzip-bomba`: twice the ceiling in spaces, compressed (~1 KB per MB), opened by the `GzipSource`
 *   with no known size, as OkHttp does with `Content-Encoding: gzip` before handing over the body.
 */
fun oversized(cap: Int, content: String): Map<String, () -> ResponseBody> {
    val head = content.toByteArray(Charsets.UTF_8)
    val bomb: ByteArray by lazy {
        val spaces = ByteArray(1024 * 1024) { ' '.code.toByte() }
        ByteArrayOutputStream().also { out ->
            GZIPOutputStream(out).use { z ->
                z.write(head)
                repeat(2 * cap / spaces.size + 1) { z.write(spaces) }
            }
        }.toByteArray()
    }
    return mapOf(
        "acima do teto" to { (head + ByteArray(cap + 1 - head.size) { ' '.code.toByte() }).toResponseBody() },
        "gzip-bomba" to { GzipSource(Buffer().write(bomb)).buffer().asResponseBody(null, -1) },
    )
}

/**
 * An OkHttp without network: an interceptor answers [code] with [body] to every call and counts the calls
 * in [calls]. The rest (the `use`, the body reading, the `enqueue`) is the real OkHttp's.
 */
fun answering(calls: AtomicInteger = AtomicInteger(), code: Int = 200, body: () -> ResponseBody): OkHttpClient =
    OkHttpClient.Builder().addInterceptor { chain ->
        calls.incrementAndGet()
        Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(code).message("teste")
            .body(body()).build()
    }.build()
