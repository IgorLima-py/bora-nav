import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.WatchUi;

//! **"Settings" on the home screen** (C16.5). Igor asked for a settings button on the watch and found the
//! numbers too big (2026-10-17). The real fine-tuning stays on the phone (the 13
//! controls of "Watch settings", `05 §CONFIG`); here stay only the three that can be solved with
//! a glove, in four steps each: the whole HUD, the numbers (distance and arrival together) and the
//! street brightness. A native `Menu2`, like the Favorites screen.
//!
//! Writes to `Storage` through the same `Config.commit` as the CONFIG message. The next CONFIG the
//! phone sends overrides the keys it brings: whoever sends last wins.
module QuickSettings {

    //! The rows that change a value; the fourth is "Reset to default".
    const ROWS = 3;
    const RESET = 3;

    //! **"Ruas em imagem" (streets in image)** (2026-10-17): the `StreetCache` test switch, for Igor to
    //! compare on the wrist the streets pasted from an image with those drawn on every frame. It stays in the watch's
    //! `Storage`, outside `CONFIG`: "Reset to default" does not touch it.
    const STREETS = 4;

    //! **"Route outline (test)"** (sheet 4, 2026-10-17): the dark edge under the route
    //! ([MapRenderer.routeCasing]). Since v1.1.5 it is the default, and the setting serves to turn it off and
    //! compare on the wrist. Also outside `CONFIG`, and "Reset to default" turns it back on.
    const CASING = 5;

    //! **"Tilted map (test)"** (v1.1.5, sheet 8): the map flattened around the rider
    //! ([MapRenderer.tilt]). On by default; turning it off compares the `frame avg` of the two on the wrist.
    //! Outside `CONFIG`, and "Reset to default" turns it back on.
    const TILT = 6;

    function tiltLabel(on as Boolean) as String {
        return Tr.s(on ? Rez.Strings.On : Rez.Strings.Off);
    }

    //! Saves the tilted map setting. `persist` false is for the tests. Returns the new value.
    function setTilt(on as Boolean, persist as Boolean) as Boolean {
        if (persist) {
            try {
                Storage.setValue(MapRenderer.TILT_PREF, on);
            } catch (ex) {
                Diag.add("tilted map did not save to Storage");
            }
        }
        Diag.add("watch setting: tilted map " + (on ? "on" : "off"));
        return on;
    }

    function casingLabel(on as Boolean) as String {
        return Tr.s(on ? Rez.Strings.OnFem : Rez.Strings.OffFem);
    }

    //! Saves the edge setting. `persist` false is for the tests. Returns the new value.
    function setCasing(on as Boolean, persist as Boolean) as Boolean {
        if (persist) {
            try {
                Storage.setValue(MapRenderer.CASING_PREF, on);
            } catch (ex) {
                Diag.add("route casing did not save to Storage");
            }
        }
        Diag.add("watch setting: route casing " + (on ? "on" : "off"));
        return on;
    }

    function streetsLabel(on as Boolean) as String {
        return Tr.s(on ? Rez.Strings.OnTest : Rez.Strings.OffTest);
    }

    //! Saves the switch. `persist` false is for the tests. Returns the new value.
    function setStreets(on as Boolean, persist as Boolean) as Boolean {
        if (persist) {
            try {
                Storage.setValue(StreetCache.PREF, on);
            } catch (ex) {
                Diag.add("street images did not save to Storage");
            }
        }
        Diag.add("watch setting: street images " + (on ? "on" : "off"));
        return on;
    }

    //! The name of each row on the screen.
    function label(row as Number) as String {
        return Tr.s(([Rez.Strings.HudSize, Rez.Strings.Numbers, Rez.Strings.StreetBrightness] as Array<ResourceId>)[row]);
    }

    //! The `Config` keys the row changes together.
    function keys(row as Number) as Array<Number> {
        if (row == 0) {
            return [Config.KEY_HUD_PCT] as Array<Number>;
        }
        if (row == 1) {
            return [Config.KEY_DIST_PCT, Config.KEY_ETA_PCT] as Array<Number>;
        }
        return [Config.KEY_CORRIDOR_PCT] as Array<Number>;
    }

    //! The steps, in %. Within the `Config` ranges (63..102 for the HUD and the groups, 50..160
    //! for the streets); 100 is everyone's default. A choice, not a measurement.
    function options(row as Number) as Array<Number> {
        return row == 2 ? [70, 100, 130, 160] as Array<Number> : [70, 80, 90, 100] as Array<Number>;
    }

    //! The row's current value: that of the first key.
    function current(row as Number) as Number {
        return Config.values[(keys(row)[0] as Number) - 1] as Number;
    }

    //! Puts `value` in all the row's keys. `persist` false is for the tests.
    function apply(row as Number, value as Number, persist as Boolean) as Boolean {
        var ids = keys(row);
        var given = [] as Array<Number>;
        for (var i = 0; i < ids.size(); i++) {
            given.add(value);
        }
        return commit(ids, given, persist);
    }

    //! The three rows back to the `Config` default.
    function reset(persist as Boolean) as Boolean {
        var ids = [] as Array<Number>;
        var given = [] as Array<Number>;
        for (var row = 0; row < ROWS; row++) {
            var rowKeys = keys(row);
            for (var i = 0; i < rowKeys.size(); i++) {
                var id = rowKeys[i] as Number;
                ids.add(id);
                given.add(Config.DEFAULTS[id - 1] as Number);
            }
        }
        return commit(ids, given, persist);
    }

