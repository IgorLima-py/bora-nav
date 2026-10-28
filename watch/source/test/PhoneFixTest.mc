import Toybox.Lang;
import Toybox.Test;

//! **PHONE_FIX and FIX_REQ** (C13b, `05 §PHONE_FIX` and `§FIX_REQ`): the phone GPS
//! as a fallback, and the watch asking for it.
//!
//! The bytes come from `TestVectors`; the `PHONE_FIX` there is **`tools/fixtures/phone_fix_00.bin`
//! itself**, the same file the Kotlin `phoneFixMatchesFixture` compares the packer
//! against, and `FIX_REQ_ON` is the `fix_req_00.bin` that the Kotlin `FixReqTest` reads.
//! The place is MASP.
(:test)
module PhoneFixTest {

    //! The packer.py `phone_fix_00.bin` becomes a position with the six fields
    //! right, **no ACK**, no `blk` line in the diagnostics and without touching the route or
    //! the transfer statistics.
    // prevents: the phone fix read with one field in place of another (accuracy becoming
    // speed), one ACK per second competing with the corridor on the link, and the `blk`
    // of each fix pushing the diagnosis of what went wrong out of the 24-line ring.
    (:test)
    function parsesTheFixture(logger as Logger) as Boolean {
        Diag.clear();
        var route = new RouteModel();
        var link = new FakeLink();
        var assembler = new MessageAssembler(route, link);
        SwapAssert.liveRoute(assembler);
        var chunks = assembler.chunksReceived;
        var bytes = assembler.bytesReceived;
        var acks = link.ackCount;
        var revision = route.revision;

        assembler.onData(TestVectors.PHONE_FIX);

        Test.assertMessage(assembler.lastWasPhoneFix, "the app needs to know it was a PHONE_FIX");
        var fix = assembler.phoneFix as PhoneFix;
        Test.assertEqualMessage(fix.latE5, TestVectors.PHONE_FIX_LAT_E5, "latitude");
        Test.assertEqualMessage(fix.lonE5, TestVectors.PHONE_FIX_LON_E5, "longitude");
        Test.assertEqualMessage(fix.speedDms, TestVectors.PHONE_FIX_SPEED_DMS, "speed in dm/s");
        Test.assertEqualMessage(fix.headingDeg, TestVectors.PHONE_FIX_HEADING_DEG, "heading");
        Test.assertMessage(fix.hasHeading(), "271 degrees is a heading");
        Test.assertEqualMessage(fix.accuracyM, TestVectors.PHONE_FIX_ACCURACY_M, "accuracy");
        Test.assertEqualMessage(fix.ageMs, TestVectors.PHONE_FIX_AGE_MS, "age");

        Test.assertEqualMessage(link.ackCount, acks, "PHONE_FIX has no ACK");
        Test.assertEqualMessage(AssemblerAssert.logged("0x0A"), 0, "nor a `blk` line: one arrives per second");
        Test.assertEqualMessage(AssemblerAssert.logged("fix"), 0, "nor any line at all about the fix");
        Test.assertEqualMessage(assembler.chunksReceived, chunks, "does not count as a route chunk");
        Test.assertEqualMessage(assembler.bytesReceived, bytes, "nor as a transfer byte");
        Test.assertEqualMessage(route.revision, revision, "the route did not change");
        Test.assertEqualMessage(assembler.phoneFixes, 1, "the counter that is left in the diagnostics");
        SwapAssert.oldRouteIsIntact(route, assembler, "after the fix");

        // Phone stopped: the heading comes as unknown, not as 65535 degrees.
        assembler.onData(TestVectors.PHONE_FIX_NO_HEADING);
        fix = assembler.phoneFix as PhoneFix;
        Test.assertMessage(!fix.hasHeading(), "no heading");
        Test.assertEqualMessage(fix.headingDeg, Protocol.HEADING_UNKNOWN, "the value for one with no heading");
        Test.assertEqualMessage(fix.accuracyM, TestVectors.PHONE_FIX_ACCURACY_M, "the neighboring field was not touched");

        // The next message, of another type, undoes the mark.
        assembler.onData(TestVectors.CORRIDOR);
        assembler.drainJobs();
        Test.assertMessage(!assembler.lastWasPhoneFix, "the mark belongs only to the last message");
        Diag.clear();
        return true;
    }

    //! What is not a position is dropped with no ACK and without becoming the watch fix:
    //! one byte fewer, one more, latitude beyond the pole, and the message in two chunks.
    // prevents: BLE garbage (05 §Regras de robustez 4) becoming the bike's position and the watch
    // declaring off route, or reading past the payload; and the repeated rejection at 1 Hz
    // filling the diagnostics ring as `blk` would.
    (:test)
    function aMalformedFixIsDroppedWithoutAck(logger as Logger) as Boolean {
        Diag.clear();
        var link = new FakeLink();
        var assembler = new MessageAssembler(new RouteModel(), link);
        var bad = [
            TestVectors.PHONE_FIX_SHORT,
            TestVectors.PHONE_FIX_LONG,
            TestVectors.PHONE_FIX_OFF_THE_MAP,
            TestVectors.PHONE_FIX_TWO_CHUNKS
        ] as Array<ByteArray>;

        for (var i = 0; i < bad.size(); i++) {
            assembler.onData(bad[i]);
            Test.assertMessage(!assembler.lastWasPhoneFix, "refused " + i.toString() + " is not a fix");
            Test.assertMessage(assembler.phoneFix == null, "refused " + i.toString() + " leaves no position");
        }
        Test.assertEqualMessage(link.ackCount, 0, "a refused one has no ACK either");
        Test.assertEqualMessage(assembler.phoneFixesRefused, 4, "the four refusals counted");
        Test.assertEqualMessage(AssemblerAssert.logged("rej fix"), 1, "only the first refusal of the series goes to the log");
        Test.assertEqualMessage(assembler.chunksReceived, 0, "none became a block chunk");

        // A good fix after the rejections is accepted: the rejection does not poison the next one.
        assembler.onData(TestVectors.PHONE_FIX);
        Test.assertMessage(assembler.lastWasPhoneFix, "the good one after the bad ones");
        Diag.clear();
        return true;
    }

    //! The FIX_REQ frame must be, byte by byte, the one from `tools/packer.py`
    //! (`fix_req_00.bin`), which is what the Kotlin reader checks on the other side.
    // prevents: the phone reading "on" where the watch wrote "off" (or the byte at the
    // wrong offset) and keeping the GPS on the whole trip, or never turning it on.
    (:test)
    function fixReqMatchesTheFixture(logger as Logger) as Boolean {
        var link = new PhoneLink();
        var on = link.fixReqFrame(true);
        var off = link.fixReqFrame(false);

        Test.assertEqualMessage(on.size(), TestVectors.FIX_REQ_ON.size(), "frame size");
        for (var i = 0; i < TestVectors.FIX_REQ_ON.size(); i++) {
            Test.assertEqualMessage(on[i], TestVectors.FIX_REQ_ON[i], "on, byte " + i.toString());
            Test.assertEqualMessage(off[i], TestVectors.FIX_REQ_OFF[i], "off, byte " + i.toString());
        }
        Test.assertMessage(on[Protocol.HEADER_SIZE] != off[Protocol.HEADER_SIZE], "the two requests differ");
        return true;
    }
}
