import Toybox.Lang;
import Toybox.System;
import Toybox.Test;

//! Records ACKs instead of transmitting them, so the tests run in the
//! simulator without a phone.
(:test)
class FakeLink extends PhoneLink {

    var ackCount as Number = 0;
    var lastAckType as Number = -1;
    var lastBitmap as ByteArray = []b;

    function initialize() {
        PhoneLink.initialize();
    }

    function sendAck(msgType as Number, routeId as Number, total as Number, bitmap as ByteArray) as Void {
        ackCount++;
        lastAckType = msgType;
        lastBitmap = bitmap;
    }

    //! Without this the end of the transfer really calls `Communications.transmit` and the
    //! simulator, which has no phone on the other side, hangs the suite.
    var logFlushes as Number = 0;

    function flushLog() as Void {
        logFlushes++;
    }

    //! The recalculation request (C11), stored instead of transmitted.
    var rerouteCount as Number = 0;
    var lastRerouteRouteId as Number = -1;
    var lastRerouteLatE5 as Number = 0;
    var lastRerouteLonE5 as Number = 0;
    var lastRerouteHeading as Number = -1;
    var lastRerouteDistM as Number = -1;

    //! The favorite navigation request (C12), stored instead of transmitted.
    var navStartCount as Number = 0;
    var lastNavStartFavId as Number = -1;

    function sendNavStartReq(favId as Number) as Void {
        navStartCount++;
        lastNavStartFavId = favId;
    }

    //! The phone GPS request (C13b), stored instead of transmitted.
    var fixReqCount as Number = 0;
    var lastFixReqOn as Boolean = false;

    function sendFixReq(on as Boolean) as Void {
        fixReqCount++;
        lastFixReqOn = on;
    }

    function sendRerouteReq(routeId as Number, latE5 as Number, lonE5 as Number, headingDeg as Number, distAlongM as Number) as Void {
        rerouteCount++;
        lastRerouteRouteId = routeId;
        lastRerouteLatE5 = latE5;
        lastRerouteLonE5 = lonE5;
        lastRerouteHeading = headingDeg;
        lastRerouteDistM = distAlongM;
    }
}

//! The REROUTE_REQ frame must be, byte by byte, the one from `tools/packer.py`
//! (`reroute_req_00.bin`), which is what the Kotlin reader checks on the other side.
(:test)
function rerouteReqMatchesTheFixture(logger as Logger) as Boolean {
    var frame = new PhoneLink().rerouteReqFrame(
        TestVectors.REROUTE_ROUTE_ID,
        TestVectors.REROUTE_LAT_E5,
        TestVectors.REROUTE_LON_E5,
        TestVectors.REROUTE_HEADING_DEG,
        TestVectors.REROUTE_DIST_ALONG_M
    );
    var expected = TestVectors.REROUTE_REQ;

    Test.assertEqualMessage(frame.size(), expected.size(), "frame size");
    for (var i = 0; i < expected.size(); i++) {
        Test.assertEqualMessage(frame[i], expected[i], "byte " + i.toString());
    }

    // The unknown bearing takes both bytes of the field, without overflowing into the neighbor.
    var unknown = new PhoneLink().rerouteReqFrame(1, 0, 0, Protocol.HEADING_UNKNOWN, 0);
    Test.assertEqualMessage(unknown[Protocol.HEADER_SIZE + 8], 0xFF, "unknown heading, high byte");
    Test.assertEqualMessage(unknown[Protocol.HEADER_SIZE + 9], 0xFF, "unknown heading, low byte");
    Test.assertEqualMessage(unknown[Protocol.HEADER_SIZE + 10], 0x00, "distance was not touched");
    return true;
}

(:test)
function assemblerParsesMeta(logger as Logger) as Boolean {
    var route = new RouteModel();
    var link = new FakeLink();
    var assembler = new MessageAssembler(route, link);

    assembler.onData(TestVectors.META);

    Test.assertEqualMessage(route.routeId, TestVectors.ROUTE_ID, "routeId");
    Test.assertEqualMessage(route.lat0, TestVectors.LAT0, "lat0");
    Test.assertEqualMessage(route.lon0, TestVectors.LON0, "lon0");
    Test.assertEqualMessage(route.distanceM, TestVectors.DISTANCE_M, "distanceM");
    Test.assertEqualMessage(route.durationS, TestVectors.DURATION_S, "durationS");
    Test.assertEqualMessage(route.destName, TestVectors.DEST_NAME, "destName");
    Test.assertEqualMessage(route.polyPointCount, TestVectors.POINT_COUNT, "polyPointCount");
    Test.assertEqualMessage(route.turnCount, TestVectors.TURN_COUNT, "turnCount");
    Test.assertEqualMessage(link.ackCount, 1, "one ACK per block");
    return true;
}

