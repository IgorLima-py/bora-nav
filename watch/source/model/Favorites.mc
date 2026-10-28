import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.StringUtil;

//! **The favorites** that the phone sends in the `FAVORITES` message (0x05, C12,
//! `05 §FAVORITES`): what the Favorites screen lists and what `NAV_START_REQ`
//! sends back (only the `favId`).
//!
//! Parallel arrays of primitives, like `RouteModel`: there are at most 6 items, and
//! no object per item. **The whole list replaces the previous one**, and a
//! message that does not add up (more than 6, repeated `favId`, name over 20 B,
//! short payload or with leftovers) is refused **whole**, with the old list
//! intact and the reason in the log (`favoritos recusados: ...`).
//!
//! Saves to `Storage` (key `favorites`) and [restore] brings the list back at
//! launch: the screen works before the phone speaks.
//!
//! The reading and `Storage` also apply to RECENTS (C16.5, [Recents]): the same format,
//! another key and another ceiling ([parseList], [readStored], [store]).
module Favorites {

    //! `05 §FAVORITES`: `01 §Screens` asks for a simple list of up to 6 items.
    const MAX = 6;
    const MAX_NAME_BYTES = 20;
    const STORAGE_KEY = "favorites";

    var ids as Array<Number> = [] as Array<Number>;
    var names as Array<String> = [] as Array<String>;
    var latE5 as Array<Number> = [] as Array<Number>;
    var lonE5 as Array<Number> = [] as Array<Number>;
    var icons as Array<Number> = [] as Array<Number>;

    //! Goes up on every applied or restored list: the screen compares it to rebuild itself.
    var revision as Number = 0;

    function count() as Number {
        return ids.size();
    }

    //! Position of the `favId` in the list, or -1.
    function indexOfId(favId as Number) as Number {
        return ids.indexOf(favId);
    }

    //! The item's on-screen text: the name, or "Favorito N" if the phone sent it empty.
    function labelAt(index as Number) as String {
        var name = names[index] as String;
        return name.length() > 0 ? name : Tr.f(Rez.Strings.FavoriteN, [ids[index] as Number]);
    }

    //! Applies the whole message or none of it. `persist` false is for
    //! tests, which must not dirty the app's `Storage`.
    function applyPayload(payload as ByteArray, persist as Boolean) as Boolean {
        var parsed = parse(payload);
        if (parsed == null) {
            return false;
        }
        commit(parsed, persist);
        Diag.add("favorites " + count().toString() + " applied");
        return true;
    }

    //! At launch: brings back the saved list. An invalid saved one (old version,
    //! corrupted `Storage`) is deleted and the list stays empty.
    function restore() as Void {
        var stored = readStored(STORAGE_KEY, MAX, "favorites"); // lang: log
        if (stored == null) {
            return;
        }
        commit(stored, false);
        Diag.add("favorites restored from Storage: " + count().toString());
    }

    //! The list saved under `key`, in the [parse] format, or `null`. What does not check out is deleted,
    //! with the reason in the log.
    function readStored(key as String, max as Number, what as String) as Dictionary? {
        var stored = Storage.getValue(key);
        if (stored == null) {
            return null;
        }
        if (!(stored instanceof Dictionary)) {
            discard(key, what, "format");
            return null;
        }
        var dict = stored as Dictionary;
        var keys = ["i", "n", "a", "o", "c"];
        for (var k = 0; k < keys.size(); k++) {
            if (!(dict.get(keys[k]) instanceof Array)) {
                discard(key, what, "field " + (keys[k] as String));
                return null;
            }
        }
        var i = dict.get("i") as Array;
        var n = dict.get("n") as Array;
        var a = dict.get("a") as Array;
        var o = dict.get("o") as Array;
        var c = dict.get("c") as Array;
        var size = i.size();
        if (size > max || n.size() != size || a.size() != size || o.size() != size || c.size() != size) {
            discard(key, what, "size"); // lang: log
            return null;
        }
        for (var j = 0; j < size; j++) {
            if (!(i[j] instanceof Number) || !(n[j] instanceof String) || !(a[j] instanceof Number)
                    || !(o[j] instanceof Number) || !(c[j] instanceof Number)) {
                discard(key, what, "type");
                return null;
            }
        }
        return {
            :ids => i,
            :names => n,
            :lat => a,
            :lon => o,
            :icons => c
        };
    }

