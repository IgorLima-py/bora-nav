package dev.igor.motonav.net

import dev.igor.motonav.corridor.MvtReader
import okhttp3.Response
import okhttp3.ResponseBody

/**
 * **The body of an HTTP response, with a cap** (C16): `null` when it exceeds [limit] bytes, by
 * `Content-Length` or by the block-wise read ([MvtReader.readCapped]).
 *
 * OkHttp opens `Content-Encoding: gzip` on its own, before the body gets here, and `string()` or
 * `bytes()` read everything that comes. An endless body, or a gzip bomb (a few KB that open into
 * gigabytes), becomes `OutOfMemoryError`: it is an `Error`, goes past every `catch (e: Exception)` and takes down the
 * process, `NavForegroundService` along with it. Each client picks the cap from its real response
 * (`DECISIONS.md` §2026-10-17, "o teto das respostas HTTP").
 */
fun ResponseBody.bytesCapped(limit: Int): ByteArray? =
    if (contentLength() > limit) null else byteStream().use { MvtReader.readCapped(it, limit) }

/**
 * The body as text, in the `Content-Type` charset (UTF-8 without it, like `string()`), or `null` if it
 * exceeds [limit] bytes ([bytesCapped]). No body is empty text, like `body?.string().orEmpty()`.
 */
fun Response.textCapped(limit: Int): String? {
    val body = body ?: return ""
    val bytes = body.bytesCapped(limit) ?: return null
    return String(bytes, body.contentType()?.charset() ?: Charsets.UTF_8)
}
