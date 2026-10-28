import Toybox.Lang;
import Toybox.WatchUi;

//! The Favorites screen (RF-02, C12): the list the phone sent, and choosing one is
//! asking for the route to it. A native `Menu2`, so touch, arrows and the Venu 4's Enter
//! work without code of ours; it is the same key automation of the simulator that
//! `tools/e2e.py --favorito` uses (Enter opens, arrow goes down, Enter picks).
//!
//! An empty list shows an item that says where to register, and does nothing when
//! chosen: never a blank screen.
function pushFavorites() as Boolean {
    var menu = new WatchUi.Menu2({ :title => Rez.Strings.FavoritesItem });
    var count = Favorites.count();
    Diag.add("favorites opened: " + count.toString());
    if (count == 0) {
        menu.addItem(new WatchUi.MenuItem(Rez.Strings.NoFavorites, Rez.Strings.AddOnPhone, :none, {}));
    }
    for (var i = 0; i < count; i++) {
        menu.addItem(new WatchUi.MenuItem(Favorites.labelAt(i), null, Favorites.ids[i], {}));
    }
    WatchUi.pushView(menu, new FavoritesDelegate(), WatchUi.SLIDE_LEFT);
    return true;
}

class FavoritesDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof Number)) {
            return;
        }
        (getApp() as MotoNavApp).startFavorite(id as Number);
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

//! The Recents screen (C16.5): the last destinations the phone sent (`Recents`), and choosing one
//! is asking for the route again, from the current position. Same `Menu2` and same empty-list rule.
function pushRecents() as Boolean {
    var menu = new WatchUi.Menu2({ :title => Rez.Strings.RecentsItem });
    var count = Recents.count();
    Diag.add("recents opened: " + count.toString());
    if (count == 0) {
        menu.addItem(new WatchUi.MenuItem(Rez.Strings.NoRecents, Rez.Strings.RecentsAfterTrip, :none, {}));
    }
    for (var i = 0; i < count; i++) {
        menu.addItem(new WatchUi.MenuItem(Recents.labelAt(i), null, Recents.ids[i], {}));
    }
    WatchUi.pushView(menu, new RecentsDelegate(), WatchUi.SLIDE_LEFT);
    return true;
}

class RecentsDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof Number)) {
            return;
        }
        (getApp() as MotoNavApp).startRecent(id as Number);
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