//! The polyline vector contains an int32 escape pair (0x7FFF,0x7FFF).
(:test)
function assemblerParsesPolylineWithEscape(logger as Logger) as Boolean {
    var route = new RouteModel();
    var assembler = new MessageAssembler(route, new FakeLink());

    assembler.onData(TestVectors.META);
    assembler.onData(TestVectors.POLY);

    Test.assertEqualMessage(route.lats.size(), TestVectors.POINT_COUNT, "point count");
    Test.assertEqualMessage(route.lats[0], TestVectors.LAT0, "first lat");
    Test.assertEqualMessage(route.lons[0], TestVectors.LON0, "first lon");
    Test.assertEqualMessage(route.lats[TestVectors.POINT_COUNT - 1], TestVectors.LAST_LAT, "last lat");
    Test.assertEqualMessage(route.lons[TestVectors.POINT_COUNT - 1], TestVectors.LAST_LON, "last lon");
    return true;
}

//! CORRIDOR: one way with short deltas and another with the escape pair, both
//! restarting the delta chain at (lat0, lon0) — which is what sets the ROUTE_POLY
//! block apart and what is most likely to diverge between the three sides.
(:test)
function assemblerParsesCorridorWays(logger as Logger) as Boolean {
    var route = new RouteModel();
    var assembler = new MessageAssembler(route, new FakeLink());

    assembler.onData(TestVectors.META);
    assembler.onData(TestVectors.POLY);
    assembler.onData(TestVectors.CORRIDOR);

    var corridor = assembler.getCorridor();
    var lod = TestVectors.CORRIDOR_LOD;

    Test.assertEqualMessage(corridor.wayCount(lod), TestVectors.CORRIDOR_WAY_COUNT, "ways of the LOD");
    Test.assertEqualMessage(
        (corridor.xs[lod] as Array<Float>).size(),
        TestVectors.CORRIDOR_POINT_COUNT,
        "points of the LOD"
    );
    Test.assertEqualMessage(corridor.lodsReceived, 1, "one LOD received");

    // The last point of the last way, projected, must match the expected one.
    var expectedX = Projection.toLocalX(TestVectors.CORRIDOR_LAST_LON, route.lon0, route.lonScale);
    var expectedY = Projection.toLocalY(TestVectors.CORRIDOR_LAST_LAT, route.lat0);
    var xs = corridor.xs[lod] as Array<Float>;
    var ys = corridor.ys[lod] as Array<Float>;
    Test.assertMessage(
        NavAssert.near(xs[xs.size() - 1] as Float, expectedX, 0.5),
        "last x of the corridor"
    );
    Test.assertMessage(
        NavAssert.near(ys[ys.size() - 1] as Float, expectedY, 0.5),
        "last y of the corridor — the escape pair was read"
    );

    // The end sentinel is what lets the drawing loop always read starts[w+1].
    var starts = corridor.wayStart[lod] as Array<Number>;
    Test.assertEqualMessage(
        starts[starts.size() - 1] as Number,
        TestVectors.CORRIDOR_POINT_COUNT,
        "the sentinel closes the ways array"
    );
    return true;
}

//! A new route has another local plane: keeping the old corridor would draw random
//! streets over the new route (`05 §Regras de robustez 2`).
(:test)
function newRouteDropsTheOldCorridor(logger as Logger) as Boolean {
    var route = new RouteModel();
    var assembler = new MessageAssembler(route, new FakeLink());

    assembler.onData(TestVectors.META);
    assembler.onData(TestVectors.POLY);
    assembler.onData(TestVectors.CORRIDOR);
    Test.assertMessage(!assembler.getCorridor().isEmpty(), "corridor arrived");

    assembler.onData(TestVectors.META);

    Test.assertMessage(assembler.getCorridor().isEmpty(), "a new META clears the corridor");
    Test.assertEqualMessage(assembler.getCorridor().lodsReceived, 0, "and the LOD count");
    return true;
}

