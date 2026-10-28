import Toybox.Lang;

//! A position from the phone's GPS (`05 §PHONE_FIX`, C13b): the backup for when the
//! watch's GPS has no fix in the middle of navigation. The phone only sends while
//! the watch asks (`FIX_REQ`), and the watch decides what to do with it.
//!
//! Mirror of `pack_phone_fix` in `tools/packer.py` and of
//! `ProtocolPacker.packPhoneFix` in Kotlin; the fixture is `phone_fix_00.bin`.
class PhoneFix {

    //! 1e-5 degree, like the whole protocol.
    var latE5 as Number;
    var lonE5 as Number;

    //! dm/s, the unit of the `trk` line.
    var speedDms as Number;

    //! Degrees, 0..359, or [Protocol.HEADING_UNKNOWN]: a stopped phone has no heading.
    var headingDeg as Number;

    //! Accuracy radius in meters; 0xFFFF is "worse than fits here".
    var accuracyM as Number;

    //! Age of the fix when the phone sent it, in ms; 0xFFFF is "more than a minute".
    var ageMs as Number;

    function initialize(latE5 as Number, lonE5 as Number, speedDms as Number, headingDeg as Number,
            accuracyM as Number, ageMs as Number) {
        self.latE5 = latE5;
        self.lonE5 = lonE5;
        self.speedDms = speedDms;
        self.headingDeg = headingDeg;
        self.accuracyM = accuracyM;
        self.ageMs = ageMs;
    }

    function hasHeading() as Boolean {
        return headingDeg < 360;
    }

    //! Reads the payload that starts at `offset`. `null` for what is not a position:
    //! wrong size, or a coordinate outside the globe (`05 §Robustness rules 4`).
    //! The caller has already checked that the `length` bytes exist.
    static function parse(data as ByteArray, offset as Number, length as Number) as PhoneFix? {
        if (length != Protocol.PHONE_FIX_BYTES) {
            return null;
        }
        var lat = Protocol.readS32(data, offset);
        var lon = Protocol.readS32(data, offset + 4);
        if (lat < -Protocol.MAX_LAT_E5 || lat > Protocol.MAX_LAT_E5
                || lon < -Protocol.MAX_LON_E5 || lon > Protocol.MAX_LON_E5) {
            return null;
        }
        var heading = Protocol.readU16(data, offset + 10);
        return new PhoneFix(
            lat,
            lon,
            Protocol.readU16(data, offset + 8),
            heading < 360 ? heading : Protocol.HEADING_UNKNOWN,
            Protocol.readU16(data, offset + 12),
            Protocol.readU16(data, offset + 14)
        );
    }
}
