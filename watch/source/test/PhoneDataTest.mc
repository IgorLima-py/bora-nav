import Toybox.Lang;
import Toybox.StringUtil;
import Toybox.Test;

//! Tests of the phone message reader ([PhoneData]).
//!
//! This is the spot that stalled attempt 2 on the street: the watch received the message
//! (`rx 2`) and silently returned `null` because the format was not the expected one. Each
//! test here is a plausible way for the same frame to arrive through Connect IQ, so
//! the next trip to the street does not spend a round discovering a data format.

(:test)
function phoneDataReadsBareByteArray(logger as Logger) as Boolean {
    var bytes = PhoneData.decode(TestVectors.META);

    Test.assert(bytes != null);
    Test.assert(TestBytes.equal(bytes as ByteArray, TestVectors.META));
    return true;
}

//! `sendMessage(..., listOf(payload))` the way the SDK documents it.
(:test)
function phoneDataReadsWrappedByteArray(logger as Logger) as Boolean {
    var wrapped = [TestVectors.META] as Array<Object>;

    var bytes = PhoneData.decode(wrapped);

    Test.assert(bytes != null);
    Test.assert(TestBytes.equal(bytes as ByteArray, TestVectors.META));
    return true;
}

//! One byte per element — how the SDK serializes byte[] inside a list.
(:test)
function phoneDataReadsArrayOfNumbers(logger as Logger) as Boolean {
    var numbers = [] as Array<Object>;
    for (var i = 0; i < TestVectors.META.size(); i++) {
        numbers.add(TestVectors.META[i]);
    }

    var bytes = PhoneData.decode(numbers);

    Test.assert(bytes != null);
    Test.assert(TestBytes.equal(bytes as ByteArray, TestVectors.META));
    return true;
}

//! Fixed vector: I pin the Base64 expectation (padding included, no line
//! break) without depending on the platform's encoder.
(:test)
function phoneDataReadsKnownBase64(logger as Logger) as Boolean {
    var bytes = PhoneData.decode("AQIDBA==");

    Test.assert(bytes != null);
    Test.assert(TestBytes.equal(bytes as ByteArray, [0x01, 0x02, 0x03, 0x04]b));
    return true;
}

//! The real path of the new transport: the frame goes in Base64 in a String,
//! inside a list, and must reach the assembler exactly the same.
(:test)
function phoneDataReadsBase64Frame(logger as Logger) as Boolean {
    var encoded = StringUtil.convertEncodedString(
        TestVectors.META,
        {
            :fromRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
            :toRepresentation => StringUtil.REPRESENTATION_STRING_BASE64
        }
    );
    Test.assert(encoded instanceof String);

    var bytes = PhoneData.decode([encoded] as Array<Object>);
    Test.assert(bytes != null);
    Test.assert(TestBytes.equal(bytes as ByteArray, TestVectors.META));

    // And the decoded frame is still a valid META for the assembler.
    var route = new RouteModel();
    var link = new FakeLink();
    new MessageAssembler(route, link).onData(bytes as ByteArray);

    Test.assertEqualMessage(route.routeId, TestVectors.ROUTE_ID, "routeId");
    Test.assertEqualMessage(route.destName, TestVectors.DEST_NAME, "destName");
    Test.assertEqualMessage(link.ackCount, 1, "ACK do META");
    return true;
}

//! ACK return: what the watch encodes for the phone must remain the same
//! frame. A raw ByteArray `transmit` reached Android as
//! FAILURE_INVALID_FORMAT and the ACK died on the way.
(:test)
function phoneLinkEncodesAckAsBase64(logger as Logger) as Boolean {
    var link = new PhoneLink();
    var frame = [0x01, 0x81, 0x00, 0x07, 0x00, 0x01, 0x00, 0x03, 0x01, 0x01, 0x01]b;

    var text = link.encode(frame);
    Test.assert(text.length() > 0);

    var decoded = PhoneData.decode(text);
    Test.assert(decoded != null);
    Test.assert(TestBytes.equal(decoded as ByteArray, frame));
    return true;
}

//! What cannot be read must become `null` **and** a readable description: it was the
//! lack of that description that left the failure mute on the screen.
(:test)
function phoneDataDescribesWhatItCannotRead(logger as Logger) as Boolean {
    Test.assert(PhoneData.decode(null) == null);
    Test.assert(PhoneData.decode({ "a" => 1 }) == null);
    Test.assert(PhoneData.decode([] as Array<Object>) == null);

    Test.assertEqualMessage(PhoneData.describe(null), "null", "null");
    Test.assertEqualMessage(PhoneData.describe([0x01, 0x02, 0x03, 0x04]b), "BA4", "ByteArray");
    Test.assertEqualMessage(PhoneData.describe("AQIDBA=="), "Str8", "String");
    Test.assertEqualMessage(
        PhoneData.describe([[0x01, 0x02]b] as Array<Object>),
        "Arr1:BA2",
        "Array de ByteArray"
    );
    Test.assertEqualMessage(PhoneData.describe([1, 2, 3] as Array<Object>), "Arr3:Num", "Array de Number");
    return true;
}

//! Annotated like the other test helpers, so it does not enter the normal build.
(:test)
module TestBytes {

    function equal(left as ByteArray, right as ByteArray) as Boolean {
        if (left.size() != right.size()) {
            return false;
        }
        for (var i = 0; i < left.size(); i++) {
            if (left[i] != right[i]) {
                return false;
            }
        }
        return true;
    }
}
