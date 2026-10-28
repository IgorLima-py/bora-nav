import Toybox.Lang;

//! Constants and readers of the phone <-> watch protocol (docs/05-PROTOCOL.md).
//! Mirror of companion proto/Protocol.kt and tools/packer.py.
module Protocol {

    //! 2 since C16.5: maneuver types 14..30 and the exitNum of 21..28 (05 §TURNS).
    const VERSION = 2;

    // Phone -> watch
    const MSG_ROUTE_META = 0x01;
    const MSG_ROUTE_POLY = 0x02;
    const MSG_TURNS = 0x03;
    const MSG_CORRIDOR = 0x04;
    const MSG_FAVORITES = 0x05;
    const MSG_ROUTE_UPDATE = 0x06;
    const MSG_CANCEL_NAV = 0x07;
    //! The route's speed cameras (05 §RADARS, C16.6): per route, one chunk, after the corridor.
    const MSG_RADARS = 0x08;
    //! Fine tuning without a cable (05 §CONFIG, C5): routeId 0, outside the route check.
    const MSG_CONFIG = 0x09;
    //! The phone's GPS position, while the watch asks (05 §PHONE_FIX, C13b):
    //! routeId 0, one chunk, **no ACK**.
    const MSG_PHONE_FIX = 0x0A;
    //! The latest destinations (05 §RECENTS, C16.5): the FAVORITES format, up to 5 items.
    const MSG_RECENTS = 0x0B;

    // Watch -> phone
    const MSG_ACK = 0x81;
    const MSG_REROUTE_REQ = 0x82;
    const MSG_NAV_START_REQ = 0x83;
    //! The `kind` of the NAV_START_REQ for a recent destination (05 §NAV_START_REQ, C16.5). The favorite
    //! goes without the byte, as in C12.
    const NAV_START_KIND_RECENT = 1;
    const MSG_NAV_ENDED = 0x84;

    //! Watch log as UTF-8 text, for the companion to write to its
    //! file (05 §Diagnostic messages). Only exists in the debug phase.
    const MSG_LOG = 0x85;

    //! The watch requests (1) or dismisses (0) the phone's GPS (05 §FIX_REQ, C13b).
    const MSG_FIX_REQ = 0x86;

    //! PHONE_FIX payload: lat, lon int32 and four uint16.
    const PHONE_FIX_BYTES = 16;

    //! Outside this it is not a place (1e-5 degree): ±90° and ±180°.
    const MAX_LAT_E5 = 9000000;
    const MAX_LON_E5 = 18000000;

    //! NAV_ENDED (0x84) reasons, per `05 §Message types`.
    const NAV_ENDED_ARRIVED = 0;
    const NAV_ENDED_CANCELLED = 1;
    const NAV_ENDED_ERROR = 2;

    //! `heading` of REROUTE_REQ (0x82) when the watch has no heading: any
    //! value ≥ 360 means "unknown" (`05 §REROUTE_REQ`).
    const HEADING_UNKNOWN = 0xFFFF;

    //! Ceiling of a log flush, so as not to compete with the route on the link.
    const MAX_LOG_BYTES = 1200;

    const HEADER_SIZE = 8;
    const DELTA_ESCAPE = 0x7FFF;

    // Caps that protect this app (docs/03-WATCH-APP.md).
    const MAX_POLY_POINTS = 4000;
    const MAX_TURNS = 100;
    //! RADARS (05 §RADARS): up to 200 records of 14 B, mirror of packer.py and Protocol.kt.
    const MAX_RADARS = 200;
    const RADAR_RECORD_BYTES = 14;
    const RADAR_FLAG_DIRECTION = 0x01;

    // CORRIDOR (0x04) — mirror of packer.py and Protocol.kt.
    const LOD_EXPRESS = 0;
    const LOD_ARTERIAL = 1;
    const LOD_COLLECTOR = 2;
    const LOD_LOCAL = 3;
    const CORRIDOR_LOD_COUNT = 4;