    function commit(ids as Array<Number>, given as Array<Number>, persist as Boolean) as Boolean {
        var next = Config.merge(ids, given);
        if (next == null) {
            return false;
        }
        Config.commit(next, ids, persist);
        var text = "watch setting:";
        for (var i = 0; i < ids.size(); i++) {
            text += " " + (Config.NAMES[(ids[i] as Number) - 1] as String) + "=" + (given[i] as Number).toString();
        }
        Diag.add(text);
        return true;
    }

    function percent(value as Number) as String {
        return value.toString() + "%";
    }
}

function pushQuickSettings() as Boolean {
    var menu = new WatchUi.Menu2({ :title => Rez.Strings.SettingsItem });
    for (var row = 0; row < QuickSettings.ROWS; row++) {
        menu.addItem(new WatchUi.MenuItem(QuickSettings.label(row),
            QuickSettings.percent(QuickSettings.current(row)), row, {}));
    }
    menu.addItem(new WatchUi.MenuItem(Rez.Strings.ResetDefaults, Rez.Strings.ResetHint, QuickSettings.RESET,
        {}));
    menu.addItem(new WatchUi.MenuItem(Rez.Strings.StreetImages,
        QuickSettings.streetsLabel(getApp().getMap().streetCache), QuickSettings.STREETS, {}));
    menu.addItem(new WatchUi.MenuItem(Rez.Strings.RouteCasing,
        QuickSettings.casingLabel(getApp().getMap().routeCasing), QuickSettings.CASING, {}));
    menu.addItem(new WatchUi.MenuItem(Rez.Strings.TiltMap,
        QuickSettings.tiltLabel(getApp().getMap().tilt), QuickSettings.TILT, {}));
    menu.addItem(new WatchUi.MenuItem(Rez.Strings.TheRest, Rez.Strings.OnThePhone, :none, {}));
    Diag.add("settings opened");
    WatchUi.pushView(menu, new QuickSettingsDelegate(menu), WatchUi.SLIDE_LEFT);
    return true;
}

class QuickSettingsDelegate extends WatchUi.Menu2InputDelegate {

    private var _menu as WatchUi.Menu2;

    function initialize(menu as WatchUi.Menu2) {
        Menu2InputDelegate.initialize();
        _menu = menu;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof Number)) {
            return;
        }
        var row = id as Number;
        if (row == QuickSettings.STREETS) {
            var map = getApp().getMap();
            var on = QuickSettings.setStreets(!map.streetCache, true);
            map.setStreetCache(on);
            item.setSubLabel(QuickSettings.streetsLabel(on));
            WatchUi.requestUpdate();
            return;
        }
        if (row == QuickSettings.CASING) {
            var map = getApp().getMap();
            map.routeCasing = QuickSettings.setCasing(!map.routeCasing, true);
            item.setSubLabel(QuickSettings.casingLabel(map.routeCasing));
            WatchUi.requestUpdate();
            return;
        }
        if (row == QuickSettings.TILT) {
            var map = getApp().getMap();
            map.tilt = QuickSettings.setTilt(!map.tilt, true);
            item.setSubLabel(QuickSettings.tiltLabel(map.tilt));
            WatchUi.requestUpdate();
            return;
        }
        if (row == QuickSettings.RESET) {
            var map = getApp().getMap();
            if (!map.routeCasing) {
                map.routeCasing = QuickSettings.setCasing(true, true);
                relabel(QuickSettings.CASING, QuickSettings.casingLabel(true));
            }
            if (!map.tilt) {
                map.tilt = QuickSettings.setTilt(true, true);
                relabel(QuickSettings.TILT, QuickSettings.tiltLabel(true));
            }
            if (QuickSettings.reset(true)) {
                for (var r = 0; r < QuickSettings.ROWS; r++) {
                    var line = _menu.getItem(r);
                    if (line != null) {
                        line.setSubLabel(QuickSettings.percent(QuickSettings.current(r)));
                    }
                }
                WatchUi.requestUpdate();
            }
            return;
        }
        var choices = new WatchUi.Menu2({ :title => QuickSettings.label(row) });
        var values = QuickSettings.options(row);
        var now = QuickSettings.current(row);
        var focus = 0;
        for (var i = 0; i < values.size(); i++) {
            var value = values[i] as Number;
            choices.addItem(new WatchUi.MenuItem(QuickSettings.percent(value),
                value == now ? Rez.Strings.CurrentValue : null, value, {}));
            if (value == now) {
                focus = i;
            }
        }
        choices.setFocus(focus);
        WatchUi.pushView(choices, new QuickChoiceDelegate(row, item), WatchUi.SLIDE_LEFT);
    }

    //! Changes the text below the menu row `id`, if it is there.
    private function relabel(id as Number, text as String) as Void {
        var at = _menu.findItemById(id);
        var line = at >= 0 ? _menu.getItem(at) : null;
        if (line != null) {
            line.setSubLabel(text);
        }
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

//! A chosen step: applies, updates the row above and goes back to it.
class QuickChoiceDelegate extends WatchUi.Menu2InputDelegate {

    private var _row as Number;
    private var _line as WatchUi.MenuItem;

    function initialize(row as Number, line as WatchUi.MenuItem) {
        Menu2InputDelegate.initialize();
        _row = row;
        _line = line;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id instanceof Number && QuickSettings.apply(_row, id as Number, true)) {
            _line.setSubLabel(QuickSettings.percent(id as Number));
        }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
