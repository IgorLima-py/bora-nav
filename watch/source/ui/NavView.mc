import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

//! Main navigation screen: track-up map + HUD (`03 §Rendering`).
class NavView extends WatchUi.View {

    private var _route as RouteModel;
    private var _nav as NavState;
    private var _matcher as MapMatcher;
    private var _map as MapRenderer;
    private var _corridor as CorridorModel;
    private var _hud as Hud;
    //! The radar sign (C16.6), near one.
    private var _speed as SpeedHud;

    //! Cost of the **previous** frame, in ms. It is the previous one and not the current because the
    //! number only exists after the frame ends — and drawing the current
    //! frame's would require drawing twice to show one number.
    private var _frameMs as Number = 0;

    function initialize(
        route as RouteModel,
        nav as NavState,
        matcher as MapMatcher,
        map as MapRenderer,
        corridor as CorridorModel
    ) {
        View.initialize();
        _route = route;
        _nav = nav;
        _matcher = matcher;
        _map = map;
        _corridor = corridor;
        _hud = new Hud();
        _speed = new SpeedHud();

        // "A little corner I pull on the right, like a sliding menu": it is
        // exactly the Venu 4's **native action menu**. Turning on the indicator, the
        // system draws the tab on the right edge (the watch's personality marks
        // `system_loc__hint_action_menu` at (420, 174)) and starts delivering
        // `onActionMenu` to the delegate — with no gesture of ours competing with the pan.
        //
        // The `has` is mandatory: the API is 5.1.1 and the manifest declares minimum 5.0.0.
        // Wrapped in `try`: an exception in the view constructor happens in the middle of the
        // screen switch and leaves the app stuck where it was. The menu tab is
        // a convenience; the map screen is not.
        if (View has :setActionMenuIndicator) {
            try {
                View.setActionMenuIndicator({ :enabled => true });
            } catch (ex) {
                Diag.add("menu indicator refused");
            }
        }
    }

    function onUpdate(dc as Dc) as Void {
        var startedAt = System.getTimer();
        if (_nav.menuHoldsTheMap(startedAt)) {
            return;
        }
        _nav.tickBrowse(startedAt);
        _map.draw(dc, _route, _nav, _matcher, _corridor);

        var hudStart = System.getTimer();
        _hud.draw(dc, _route, _nav, _matcher);
        _speed.draw(dc, _nav, _matcher, _route);
        _map.msHud = System.getTimer() - hudStart;

        _frameMs = System.getTimer() - startedAt;
        _map.noteFrame(_frameMs);
        if (_map.wantsCatchUp()) {
            getApp().scheduleCatchUp();
        }
    }

    function getRenderer() as MapRenderer {
        return _map;
    }
}

//! Map controls (`01 §Interaction`): the up button cycles the zoom, dragging pans,
//! double tap recenters, swipe up opens Details, and the right tab
//! opens the actions menu. The other swipes and the flick do nothing (C16.5).
//!
//! **BACK exits the app, and only that.** The previous version turned BACK into
//! "End route?" and trapped Igor inside MotoNav: the confirmation switched the
//! screen from inside its own `onResponse`, its automatic pop undid the switch
//! right after, and the app went back to the map — from where the only way out was the
//! same BACK, again. Ending the route moved to the menu, which is where a
//! destructive action belongs; leaving the app is what the back button does in any
//! watch app, and that expectation is not to be contradicted.
class NavDelegate extends WatchUi.BehaviorDelegate {

    //! Two taps within this window count as a double tap — Connect IQ
    //! has no native double-tap gesture (`03 §Input`).
    const DOUBLE_TAP_MS = 400;

    private var _route as RouteModel;
    private var _nav as NavState;
    private var _map as MapRenderer;
    private var _lastTapMs as Number = 0;
    private var _dragX as Number = -1;
    private var _dragY as Number = -1;

    function initialize(route as RouteModel, nav as NavState, map as MapRenderer) {
        BehaviorDelegate.initialize();
        _route = route;
        _nav = nav;
        _map = map;
    }

    function onSelect() as Boolean {
        getApp().noteTouch();
        _nav.cycleZoom(System.getTimer());
        getApp().savePrefs();
        WatchUi.requestUpdate();
        return true;
    }

    function onTap(event as WatchUi.ClickEvent) as Boolean {
        getApp().noteTouch();
        var now = System.getTimer();
        if (now - _lastTapMs < DOUBLE_TAP_MS) {
            _nav.recenter();
            WatchUi.requestUpdate();
            _lastTapMs = 0;
            return true;
        }
        _lastTapMs = now;
        return false;
    }