    //! The watch's ceiling, independent of the phone's ceiling: what arrives over BLE is
    //! always untrusted and this is the number that protects the **memory** here
    //! (`03 §Budget`).
    //!
    //! Raised from 4,000 to 7,000 on 2026-08-01, together with the companion's ceiling.
    //! The math: 7,000 points are two Float arrays plus the rectangle per way,
    //! on the order of 140 KB — out of the **768 KB** that the `venu445mm` gives a watch app
    //! (`compiler.json`, `appTypes.watchApp.memoryLimit`). What protects the
    //! *frame* is not this number and never was: it is the `MapRenderer`'s adaptive
    //! leash, because the watch only draws what fits on the screen.
    const MAX_CORRIDOR_POINTS = 7000;

    //! Incomplete block is dropped after this long without new chunks.
    const BLOCK_TIMEOUT_MS = 30000;

    // Turn types (05 §TURNS).
    const TURN_DEPART = 0;
    const TURN_STRAIGHT = 1;
    const TURN_SLIGHT_RIGHT = 2;
    const TURN_RIGHT = 3;
    const TURN_SHARP_RIGHT = 4;
    const TURN_UTURN = 5;
    const TURN_SHARP_LEFT = 6;
    const TURN_LEFT = 7;
    const TURN_SLIGHT_LEFT = 8;
    const TURN_ROUNDABOUT = 9;
    const TURN_HIGHWAY_ENTER = 10;
    const TURN_HIGHWAY_EXIT = 11;
    const TURN_ARRIVE = 12;
    const TURN_NEW_NAME = 13;
    // C16.5: the Google Navigation SDK icon set (TurnGlyphs) draws these separately.
    const TURN_FORK_LEFT = 14;
    const TURN_FORK_RIGHT = 15;
    const TURN_MERGE = 16;
    const TURN_MERGE_LEFT = 17;
    const TURN_MERGE_RIGHT = 18;
    const TURN_ARRIVE_LEFT = 19;
    const TURN_ARRIVE_RIGHT = 20;
    //! Roundabout with the exit at an angle: sharp right (21), counterclockwise, up to the U-turn (28).
    const TURN_ROUNDABOUT_SHARP_RIGHT = 21;
    const TURN_ROUNDABOUT_LEFT = 26;
    const TURN_ROUNDABOUT_UTURN = 28;
    const TURN_HIGHWAY_ENTER_LEFT = 29;
    const TURN_HIGHWAY_EXIT_LEFT = 30;

    //! A roundabout carries `exitNum` in the TURNS record: the 9, and the 21..28 since version 2.
    function hasExitNum(type as Number) as Boolean {
        return type == TURN_ROUNDABOUT || (type >= TURN_ROUNDABOUT_SHARP_RIGHT && type <= TURN_ROUNDABOUT_UTURN);
    }

    //! Arrival, with or without the destination's side.
    function isArrival(type as Number) as Boolean {
        return type == TURN_ARRIVE || type == TURN_ARRIVE_LEFT || type == TURN_ARRIVE_RIGHT;
    }

    //! Everything arriving over BLE is untrusted: every read is bounds-checked
    //! by the caller through hasBytes() before use (05 §Robustness rules).
    function hasBytes(data as ByteArray, offset as Number, count as Number) as Boolean {
        return offset >= 0 && count >= 0 && offset + count <= data.size();
    }

    function readU8(data as ByteArray, offset as Number) as Number {
        return data[offset] as Number;
    }

    function readU16(data as ByteArray, offset as Number) as Number {
        return ((data[offset] as Number) << 8) | (data[offset + 1] as Number);
    }

    function readS16(data as ByteArray, offset as Number) as Number {
        var value = readU16(data, offset);
        if (value >= 0x8000) {
            value -= 0x10000;
        }
        return value;
    }

    //! Numbers are 32-bit two's complement here, so the shift already signs it.
    function readS32(data as ByteArray, offset as Number) as Number {
        return ((data[offset] as Number) << 24)
            | ((data[offset + 1] as Number) << 16)
            | ((data[offset + 2] as Number) << 8)
            | (data[offset + 3] as Number);
    }
}