//! Block truncated in the middle of a way: the incomplete way is dropped whole, instead
//! of becoming a street that ends nowhere.
(:test)
function corridorDropsATruncatedWay(logger as Logger) as Boolean {
    var route = new RouteModel();
    var assembler = new MessageAssembler(route, new FakeLink());

    assembler.onData(TestVectors.META);
    assembler.onData(TestVectors.POLY);

    // Cuts 6 bytes from the end: the last way loses part of the escape pair.
    var full = TestVectors.CORRIDOR;
    var cut = full.slice(0, full.size() - 6);
    // The header must stay consistent with the shortened payload.
    cut[6] = 0;
    cut[7] = cut.size() - Protocol.HEADER_SIZE;
    assembler.onData(cut);

    var corridor = assembler.getCorridor();
    Test.assertEqualMessage(
        corridor.wayCount(TestVectors.CORRIDOR_LOD),
        1,
        "only the complete way went in"
    );
    Test.assertMessage(assembler.lastError.length() > 0, "and the truncation was recorded");
    return true;
}

//! TURNS arrives split in two chunks and must be reassembled before parsing.
(:test)
function assemblerReassemblesTurns(logger as Logger) as Boolean {
    var route = new RouteModel();
    var link = new FakeLink();
    var assembler = new MessageAssembler(route, link);

    assembler.onData(TestVectors.META);
    assembler.onData(TestVectors.POLY);
    assembler.onData(TestVectors.TURNS_0);
    Test.assertMessage(!route.hasTurns, "half a block must not be applied");
    assembler.onData(TestVectors.TURNS_1);

    Test.assertEqualMessage(route.turnPointIdx.size(), TestVectors.TURN_COUNT, "turn count");
    Test.assertEqualMessage(route.turnType[0], Protocol.TURN_DEPART, "first turn type");
    Test.assertEqualMessage(route.turnType[1], Protocol.TURN_ROUNDABOUT, "roundabout type");
    Test.assertEqualMessage(route.turnExit[1], TestVectors.ROUNDABOUT_EXIT, "roundabout exit");
    Test.assertEqualMessage(route.turnName[2], TestVectors.LONG_NAME_TRUNCATED, "truncated name");
    // prevents: the exitNum of the roundabout with angle (21..28, C16.5) read as the name size, which
    // scrambles this maneuver and all the following ones.
    Test.assertEqualMessage(route.turnType[3], TestVectors.ANGLED_ROUNDABOUT_TYPE, "angled roundabout type");
    Test.assertEqualMessage(route.turnExit[3], TestVectors.ANGLED_ROUNDABOUT_EXIT, "angled roundabout exit");
    Test.assertEqualMessage(route.turnName[3], TestVectors.ANGLED_ROUNDABOUT_NAME, "angled roundabout name");
    Test.assertEqualMessage(route.turnName[4], "", "empty name");
    Test.assertMessage(route.isComplete(), "route should be complete");
    return true;
}

//! Chunks may arrive out of order; a duplicate must not corrupt the block.
(:test)
function assemblerHandlesOutOfOrderAndDuplicateChunks(logger as Logger) as Boolean {
    var route = new RouteModel();
    var assembler = new MessageAssembler(route, new FakeLink());

    assembler.onData(TestVectors.META);
    assembler.onData(TestVectors.POLY);
    assembler.onData(TestVectors.TURNS_1);
    assembler.onData(TestVectors.TURNS_1);
    assembler.onData(TestVectors.TURNS_0);

    Test.assertEqualMessage(route.turnPointIdx.size(), TestVectors.TURN_COUNT, "turn count");
    return true;
}

//! Everything off the link is untrusted: garbage must be rejected, not crash.
(:test)
function assemblerRejectsGarbage(logger as Logger) as Boolean {
    var route = new RouteModel();
    var assembler = new MessageAssembler(route, new FakeLink());

    assembler.onData([0x01, 0x02]b); // shorter than the header
    assembler.onData([0x09, 0x01, 0x00, 0x07, 0x00, 0x01, 0x00, 0x00]b); // wrong protoVersion
    assembler.onData([0x02, 0x01, 0x00, 0x07, 0x05, 0x02, 0x00, 0x00]b); // seq >= total (protoVersion 2)
    assembler.onData([0x02, 0x01, 0x00, 0x07, 0x00, 0x01, 0xFF, 0xFF]b); // length beyond the data

    Test.assertMessage(!route.hasMeta, "no route should have been built");
    return true;
}