    function onDrag(event as WatchUi.DragEvent) as Boolean {
        var coordinates = event.getCoordinates();
        var x = coordinates[0] as Number;
        var y = coordinates[1] as Number;

        if (event.getType() == WatchUi.DRAG_TYPE_START || _dragX < 0) {
            getApp().noteTouch();
            _dragX = x;
            _dragY = y;
            return true;
        }

        // The center moves opposite to the finger, so the map follows the drag.
        var world = _map.screenDeltaToWorld(x - _dragX, y - _dragY);
        _nav.pan(-(world[0] as Float), -(world[1] as Float), System.getTimer());
        _dragX = x;
        _dragY = y;

        if (event.getType() == WatchUi.DRAG_TYPE_STOP) {
            _dragX = -1;
            _dragY = -1;
        }
        WatchUi.requestUpdate();
        return true;
    }

    //! **No gesture on the map closes the app** (C16.5). In C16 Igor found that almost
    //! any touch closed the app, and the pinch too: the `BehaviorDelegate` reads the
    //! leftover swipe ("not handled") as BACK, and BACK on the map exits the app. Up
    //! still opens Details; the other swipes are consumed here. Leaving
    //! the app is the physical back button.
    function onSwipe(event as WatchUi.SwipeEvent) as Boolean {
        if (event.getDirection() == WatchUi.SWIPE_UP) {
            getApp().pushDetails();
        }
        return true;
    }

    //! The flick (the finger that slips, and the pinch, which Connect IQ has no gesture for
    //! and delivers as one of them) also does not become BACK.
    function onFlick(event as WatchUi.FlickEvent) as Boolean {
        return true;
    }

    //! The right tab. `onActionMenu` is what the native indicator fires.
    function onActionMenu() as Boolean {
        return showNavMenu(_nav);
    }

    //! The same thing through the classic path, in case the watch (or the
    //! simulator) delivers the gesture as MENU instead of the action menu.
    function onMenu() as Boolean {
        return showNavMenu(_nav);
    }
}

//! Builds and shows the map's actions menu.
//!
//! The zoom label is built on the spot because it **is** the state: an item that says
//! "Auto zoom" without saying whether it is on forces you to open the menu to
//! find out, which is the opposite of what works on a motorcycle.
function showNavMenu(nav as NavState) as Boolean {
    if (!(WatchUi has :showActionMenu)) {
        // With no action menu on the device, the action that cannot be missing is dropping the
        // route — without it the whole menu would be decorative.
        getApp().runMenuAction(:endRoute);
        return true;
    }

    var menu = new WatchUi.ActionMenu(null);
    menu.addItem(new WatchUi.ActionMenuItem({ :label => Rez.Strings.MenuEndRoute }, :endRoute));
    menu.addItem(new WatchUi.ActionMenuItem(
        { :label => nav.autoZoom ? Rez.Strings.MenuZoomFixed : Rez.Strings.MenuZoomAuto },
        :toggleAutoZoom
    ));
    menu.addItem(new WatchUi.ActionMenuItem({ :label => Rez.Strings.MenuRecenter }, :recenter));
    menu.addItem(new WatchUi.ActionMenuItem({ :label => Rez.Strings.MenuDetails }, :details));
    menu.addItem(new WatchUi.ActionMenuItem({ :label => Rez.Strings.MenuLog }, :log));
    // C16.5: removed "Tela acesa (gravar)" (keep screen on) from C9. It did not hold the screen on the C16 bench, and the
    // `Fit` permission it asked for put the app in the activities list instead of the apps one.
    // The virtual bike rides the route that arrived from the phone (C3b): at the desk, without GPS.
    menu.addItem(new WatchUi.ActionMenuItem(
        { :label => getApp().isReplaying() ? Rez.Strings.MenuSimulateStop : Rez.Strings.MenuSimulate },
        :simulate
    ));

    nav.menuOpened(System.getTimer());
    WatchUi.showActionMenu(menu, new NavMenuDelegate(nav));
    return true;
}

//! Actions menu responses.
//!
//! Recenter and zoom are pure state and can run right here. **Switching screens
//! cannot**: the action menu dismisses itself *after* this callback, and its
//! pop would swallow the view stacked here — exactly that chain
//! trapped Igor in the app on `v0.9.0-f2`. That is why these actions go to a
//! short timer, in the app (`MotoNavApp.runMenuAction`).
class NavMenuDelegate extends WatchUi.ActionMenuDelegate {

    private var _nav as NavState;

    function initialize(nav as NavState) {
        ActionMenuDelegate.initialize();
        _nav = nav;
    }

    function onBack() as Void {
        _nav.menuClosed();
        WatchUi.requestUpdate();
    }

    function onSelect(menuItem as WatchUi.ActionMenuItem) as Void {
        _nav.menuClosed();
        WatchUi.requestUpdate();
        var id = menuItem.getId();

        if (id == :recenter) {
            _nav.recenter();
            WatchUi.requestUpdate();
            return;
        }
        if (id == :toggleAutoZoom) {
            _nav.setAutoZoom(!_nav.autoZoom);
            getApp().savePrefs();
            Diag.add("zoom " + (_nav.autoZoom ? "auto" : "fixed"));
            WatchUi.requestUpdate();
            return;
        }
        if (id == :endRoute || id == :details || id == :log || id == :simulate) {
            getApp().runMenuAction(id as Symbol);
        }
    }
}

