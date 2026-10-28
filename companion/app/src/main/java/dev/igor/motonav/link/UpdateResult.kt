package dev.igor.motonav.link

/**
 * What happened to a `ROUTE_UPDATE` (05 §ROUTE_UPDATE, C13a). The ACK of that
 * message is an answer, not just transport, and each case asks something different of
 * the sender (`RerouteController.refreshEta`).
 */
enum class UpdateResult {
    /** The watch applied the new duration. */
    DELIVERED,

    /** The watch answered that it is not navigating this route. */
    REFUSED,

    /** The message went out and nobody answered within the ACK deadline. */
    SILENT,

    /** The send did not leave the phone (the SDK refused it or hit the deadline). */
    SEND_FAILED,

    /** No watch connected. */
    NOT_CONNECTED,
}

/**
 * The ACK bitmap of a `ROUTE_UPDATE` (a single chunk, so it is bit 0): full means
 * applied, empty means refused. `null` is no ACK within the deadline.
 *
 * Outside `WatchLink` so it can be tested: the class does not instantiate on the JVM.
 */
fun updateResultOf(ackBitmap: ByteArray?): UpdateResult = when {
    ackBitmap == null -> UpdateResult.SILENT
    ackBitmap.isNotEmpty() && (ackBitmap[0].toInt() and 1) == 1 -> UpdateResult.DELIVERED
    else -> UpdateResult.REFUSED
}
