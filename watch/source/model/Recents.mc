import Toybox.Application.Storage;
import Toybox.Lang;

//! **The latest destinations** that the phone sends in the `RECENTS` message (0x0B, C16.5,
//! `05 §RECENTS`): what the "Recent" screen on the home screen lists. Igor asked for a button
//! to see the favorites and "the routes" on the home screen (2026-10-17); the earlier route is the
//! earlier destination, redone from the current position.
//!
//! The same format and the same rules as [Favorites] (the whole list replaces the previous one,
//! a message that does not add up is refused whole), with at most [MAX] items and its own key in
//! `Storage`. The id is the position in the phone's list, and only goes back to it in `NAV_START_REQ` with
//! `kind` 1: the phone looks up the destination in its own trips, never in a coordinate coming from here.
module Recents {

    const MAX = 5;
    const STORAGE_KEY = "recents";

    var ids as Array<Number> = [] as Array<Number>;
    var names as Array<String> = [] as Array<String>;
    var latE5 as Array<Number> = [] as Array<Number>;
    var lonE5 as Array<Number> = [] as Array<Number>;
    var icons as Array<Number> = [] as Array<Number>;

    //! Goes up on every applied or restored list.
    var revision as Number = 0;

    function count() as Number {
        return ids.size();
    }

    //! Position of the id in the list, or -1.
    function indexOfId(id as Number) as Number {
        return ids.indexOf(id);
    }

    //! The item's on-screen text: the name, or "Destino N" if the phone sent it empty.
    function labelAt(index as Number) as String {
        var name = names[index] as String;
        return name.length() > 0 ? name : Tr.f(Rez.Strings.DestinationN, [(ids[index] as Number) + 1]);
    }

    //! Applies the whole message or none of it. `persist` false is for the tests.
    function applyPayload(payload as ByteArray, persist as Boolean) as Boolean {
        var parsed = Favorites.parseList(payload, MAX, "recents"); // lang: log
        if (parsed == null) {
            return false;
        }
        commit(parsed, persist);
        Diag.add("recents " + count().toString() + " applied");
        return true;
    }

    //! At launch: brings back the saved list, like [Favorites].
    function restore() as Void {
        var stored = Favorites.readStored(STORAGE_KEY, MAX, "recents"); // lang: log
        if (stored == null) {
            return;
        }
        commit(stored, false);
        Diag.add("recents restored from Storage: " + count().toString());
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

    function commit(parsed as Dictionary, persist as Boolean) as Void {
        ids = parsed[:ids] as Array<Number>;
        names = parsed[:names] as Array<String>;
        latE5 = parsed[:lat] as Array<Number>;
        lonE5 = parsed[:lon] as Array<Number>;
        icons = parsed[:icons] as Array<Number>;
        revision++;
        if (persist) {
            Favorites.store(STORAGE_KEY, parsed, "recents"); // lang: log
        }
    }
}