//! Details (C9, `01 §Watch screens`): the next maneuvers, the route
//! totals, the battery and the end button. The content comes from [DetailsModel]; this
//! class only draws it. Text screen: pure black background, no map.
class DetailsView extends WatchUi.View {

    private var _route as RouteModel;
    private var _matcher as MapMatcher;
    private var _confirm as EndConfirm;

    function initialize(route as RouteModel, matcher as MapMatcher, confirm as EndConfirm) {
        View.initialize();
        _route = route;
        _matcher = matcher;
        _confirm = confirm;
    }

    function onUpdate(dc as Dc) as Void {
        var cx = dc.getWidth() / 2;
        var armed = _confirm.isArmed(System.getTimer());
        var model = new DetailsModel(_route, _matcher, System.getSystemStats().battery, armed);

        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_BLACK);
        dc.clear();

        // Destination, truncated by the screen chord at that height.
        dc.setColor(DesignTokens.SECONDARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 52, Graphics.FONT_XTINY, fit(dc, model.destination, 52, Graphics.FONT_XTINY),
            Graphics.TEXT_JUSTIFY_CENTER);

        // The next maneuvers: the first highlighted, the others in the secondary tone.
        var y = 92;
        for (var i = 0; i < model.upcoming.size(); i++) {
            dc.setColor(i == 0 ? DesignTokens.PRIMARY : DesignTokens.SECONDARY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, y, Graphics.FONT_XTINY,
                fit(dc, model.upcoming[i] as String, y, Graphics.FONT_XTINY), Graphics.TEXT_JUSTIFY_CENTER);
            y += 34;
        }

        // Route totals, what is left and the battery.
        dc.setColor(DesignTokens.PRIMARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 206, Graphics.FONT_TINY, model.total, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(DesignTokens.SECONDARY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 252, Graphics.FONT_XTINY, model.left, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, 284, Graphics.FONT_XTINY, model.battery, Graphics.TEXT_JUSTIFY_CENTER);

        // The button: amber when armed, so the second tap is not blind.
        var left = DetailsModel.BTN_LEFT;
        var top = DetailsModel.BTN_TOP;
        var width = DetailsModel.BTN_RIGHT - DetailsModel.BTN_LEFT;
        var height = DetailsModel.BTN_BOTTOM - DetailsModel.BTN_TOP;
        dc.setColor(armed ? DesignTokens.URGENT : 0x333333, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(left, top, width, height, DesignTokens.CARD_RADIUS);
        dc.setColor(armed ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, top + (height - dc.getFontHeight(Graphics.FONT_XTINY)) / 2, Graphics.FONT_XTINY,
            model.endLabel, Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! Cuts the text by the round screen's chord at that height (`y` is the top of the
    //! line; it is measured at its middle).
    private function fit(dc as Dc, text as String, y as Number, font) as String {
        var mid = y + dc.getFontHeight(font) / 2;
        var dy = mid - 227;
        var squared = 227 * 227 - dy * dy;
        var maxWidth = (squared > 0 ? Math.sqrt(squared.toFloat()).toNumber() : 0) * 2 - 24;
        if (dc.getTextWidthInPixels(text, font) <= maxWidth) {
            return text;
        }
        var keep = text.length();
        while (keep > 1 && dc.getTextWidthInPixels(text.substring(0, keep) + "…", font) > maxWidth) {
            keep--;
        }
        return text.substring(0, keep) + "…";
    }
}

//! Details controls: BACK or swipe down go back to the map; the
//! "End route" button asks for **two taps** (see [EndConfirm]).
class DetailsDelegate extends WatchUi.BehaviorDelegate {

    private var _confirm as EndConfirm;

    function initialize(confirm as EndConfirm) {
        BehaviorDelegate.initialize();
        _confirm = confirm;
    }

    function onTap(event as WatchUi.ClickEvent) as Boolean {
        var coordinates = event.getCoordinates();
        if (!DetailsModel.hitsEnd(coordinates[0] as Number, coordinates[1] as Number)) {
            return false;
        }
        if (_confirm.tap(System.getTimer())) {
            // Leaves Details before ending: `endRoute` replaces the screen that
            // is on top, and with Details on top the map would end up under
            // the home screen. The action runs 100 ms later, on the app's timer.
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            getApp().runMenuAction(:endRoute);
        } else {
            WatchUi.requestUpdate();
        }
        return true;
    }

    function onSwipe(event as WatchUi.SwipeEvent) as Boolean {
        if (event.getDirection() == WatchUi.SWIPE_DOWN) {
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            return true;
        }
        return false;
    }

    function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        return true;
    }
}