//! A block whose META never arrived is dropped with an empty ACK, so the
//! companion resends from META (05 §Regras de robustez 1).
(:test)
function assemblerDropsBlockWithoutMeta(logger as Logger) as Boolean {
    var route = new RouteModel();
    var link = new FakeLink();
    var assembler = new MessageAssembler(route, link);

    assembler.onData(TestVectors.POLY);

    Test.assertMessage(!route.hasPoly, "POLY without META must be dropped");
    Test.assertEqualMessage(link.lastAckType, Protocol.MSG_ROUTE_POLY, "ACK for the dropped block");
    return true;
}

//! The bitmap tells the companion exactly which chunks are missing.
(:test)
function blockBufferBitmapMarksReceivedChunks(logger as Logger) as Boolean {
    var buffer = new BlockBuffer(Protocol.MSG_CORRIDOR, 1, 10);
    buffer.put(0, []b);
    buffer.put(3, []b);
    buffer.put(9, []b);

    var bitmap = buffer.bitmap();
    Test.assertEqualMessage(bitmap.size(), 2, "10 chunks need 2 bytes");
    Test.assertEqualMessage(bitmap[0], 0x09, "chunks 0 and 3");
    Test.assertEqualMessage(bitmap[1], 0x02, "chunk 9");
    Test.assertMessage(!buffer.isComplete(), "block is not complete");
    return true;
}

(:test)
module AssemblerAssert {

    //! How many `Diag` lines contain `text`.
    function logged(text as String) as Number {
        var count = 0;
        for (var i = 0; i < Diag.lines.size(); i++) {
            if ((Diag.lines[i] as String).find(text) != null) {
                count++;
            }
        }
        return count;
    }
}

//! The link drops in the middle of a block (C13b). After 30 s of silence the watch sends
//! the bitmap of what arrived, and the phone resends **only what is missing** (`05 §Framing`).
//! So what arrived must stay stored: until C13b the partial ACK threw the block away,
//! the complement opened an empty buffer and the block never closed.
(:test)
function aPartialBlockKeepsItsChunksAfterThePartialAck(logger as Logger) as Boolean {
    var route = new RouteModel();
    var link = new FakeLink();
    var assembler = new MessageAssembler(route, link);

    assembler.onData(TestVectors.META);
    assembler.onData(TestVectors.POLY);
    assembler.onData(TestVectors.TURNS_0);
    var acks = link.ackCount;
    var now = System.getTimer();

    assembler.checkTimeouts(now + Protocol.BLOCK_TIMEOUT_MS - 1000);
    Test.assertEqualMessage(link.ackCount, acks, "within the deadline no ACK goes out");

    assembler.checkTimeouts(now + Protocol.BLOCK_TIMEOUT_MS + 1000);
    Test.assertEqualMessage(link.ackCount, acks + 1, "past the deadline the partial ACK goes out");
    Test.assertEqualMessage(link.lastAckType, Protocol.MSG_TURNS, "for the block that stalled");
    Test.assertEqualMessage(link.lastBitmap[0], 0x01, "the bitmap says only chunk 0 arrived");

    assembler.onData(TestVectors.TURNS_1);
    Test.assertEqualMessage(route.turnPointIdx.size(), TestVectors.TURN_COUNT, "the remainder closes the block");
    Test.assertEqualMessage(link.lastBitmap[0], 0x03, "and the ACK comes back full");
    Test.assertMessage(route.isComplete(), "the route becomes complete");
    return true;
}

