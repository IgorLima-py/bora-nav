import Toybox.Lang;
import Toybox.StringUtil;

//! Converts what Connect IQ delivers in `onPhoneMessage` to a `ByteArray`.
//!
//! It exists because the Android SDK and Monkey C disagree on how a byte
//! array crosses the link: the companion sends `sendMessage(..., listOf(payload))`
//! and the watch may receive it as a ByteArray, as an Array of Number (one byte
//! per element), as a String, or nested inside an Array. The old reader
//! only accepted the first two forms and silently returned `null` on all the
//! others — which is exactly what stalled attempt 2 on the road (`rx 2 · ack 0/0`
//! with "formato inesperado").
//!
//! Here the two functions go together: `decode` accepts every plausible form and
//! `describe` says **which** one arrived, so the watch's screen and log can
//! prove what happened instead of leaving us guessing.
module PhoneData {

    //! Description short enough to fit on the watch screen.
    //! E.g. `BA37`, `Arr1:Str52`, `Arr37:Num`, `null`.
    function describe(data as Object?) as String {
        if (data == null) {
            return "null";
        }
        if (data instanceof ByteArray) {
            return "BA" + (data as ByteArray).size().toString();
        }
        if (data instanceof String) {
            return "Str" + (data as String).length().toString();
        }
        if (data instanceof Number) {
            return "Num";
        }
        if (data instanceof Dictionary) {
            return "Dict" + (data as Dictionary).size().toString();
        }
        if (data instanceof Array) {
            var list = data as Array;
            var inner = list.size() > 0 ? describe(list[0]) : "vazio";
            return "Arr" + list.size().toString() + ":" + inner;
        }
        return "?";
    }

    //! `null` only when no reading is possible — and in that case
    //! `describe` says what it was.
    function decode(data as Object?) as ByteArray? {
        if (data instanceof ByteArray) {
            return data as ByteArray;
        }
        if (data instanceof String) {
            return fromBase64(data as String);
        }
        if (data instanceof Array) {
            var list = data as Array;
            if (list.size() == 0) {
                return null;
            }
            if (list[0] instanceof Number) {
                return fromNumbers(list);
            }
            // A single wrapped element: ByteArray, String or another Array.
            return decode(list[0]);
        }
        return null;
    }

    //! One byte per element, as the SDK does when it serializes a byte[] into a list.
    //! (Module functions in Monkey C do not accept `private`.)
    function fromNumbers(list as Array) as ByteArray {
        var size = list.size();
        var bytes = new [size]b;
        for (var i = 0; i < size; i++) {
            var value = list[i];
            bytes[i] = value instanceof Number ? (value as Number) & 0xFF : 0;
        }
        return bytes;
    }

    //! The companion's current transport: the binary frame goes in Base64 in a String,
    //! the type that both sides carry without ambiguity.
    function fromBase64(text as String) as ByteArray? {
        var bytes = StringUtil.convertEncodedString(
            text,
            {
                :fromRepresentation => StringUtil.REPRESENTATION_STRING_BASE64,
                :toRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY
            }
        );
        return bytes instanceof ByteArray ? bytes as ByteArray : null;
    }
}
