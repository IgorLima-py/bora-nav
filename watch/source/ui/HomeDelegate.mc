import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! Home screen input.
//! C12 (RF-02, `01 §Interaction`): the top button (SELECT/Enter) opens Favorites. ESC falls through to the
//! system and exits the app.
//! C16.5: tapping the three buttons on the screen opened Favorites, Recents or Settings.
//! Sheet 1 (2026-10-17, `docs/design/telas.md` §4.4): the four-item list. Enter opens the focused
//! item, which at the top is Favorites; dragging and the page buttons move the focus without wrapping around; a
//! tap on the card opens, and a tap on the neighbor above or below moves one step. The log stays on
//! long press (`onMenu`) and on the Link item.
//! `v1.2.1` (Igor, 2026-10-18: "the scroll [...] is kind of clunky and awkward, kind of slow and stiff"): the
//! list follows the finger ([onDrag]) and, on release, moves to the nearest item in the direction of the drag. The
//! swipe the system recognizes at the end of the same gesture does not move another step.
class HomeDelegate extends WatchUi.BehaviorDelegate {

    //! After a drag that moved the list, the swipe and the tap of the same gesture are swallowed
    //! in this window.
    const AFTER_DRAG_MS = 500;

    private var _view as HomeView;
    private var _dragY0 as Number = -1;
    private var _dragS0 as Float = 0.0;
    private var _dragMoved as Boolean = false;
    private var _dragAtMs as Number = 0;

    function initialize(view as HomeView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    //! **Consumes nothing** (C16, 2026-10-17 bench: "recents opens favorites, settings
    //! too"). On a touch device `onSelect` comes from the Enter button **and** from the touch
    //! (`CLICK_TYPE_TAP`), and comes before `onTap`: returning `true`, every tap opened Favorites and
    //! [onTap] never ran. The `BehaviorDelegate` doc (SDK 9.2.0): "If a BehaviorDelegate
    //! returns true for a function [...] the InputDelegate function that corresponds to the
    //! behavior will not be called". With `false`, the tap goes on to [onTap] and the key to
    //! [onKey].
    function onSelect() as Boolean {
        return false;
    }

    //! The top button (Enter) opens the focused item; with the list at the top, Favorites, as since C12.
    function onKey(event as WatchUi.KeyEvent) as Boolean {
        if (event.getKey() == WatchUi.KEY_ENTER) {
            return openFocused();
        }
        return false;
    }

    function onNextPage() as Boolean {
        if (!afterDrag()) {
            _view.move(1);
        }
        return true;
    }

    function onPreviousPage() as Boolean {
        if (!afterDrag()) {
            _view.move(-1);
        }
        return true;
    }

    //! A finger going up takes the list down (the next item), like the swipe. Up to
    //! [HomeList.DRAG_SLOP_PX] the gesture is a tap and goes on to [onTap].
    function onDrag(event as WatchUi.DragEvent) as Boolean {
        var y = event.getCoordinates()[1] as Number;
        var type = event.getType();
        if (type == WatchUi.DRAG_TYPE_START || _dragY0 < 0) {
            _dragY0 = y;
            _dragS0 = _view.position();
            _dragMoved = false;
            return false;
        }
        var dy = _dragY0 - y;
        if (_dragMoved || dy > HomeList.DRAG_SLOP_PX || dy < -HomeList.DRAG_SLOP_PX) {
            _dragMoved = true;
            _dragAtMs = System.getTimer();
            _view.dragTo(HomeList.rubber(_dragS0 + dy.toFloat() / HomeList.DRAG_PX));
        }
        if (type == WatchUi.DRAG_TYPE_STOP) {
            _dragY0 = -1;
            if (_dragMoved) {
                _view.release(_view.position() - _dragS0);
            }
        }
        return _dragMoved;
    }

    //! The same gesture that just dragged the list: its swipe and tap do not count.
    private function afterDrag() as Boolean {
        return _dragMoved && System.getTimer() - _dragAtMs < AFTER_DRAG_MS;
    }

    function onMenu() as Boolean {
        return pushLogView();
    }

    //! A tap outside the card and the neighbors goes to the system, as before.
    function onTap(event as WatchUi.ClickEvent) as Boolean {
        if (afterDrag()) {
            return true;
        }
        var at = event.getCoordinates();
        var hit = HomeList.hit(at[1] as Number);
        if (hit == HomeList.HIT_CARD) {
            return openFocused();
        }
        if (hit == HomeList.HIT_NEXT || hit == HomeList.HIT_PREVIOUS) {
            _view.move(hit);
            return true;
        }
        return false;
    }

    private function openFocused() as Boolean {
        var focus = _view.focus();
        if (focus == HomeList.RECENTS) {
            return pushRecents();
        }
        if (focus == HomeList.SETTINGS) {
            return pushQuickSettings();
        }
        if (focus == HomeList.LINK) {
            return pushLogView();
        }
        return pushFavorites();
    }
}