//! The block stored after the partial ACK does not stay forever: another full deadline
//! with no new chunk and it is dropped, with the line in the log. The phone has already
//! given up by then (60 s, `WatchLink`), and whatever comes next starts over.
(:test)
function aPartialBlockIsDroppedAfterTheSecondTimeout(logger as Logger) as Boolean {
    var route = new RouteModel();
    var link = new FakeLink();
    var assembler = new MessageAssembler(route, link);
    Diag.clear();

    assembler.onData(TestVectors.META);
    assembler.onData(TestVectors.POLY);
    assembler.onData(TestVectors.TURNS_0);
    var now = System.getTimer();

    assembler.checkTimeouts(now + Protocol.BLOCK_TIMEOUT_MS + 1000);
    var acks = link.ackCount;

    // The second deadline counts from the partial ACK, not from the last chunk.
    assembler.checkTimeouts(now + 2 * Protocol.BLOCK_TIMEOUT_MS);
    Test.assertEqualMessage(AssemblerAssert.logged("block 0x03 abandoned"), 0, "within the second deadline the block stays");

    assembler.checkTimeouts(now + 2 * Protocol.BLOCK_TIMEOUT_MS + 2000);
    Test.assertEqualMessage(AssemblerAssert.logged("block 0x03 abandoned"), 1, "past the second deadline it is dropped");
    Test.assertEqualMessage(link.ackCount, acks, "no other ACK: nobody is waiting");

    // Chunk 0 is gone: chunk 1 alone does not close the block, and its bitmap says so.
    assembler.onData(TestVectors.TURNS_1);
    Test.assertMessage(!route.hasTurns, "half a block is not applied");
    assembler.checkTimeouts(System.getTimer() + Protocol.BLOCK_TIMEOUT_MS + 1000);
    Test.assertEqualMessage(link.lastBitmap[0], 0x02, "only chunk 1 is stored");
    return true;
}

//! The full ACK is lost in the drop and the phone resends the whole block. The LOD is already
//! on the watch: reading it again puts two of it in memory at once (the one in the model
//! and the one being read) and wastes reading ticks. The watch answers the full ACK
//! and does not read.
(:test)
function aCorridorBlockResentAfterCompletionIsNotAppliedTwice(logger as Logger) as Boolean {
    var route = new RouteModel();
    var link = new FakeLink();
    var assembler = new MessageAssembler(route, link);
    Diag.clear();

    assembler.onData(TestVectors.META);
    assembler.onData(TestVectors.POLY);
    assembler.onData(TestVectors.CORRIDOR);
    assembler.drainJobs();
    Test.assertEqualMessage(AssemblerAssert.logged("corridor lod"), 1, "the LOD was read");
    var acks = link.ackCount;

    assembler.onData(TestVectors.CORRIDOR);
    assembler.drainJobs();
    Test.assertEqualMessage(link.ackCount, acks + 1, "the resend is acknowledged");
    Test.assertEqualMessage(link.lastAckType, Protocol.MSG_CORRIDOR, "as a corridor block");
    Test.assertEqualMessage(link.lastBitmap[0], 0x01, "with the full ACK");
    Test.assertEqualMessage(AssemblerAssert.logged("corridor lod"), 1, "and the LOD is not read again");
    Test.assertEqualMessage(
        assembler.getCorridor().wayCount(TestVectors.CORRIDOR_LOD),
        TestVectors.CORRIDOR_WAY_COUNT,
        "what was on the watch is still there"
    );
    return true;
}

//! New route, same corridor block: then it is a new corridor (another local plane), and
//! the "already read" memory cannot cross the route change.
(:test)
function theSameCorridorBlockIsReadAgainOnANewRoute(logger as Logger) as Boolean {
    var route = new RouteModel();
    var link = new FakeLink();
    var assembler = new MessageAssembler(route, link);
    Diag.clear();

    assembler.onData(TestVectors.META);
    assembler.onData(TestVectors.POLY);
    assembler.onData(TestVectors.CORRIDOR);
    assembler.drainJobs();

    // Restarts the same META route: the corridor is cleared, as on a new route.
    assembler.onData(TestVectors.META);
    Test.assertEqualMessage(assembler.getCorridor().lodsReceived, 0, "the META clears the corridor");
    assembler.onData(TestVectors.POLY);
    assembler.onData(TestVectors.CORRIDOR);
    assembler.drainJobs();
    Test.assertEqualMessage(AssemblerAssert.logged("corridor lod"), 2, "the LOD is read again");
    Test.assertEqualMessage(assembler.getCorridor().lodsReceived, 1, "and it is on the watch");
    return true;
}
