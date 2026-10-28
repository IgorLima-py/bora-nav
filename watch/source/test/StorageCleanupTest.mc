import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.Test;

//! **The `Storage` cleanup** (C14, `StorageCleanup`).
//!
//! It only touches the route and corridor keys, plus a test key that the app
//! never uses: the simulator's `Storage` survives between runs (measured in C5)
//! and `config`/`favorites`/`prefs` cannot be dirtied or erased here.

// prevents: leftover route/corridor from an old build eating the `Storage` (undocumented
// ceiling) forever, and the cleanup taking along what the app keeps.
(:test)
function oldRoutesAreDropped(logger as Logger) as Boolean {
    var guard = "teste.guarda";
    Storage.setValue(guard, 7);
    Storage.setValue("route.meta", [1, 2]);
    Storage.setValue("route.turns", [3]);
    Storage.setValue("route.poly.0", [4]);
    Storage.setValue("route.poly.15", [5]);
    Storage.setValue("corridor.0.0", [6]);
    Storage.setValue("corridor.3.15", [7]);
    Diag.clear();

    var dropped = StorageCleanup.dropOldRoutes();

    Test.assertEqualMessage(dropped, 6, "the six keys that existed");
    Test.assertMessage(Storage.getValue("route.meta") == null, "route.meta apagada");
    Test.assertMessage(Storage.getValue("route.poly.15") == null, "last polyline chunk deleted");
    Test.assertMessage(Storage.getValue("corridor.3.15") == null, "last chunk of the last LOD deleted");
    Test.assertEqualMessage(Storage.getValue(guard), 7, "a key that is not a route one stays");
    Test.assertEqualMessage(StorageCleanup.dropOldRoutes(), 0, "second pass: nothing to delete");

    Storage.deleteValue(guard);
    Diag.clear();
    return true;
}
