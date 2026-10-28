import Toybox.Application.Storage;
import Toybox.Lang;

//! `Storage` cleanup (C14, `03 §Storage`: "clear route/corridor keys").
//!
//! The app **does not save the route or the corridor**: they live in memory and are born
//! again on every `ROUTE`/`CORRIDOR`. But the `03` design foresaw the `route.*`
//! and `corridor.*` keys, and the watch's `Storage` (and the simulator's) survives
//! between installs, with a cap that Garmin does not document. So at launch the
//! app deletes any leftover of those keys, so as never to compete for space with what
//! it actually keeps (`config`, `favorites`, `prefs`).
//!
//! CIQ does not enumerate `Storage` keys, so the list is closed: the name
//! of each chunk that `03` foresees, with the design's limits (up to 16 polyline
//! chunks and 4 LODs × 16 chunks).
module StorageCleanup {

    const META = "route.meta";
    const TURNS = "route.turns";
    const POLY_PREFIX = "route.poly.";
    const CORRIDOR_PREFIX = "corridor.";

    const POLY_CHUNKS = 16;
    const LODS = 4;
    const CORRIDOR_CHUNKS = 16;

    //! Deletes the route and corridor keys. Returns how many **existed**.
    function dropOldRoutes() as Number {
        var dropped = 0;
        dropped += drop(META);
        dropped += drop(TURNS);
        for (var n = 0; n < POLY_CHUNKS; n++) {
            dropped += drop(POLY_PREFIX + n.toString());
        }
        for (var lod = 0; lod < LODS; lod++) {
            for (var n = 0; n < CORRIDOR_CHUNKS; n++) {
                dropped += drop(CORRIDOR_PREFIX + lod.toString() + "." + n.toString());
            }
        }
        if (dropped > 0) {
            Diag.add("storage: " + dropped.toString() + " route keys deleted");
        }
        return dropped;
    }

    function drop(key as String) as Number {
        if (Storage.getValue(key) == null) {
            return 0;
        }
        Storage.deleteValue(key);
        return 1;
    }
}