    //! The empty list. `persist` clears the `Storage` too.
    function reset(persist as Boolean) as Void {
        ids = [] as Array<Number>;
        names = [] as Array<String>;
        latE5 = [] as Array<Number>;
        lonE5 = [] as Array<Number>;
        icons = [] as Array<Number>;
        revision++;
        if (persist) {
            Storage.deleteValue(STORAGE_KEY);
        }
    }

    //! The message read, or `null` with the reason in the log. Each read checks the
    //! bytes first (`05 §Robustness rules 4`): what arrives over BLE is not trustworthy.
    function parse(payload as ByteArray) as Dictionary? {
        return parseList(payload, MAX, "favorites"); // lang: log
    }

    //! The [parse] of a list of up to `max` places; `what` goes in the refusal's log.
    function parseList(payload as ByteArray, max as Number, what as String) as Dictionary? {
        if (payload.size() < 1) {
            return refuse(what, "short payload");
        }
        var wanted = payload[0] as Number;
        if (wanted > max) {
            return refuse(what, "more than " + max.toString());
        }
        var outIds = [] as Array<Number>;
        var outNames = [] as Array<String>;
        var outLat = [] as Array<Number>;
        var outLon = [] as Array<Number>;
        var outIcons = [] as Array<Number>;
        var offset = 1;
        for (var i = 0; i < wanted; i++) {
            // favId (1) + lat (4) + lon (4) + name length (1)
            if (!Protocol.hasBytes(payload, offset, 10)) {
                return refuse(what, "short payload");
            }
            var favId = payload[offset] as Number;
            var lat = Protocol.readS32(payload, offset + 1);
            var lon = Protocol.readS32(payload, offset + 5);
            var nameLen = payload[offset + 9] as Number;
            offset += 10;
            if (nameLen > MAX_NAME_BYTES) {
                return refuse(what, "name over 20");
            }
            // the name and the icon byte
            if (!Protocol.hasBytes(payload, offset, nameLen + 1)) {
                return refuse(what, "short payload");
            }
            var name = "";
            if (nameLen > 0) {
                name = decodeUtf8(payload.slice(offset, offset + nameLen));
                if (name.length() == 0) {
                    return refuse(what, "unreadable name");
                }
            }
            offset += nameLen;
            var icon = payload[offset] as Number;
            offset += 1;
            if (outIds.indexOf(favId) >= 0) {
                return refuse(what, "favId repeated");
            }
            outIds.add(favId);
            outNames.add(name);
            outLat.add(lat);
            outLon.add(lon);
            outIcons.add(icon);
        }
        if (offset != payload.size()) {
            return refuse(what, "extra bytes");
        }
        return {
            :ids => outIds,
            :names => outNames,
            :lat => outLat,
            :lon => outLon,
            :icons => outIcons
        };
    }

    function commit(parsed as Dictionary, persist as Boolean) as Void {
        ids = parsed[:ids] as Array<Number>;
        names = parsed[:names] as Array<String>;
        latE5 = parsed[:lat] as Array<Number>;
        lonE5 = parsed[:lon] as Array<Number>;
        icons = parsed[:icons] as Array<Number>;
        revision++;
        if (persist) {
            store(STORAGE_KEY, parsed, "favorites"); // lang: log
        }
    }

    //! Writes the list read under `key`. A failure only goes to the log: applied, it holds until the app closes.
    function store(key as String, parsed as Dictionary, what as String) as Void {
        try {
            Storage.setValue(key, {
                "i" => parsed[:ids],
                "n" => parsed[:names],
                "a" => parsed[:lat],
                "o" => parsed[:lon],
                "c" => parsed[:icons]
            });
        } catch (ex) {
            Diag.add(what + " not saved to Storage");
        }
    }

    function refuse(what as String, why as String) as Dictionary? {
        Diag.add(what + " refused: " + why);
        return null;
    }

    function discard(key as String, what as String, why as String) as Void {
        Storage.deleteValue(key);
        Diag.add(what + " from Storage discarded (" + why + ")");
    }

    //! Invalid UTF-8 gives the empty string, and the caller refuses the message.
    function decodeUtf8(bytes as ByteArray) as String {
        var text = StringUtil.convertEncodedString(
            bytes,
            {
                :fromRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
                :toRepresentation => StringUtil.REPRESENTATION_STRING_PLAIN_TEXT,
                :encoding => StringUtil.CHAR_ENCODING_UTF8
            }
        );
        return text instanceof String ? text as String : "";
    }
}
