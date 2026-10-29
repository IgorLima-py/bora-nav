import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.Timer;
import Toybox.WatchUi;

//! MotoNav watch app entry point.
//! F1: receives the route from the companion. F2: projects, matches with the GPS and draws the
//! track-up map. Turn-by-turn and vibration are F3.
class MotoNavApp extends Application.AppBase {

    private var _route as RouteModel;
    private var _link as PhoneLink;
    private var _assembler as MessageAssembler;
    private var _nav as NavState;
    private var _matcher as MapMatcher;
    private var _map as MapRenderer;
    private var _alerts as AlertPolicy;
    private var _track as TrackBuffer;
    private var _gap as FixGap;
    private var _offRoute as OffRoute;
    private var _fallback as FixFallback;
    private var _favoriteAsk as FavoriteAsk;
    //! The deadline for the app left open after arrival (C16.5).
    private var _arrivalExit as ArrivalExit;
    //! The GPS gap drill (C16, the rides of 2026-10-19 and 20).
    private var _gpsDrill as GpsDrill;
    private var _replay as ReplayRunner? = null;

    //! The phase navigation was in when the simulation started: it is the one it returns to
    //! when it ends (see [stopReplay]).
    private var _phaseBeforeReplay as Number = NavPhase.IDLE;
    private var _timer as Timer.Timer?;
    //! The screen waiting for the rest of a new route ([showWait]): none, the
    //! home screen with the spinning ring, or the `DebugView` with the error of a refused
    //! message. With one of them up, the map is gone and `showNav` switches screens.
    const WAIT_NONE = 0;
    const WAIT_HOME = 1;
    const WAIT_DEBUG = 2;
    // The literal, and not WAIT_NONE: Monkey C does not initialize a field with a class constant.
    private var _waitShown as Number = 0;
    private var _navShown as Boolean = false;
    private var _gpsOn as Boolean = false;
    private var _replayActive as Boolean = false;

    //! Which route has already been built on the map screen. `-1` = none. See [showNav].
    private var _shownRouteId as Number = -1;

    //! The last good fix, in E5 (what the GPS gave, not the local plane): the position
    //! of the recalculation request, and what [showNav] reprojects when the route changes
    //! while the rider is moving (C11). Only valid with [_hasLastFix].
    private var _hasLastFix as Boolean = false;
    private var _lastLatE5 as Number = 0;
    private var _lastLonE5 as Number = 0;

    //! Where the last fix that moved the map came from ([FixSource]). Whoever calls
    //! [applyFix] sets `fixSource` first, and a weak fix moves nothing: without
    //! this a weak fix from the watch switched the origin in the telemetry to `gps`
    //! with the position still being the phone's (C13b).
    private var _appliedSource as Number = FixSource.NONE;

    //! Menu action waiting for the menu to leave the screen (see [runMenuAction]).
    private var _pendingAction as Symbol? = null;
    private var _actionTimer as Timer.Timer?;

    //! **Extra frames and slices while there is pending screen work** (C16, bench of
    //! 2026-10-17: "the streets take a while to show up, every time the zoom changes it seems to
    //! reset"). While navigating, the frame comes from the GPS at 1 Hz and the corridor slices come from the 1 s tick:
    //! the street list of a new zoom, and reading a corridor of ~4,000 points in slices of
    //! 450, took seconds. While the sweep of a new zoom or corridor is open
    //! ([MapRenderer.wantsCatchUp]), or there is POLY or corridor left to read, a one-shot timer asks for
    //! the next step after [CATCHUP_MS]. The watchdog is per callback and each step stays
    //! the same size; what changes is how many fit in a second. It is the app's third timer, the ceiling
    //! that the `Timer` doc gives ("The number of available timers (default 3)", SDK 9.2.0).
    private var _catchUpTimer as Timer.Timer?;
    private var _catchUpArmed as Boolean = false;
    //! A choice, not a measurement: the map frame costs 118 to 177 ms on the wrist (bench of 2026-10-17),
    //! so 100 ms of slack gives about four steps per second instead of one.
    const CATCHUP_MS = 100;

    //! `prefs` keys from `03 §Storage`.
    const PREF_ZOOM_INDEX = "zoomIndex";
    const PREF_AUTO_ZOOM = "autoZoom";

    //! Seconds of navigation between one telemetry line and the next, and between
    //! one log send to the phone and the next. See [sendTelemetry].
    const TELEMETRY_EVERY_S = 10;
    //! 15 s, not 30: the telemetry (~170 characters) and the frame summary go out every
    //! 10 s, and at 30 s the diagnostic went past the send's character ceiling and the 24-line
    //! ring started losing lines on a 10 min ride (finding of the C3b
    //! reviewer, measured in the ride log).
    const LOG_FLUSH_EVERY_S = 15;

    private var _ticks as Number = 0;

    function initialize() {
        AppBase.initialize();
        Screen.init();
        _route = new RouteModel();
        _link = new PhoneLink();
        _assembler = new MessageAssembler(_route, _link);
        _nav = new NavState();
        _matcher = new MapMatcher(_route);
        _map = new MapRenderer();
        _alerts = new AlertPolicy();
        _track = new TrackBuffer();
        _gap = new FixGap();
        _offRoute = new OffRoute();
        _fallback = new FixFallback();
        _favoriteAsk = new FavoriteAsk();
        _arrivalExit = new ArrivalExit();
        _gpsDrill = new GpsDrill();
        _link.track = _track;
        _assembler.nav = _nav;
    }

    function onStart(state as Dictionary?) as Void {
        Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
        // A message the system refused before it reached `onPhoneMessage`
        // (full queue, a format CIQ does not deliver) was invisible: from the
        // watch's side, identical to no message. API 6.0.0, hence the `has`.
        if (Communications has :registerForPhoneAppMessageErrors) {
            Communications.registerForPhoneAppMessageErrors(method(:onPhoneMessageError));
        }
        // Leftover route/corridor from an old Storage design (C14).
        StorageCleanup.dropOldRoutes();
        // The fine tuning (C5) before the preferences: the initial zoom comes from it.
        Config.restore();
        // The favorites (C12) and the recents (C16.5): the screen works before the phone speaks.
        Favorites.restore();
        Recents.restore();
        loadPrefs();
        Diag.add("start " + AppVersion.LABEL);
        var timer = new Timer.Timer();
        timer.start(method(:onTick), 1000, true);
        _timer = timer;
        // Empty in the real app; in the simulator demo build
        // (`watch/demo.jungle`), it injects São Paulo through `onPhoneData`.
        demoStart();
    }

    function onStop(state as Dictionary?) as Void {
        var timer = _timer;
        if (timer != null) {
            timer.stop();
            _timer = null;
        }
        var action = _actionTimer;
        if (action != null) {
            action.stop();
            _actionTimer = null;
        }
        var catchUp = _catchUpTimer;
        if (catchUp != null) {
            catchUp.stop();
            _catchUpTimer = null;
            _catchUpArmed = false;
        }
        stopReplay("app closed");
        stopGps();
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        var home = new HomeView();
        return [home, new HomeDelegate(home)];
    }

    function getAssembler() as MessageAssembler {
        return _assembler;
    }

    //! The map drawer. For the screens demo (`watch/demo/shots`), which pins the leash.
    function getMap() as MapRenderer {
        return _map;
    }

    function getFavoriteAsk() as FavoriteAsk {
        return _favoriteAsk;
    }

    //! The rider picked a favorite on the Favorites screen (RF-02, C12): asks the phone
    //! for the route by `favId`. The answer is a new route (`showNav` clears the
    //! request); without it, the Home screen says the phone is not responding.
    function startFavorite(favId as Number) as Void {
        var index = Favorites.indexOfId(favId);
        if (index < 0) {
            Diag.add("favorite " + favId.toString() + " not in the list");
            return;
        }
        _favoriteAsk.start(favId, Favorites.labelAt(index), System.getTimer());
        _link.sendNavStartReq(favId);
        WatchUi.requestUpdate();
    }

    //! Igor picked a destination from "Recentes" (C16.5): the same request as the favorite, with
    //! `kind` 1. The wait on the home screen is the same ([FavoriteAsk]).
    function startRecent(id as Number) as Void {
        var index = Recents.indexOfId(id);
        if (index < 0) {
            Diag.add("recent " + id.toString() + " not in the list");
            return;
        }
        _favoriteAsk.start(id, Recents.labelAt(index), System.getTimer());
        _link.sendRecentStartReq(id);
        WatchUi.requestUpdate();
    }

    function getRoute() as RouteModel {
        return _route;
    }

    function getNav() as NavState {
        return _nav;
    }

    function getMatcher() as MapMatcher {
        return _matcher;
    }

    function getTrack() as TrackBuffer {
        return _track;
    }

    //! Called by Connect IQ whenever the companion sends a message.
    function onPhoneMessage(message as Communications.PhoneAppMessage) as Void {
        // Only in the bridge build (`watch/ponte.jungle`); in the real app it is `false`.
        if (bridgeMessage(message.data)) {
            return;
        }
        onPhoneData(message.data);
    }

    function onPhoneMessageError(error as Communications.PhoneAppMessageError) as Void {
        _assembler.rawMessages++;
        Diag.add("rx error " + error.toString());
    }

    //! The body of `onPhoneMessage`, at the data level: this is where the simulator's
    //! `DemoFeed` comes in, with the same Base64 String the phone sends, so
    //! `PhoneData.decode`, the assembler and `showNav` run for real.
    function onPhoneData(data as Object?) as Void {
        // Counts before trying to read: a message in an unexpected format used to be
        // invisible here, indistinguishable from no message.
        _assembler.rawMessages++;
        var shape = PhoneData.describe(data);
        var bytes = PhoneData.decode(data);
        // PHONE_FIX (C13b) arrives once a second: it goes without the `rx` line, for the same
        // reason it goes without the `blk` one in the assembler (Diag's ring has 24 lines).
        var isPhoneFix = bytes != null && bytes.size() > 1 && (bytes[1] as Number) == Protocol.MSG_PHONE_FIX;
        if (bytes == null) {
            _assembler.lastError = "could not read " + shape;
            Diag.add("rx " + shape + " UNREADABLE");
        } else {
            if (!isPhoneFix) {
                Diag.add("rx " + shape + " -> " + bytes.size().toString() + "B");
            }
            _assembler.onData(bytes);
        }
        if (hasPendingJobs()) {
            scheduleCatchUp();
        }

        // Not a route, nor the refused one: never switches screens nor goes through `showNav`.
        if (isPhoneFix) {
            var phoneFix = _assembler.phoneFix;
            if (_assembler.lastWasPhoneFix && phoneFix != null) {
                applyPhoneFix(phoneFix);
            }
            return;
        }

        // Favorites (C12): not a route either; the Home screen just rebuilds.
        if (_assembler.lastWasFavorites) {
            WatchUi.requestUpdate();
            return;
        }

        // Fine tuning (C5): not a route, so it does not switch screens — it only redraws,
        // and the zoom changes right away if the message brought the zoom.
        if (_assembler.lastWasConfig) {
            if (Config.lastKeys.indexOf(Config.KEY_ZOOM) >= 0) {
                _nav.setZoomIndex(Config.zoomIndex());
                _nav.ridingZoomIndex = Config.zoomIndex();
                savePrefs();
            }
            applyMapSwitches();
            WatchUi.requestUpdate();
            return;
        }

        // ROUTE_UPDATE (C13a): only the ETA changed. It does not go through `showNav`: with the
        // route still loaded after arrival, it would turn navigation and the GPS back on.
        if (_assembler.lastWasRouteUpdate) {
            WatchUi.requestUpdate();
            return;
        }

        if (_route.isComplete()) {
            showNav();
            return;
        }
        if (bytes != null && _assembler.lastWasRouteBlock) {
            // New route half-received (C16): the home screen with the spinning ring, until the
            // path and the turns arrive. It used to be the F1 `DebugView`, and its numbers
            // showed up for about 3 s on every route (`DECISIONS.md` §2026-10-21).
            _favoriteAsk.noteRouteChunk(System.getTimer());
            showWait(WAIT_HOME);
        } else {
            // Refused or unreadable, with the route half-received: the `DebugView` puts the
            // error on the screen (`lastError`; the `protoVersion` of a newer phone),
            // which is where it is useful.
            showWait(WAIT_DEBUG);
        }
    }

    //! Takes the map off and puts up the wait screen for the new route, if it is not already
    //! up. Without zeroing `_navShown`, the `showNav` at the end of the new route would think the
    //! map was still up and only call `requestUpdate`, leaving the wait
    //! screen forever.
    private function showWait(screen as Number) as Void {
        if (_waitShown == screen) {
            WatchUi.requestUpdate();
            return;
        }
        _waitShown = screen;
        _navShown = false;
        if (screen == WAIT_DEBUG) {
            WatchUi.switchToView(new DebugView(_assembler), new DebugDelegate(), WatchUi.SLIDE_IMMEDIATE);
        } else {
            var home = new HomeView();
            WatchUi.switchToView(home, new HomeDelegate(home), WatchUi.SLIDE_IMMEDIATE);
        }
    }

    //! **The map switches through `CONFIG` (C16):** keys 17 to 19 that came from the phone
    //! rewrite the preferences that the watch menu writes and change the map right away, without ending the
    //! route. Only the keys that came: an empty `CONFIG` brings all of them and puts the three back to default (on).
    private function applyMapSwitches() as Void {
        var keys = Config.lastKeys;
        if (keys.indexOf(Config.KEY_STREET_IMG) >= 0) {
            var on = QuickSettings.setStreets(Config.streetImage(), true);
            _map.setStreetCache(on);
        }
        if (keys.indexOf(Config.KEY_MAP_TILT) >= 0) {
            _map.tilt = QuickSettings.setTilt(Config.mapTilt(), true);
        }
        if (keys.indexOf(Config.KEY_STREET_16BIT) >= 0) {
            var sixteen = Config.street16Bit();
            try {
                Storage.setValue(StreetCache.PREF_16BIT, sixteen);
            } catch (ex) {
                Diag.add("16-bit image not saved to Storage");
            }
            _map.setStreet16Bit(sixteen);
        }
        if (keys.indexOf(Config.KEY_STREET_DIAG) >= 0) {
            var lever = Config.streetDiag();
            if (lever != _map.streets().diag) {
                Diag.add("streets diagnostics: " + lever.toString() + " "
                    + (StreetCache.DIAG_NAMES[lever] as String));
            }
            _map.setStreetDiag(lever);
        }
    }

    //! Complete route: map on the screen and GPS on. Applies both to the first route
    //! and to a route swap midway.
    //!
    //! **The reset is per route, not per message.** Every CORRIDOR block that
    //! arrives *after* the route also lands here, because `isComplete()` stays
    //! true — and the previous version zeroed the map-matching and discarded the fix
    //! on every one of them. In practice, the map went back to the start of the route for one
    //! second on every corridor chunk, which is precisely when the corridor
    //! started to exist. Hence the comparison with [_shownRouteId].
    private function showNav() as Void {
        // The route the phone sent is the answer to the favorite request, if there was one.
        _favoriteAsk.clear();
        if (_route.routeId != _shownRouteId) {
            _shownRouteId = _route.routeId;
            _arrivalExit.reset();
            var last = _route.lats.size() - 1;
            if (last >= 0) {
                // C16.5: same destination is a recalculation, and the arrival delta carries on against the earlier plan.
                _nav.beginTrip(_route.lats[last] as Number, _route.lons[last] as Number);
            }
            _matcher.reset();
            _alerts.reset();
            _gap.reset();
            resetOffRoute();
            if (_nav.phase == NavPhase.NAVIGATING && _nav.hasFix && _hasLastFix) {
                // Swap with the rider moving (recalculation, C11): the fix they
                // just gave is still valid, only the local plane changed. It is
                // reprojected and matched to the new route right away, without waiting for the
                // next one: discarding it erased the arrow and put "no GPS" on the screen
                // on every recalculation.
                var x = Projection.toLocalX(_lastLonE5, _route.lon0, _route.lonScale);
                var y = Projection.toLocalY(_lastLatE5, _route.lat0);
                _nav.rebase(x, y);
                _matcher.update(x, y);
            } else {
                // First route, or new route after arrival: the old fix
                // is in the previous route's plane and may be hours old. Discard and
                // recenter on what the watch already knows.
                _nav.invalidateFix();
                _hasLastFix = false;

                // **Nothing here may keep the map from showing up.** Centering on the last
                // known position is comfort, not a requirement: `Position.getInfo()`
                // is a system call and an exception from it, before the line that
                // marks the phase as navigating, left the app stuck on the transfer
                // screen — no map, no telemetry and no way
                // of knowing it from the phone's side (`05 §Robustness rules 3`).
                try {
                    seedFromLastKnown();
                } catch (ex) {
                    Diag.add("seedFromLastKnown failed");
                }
            }
            // The virtual ride walks the route that is in force: on the swap, it restarts
            // on the new one (which starts from where the motorcycle was when it asked).
            var replay = _replay;
            if (replay != null) {
                replay.rebind(_route);
            }
        }
        if (_nav.phase != NavPhase.NAVIGATING) {
            // New trip. The recalculation arrives with the phase already navigating and does not re-arm the drill.
            _gpsDrill.begin(Clock.nowMs());
        }
        _nav.phase = NavPhase.NAVIGATING;

        try {
            startGps();
        } catch (ex) {
            Diag.add("startGps failed");
        }

        if (_navShown) {
            WatchUi.requestUpdate();
            return;
        }
        _navShown = true;
        _waitShown = WAIT_NONE;
        Diag.add("map on");
        WatchUi.switchToView(
            new NavView(_route, _nav, _matcher, _map, _assembler.getCorridor()),
            new NavDelegate(_route, _nav, _map),
            WatchUi.SLIDE_IMMEDIATE
        );
    }

    //! "End route" from the right-hand menu: drops the route, turns off the GPS and goes back
    //! to the home screen, ready to receive the next one.
    function endRoute() as Void {
        stopReplay("route ended"); // lang: log
        logTrackSummary();
        stopGps();
        if (_nav.phase == NavPhase.NAVIGATING) {
            _link.sendNavEnded(_route.routeId, Protocol.NAV_ENDED_CANCELLED);
        }
        _route.clear();
        _assembler.cancelRouteJobs();
        _assembler.getCorridor().clear();
        _matcher.reset();
        _alerts.reset();
        _gap.reset();
        resetOffRoute();
        _nav.invalidateFix();
        _nav.endTrip();
        _gpsDrill.end();
        _arrivalExit.reset();
        _hasLastFix = false;
        _nav.phase = NavPhase.IDLE;
        _navShown = false;
        _waitShown = WAIT_NONE;
        _shownRouteId = -1;
        Diag.add("route ended by user");
        var home = new HomeView();
        WatchUi.switchToView(home, new HomeDelegate(home), WatchUi.SLIDE_IMMEDIATE);
    }

    //! Runs a menu action **after** the menu has left the screen.
    //!
    //! A `switchToView`/`pushView` called from inside the menu callback does not
    //! survive: the menu (or the confirmation) dismisses itself right afterwards
    //! and its pop takes along the view that was just pushed. That is how
    //! the "End route?" of `v0.9.0-f2` became a trap — it ended the route and
    //! returned the rider to the map, from where the only way out was the same button.
    //! 100 ms is enough slack for the menu animation to finish.
    function runMenuAction(action as Symbol) as Void {
        _pendingAction = action;
        var timer = new Timer.Timer();
        timer.start(method(:onMenuAction), 100, false);
        _actionTimer = timer;
    }

    function onMenuAction() as Void {
        var action = _pendingAction;
        _pendingAction = null;
        _actionTimer = null;

        if (action == :endRoute) {
            endRoute();
        } else if (action == :details) {
            pushDetails();
        } else if (action == :log) {
            pushLogView();
        } else if (action == :simulate) {
            if (_replay != null) {
                stopReplay("stopped from menu");
            } else {
                startReplay();
            }
        }
    }

    //! The rider touched the map: the deadline for the app left open after arrival restarts (C16.5).
    function noteTouch() as Void {
        _arrivalExit.touched(Clock.nowMs());
    }

    //! Opens Details on top of the map (swipe up or menu item).
    function pushDetails() as Void {
        var confirm = new EndConfirm();
        WatchUi.pushView(
            new DetailsView(_route, _matcher, confirm),
            new DetailsDelegate(confirm),
            WatchUi.SLIDE_UP
        );
    }

    //! The chosen zoom and the zoom mode survive closing the app: they are the rider's
    //! preference, not route state (`03 §Storage`, key `prefs`).
    private function loadPrefs() as Void {
        // With no saved zoom, the initial one is that of the fine tuning (`Config`, C5).
        var level = Config.zoomIndex();
        var zoom = Storage.getValue(PREF_ZOOM_INDEX);
        // **A lookup level is not a preference.** 10 and 20 m/px exist to
        // look at the whole route for a few seconds; saving them between sessions
        // is like opening the app with the map already wrong. Igor's watch opened
        // like that during the whole 2026-08-01 session (`zoom 20.0` in the log), and
        // nothing on the screen said why.
        if (zoom instanceof Number && zoom >= 0 && zoom < _nav.BROWSE_ZOOM_INDEX) {
            level = zoom;
        }
        _nav.setZoomIndex(level);
        _nav.ridingZoomIndex = level;
        var auto = Storage.getValue(PREF_AUTO_ZOOM);
        if (auto instanceof Boolean) {
            _nav.autoZoom = auto;
        }
        // The streets as an image (2026-10-17): on, unless the Settings switch says otherwise.
        _map.setStreetCache(StreetCache.wanted());
        // The streets as tiles (v1.2.9) in the normal drawing, in place of the single 640 px image.
        _map.useStreetGrid();
        // The diagnostic lever (v1.2.5) comes from the saved `CONFIG`, like the rest of the adjustment.
        _map.setStreetDiag(Config.streetDiag());
        _map.setStreet16Bit(StreetCache.wants16Bit());
        // The route border and the tilted map (v1.1.5, sheet 8): on, unless the test
        // settings say otherwise.
        _map.routeCasing = MapRenderer.casingWanted();
        _map.tilt = MapRenderer.tiltWanted();
    }

    function savePrefs() as Void {
        Storage.setValue(PREF_ZOOM_INDEX, _nav.zoomIndex);
        Storage.setValue(PREF_AUTO_ZOOM, _nav.autoZoom);
    }

    //! Centers the map on the last position the watch saved, while the
    //! session's first fix has not arrived. Costs nothing and avoids the screen Igor
    //! saw in the first test: the whole path drawn from the route's
    //! origin, with no reference of where he was.
    private function seedFromLastKnown() as Void {
        var location = Position.getInfo().position;
        if (location == null) {
            return;
        }
        var degrees = location.toDegrees();
        _nav.seedCentre(
            Projection.toLocalX(Projection.degreesToE5(degrees[1] as Double), _route.lon0, _route.lonScale),
            Projection.toLocalY(Projection.degreesToE5(degrees[0] as Double), _route.lat0)
        );
        Diag.add("center on last known pos");
    }

    //! Turns the GPS on asking for the **best constellation the watch accepts**.
    //!
    //! `enableLocationEvents(LOCATION_CONTINUOUS, ...)` — the old form, which
    //! was here — uses `CONSTELLATION_GPS` by default, that is, **plain L1 GPS**.
    //! It does not inherit the GNSS mode chosen in the watch menu: that setting
    //! applies to Garmin's native activities, not to Connect IQ apps.
    //! For a navigation app in the city that is the worst possible choice, so
    //! here the cascade asks for multiband (L1+L5, which rejects the signal
    //! reflected off buildings), then all systems on L1, then SatIQ.
    //! `DECISIONS.md` §GNSS constellations.
    private function startGps() as Void {
        if (_gpsOn) {
            return;
        }
        _gpsOn = true;

        var options = { :acquisitionType => Position.LOCATION_CONTINUOUS };
        var label = "GPS L1 (default)";

        if (Position has :hasConfigurationSupport) {
            if ((Position has :CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5)
                    && Position.hasConfigurationSupport(Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5)) {
                options[:configuration] = Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5;
                label = "multiband L1+L5";
            } else if ((Position has :CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1)
                    && Position.hasConfigurationSupport(Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1)) {
                options[:configuration] = Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1;
                label = "all systems L1";
            } else if ((Position has :CONFIGURATION_SAT_IQ)
                    && Position.hasConfigurationSupport(Position.CONFIGURATION_SAT_IQ)) {
                options[:configuration] = Position.CONFIGURATION_SAT_IQ;
                label = "SatIQ";
            }
        }

        // A refused combination cannot bring navigation down: the simple mode
        // always exists, and the log says which of the two the app ended up in.
        try {
            Position.enableLocationEvents(options, method(:onPosition));
        } catch (ex) {
            Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
            label = "GPS L1 (config refused)";
        }
        Diag.add("gps " + label);
    }

    //! Outside navigation the GPS stays off (`03 §GPS`) — it is the app's biggest
    //! battery consumer.
    private function stopGps() as Void {
        if (!_gpsOn) {
            return;
        }
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
        _gpsOn = false;
    }

    //! ~1 Hz. Only translates the `Position.Info` to [applyFix]; during the virtual
    //! ride the real GPS stays mute, so as not to compete with it for the position.
    function onPosition(info as Position.Info) as Void {
        var location = info.position;
        if (location == null || _replayActive) {
            return;
        }

        var degrees = location.toDegrees();
        var speed = info.speed;
        var quality = info.accuracy as Number?;
        if (_nav.phase == NavPhase.NAVIGATING) {
            // The C16 drill: while it pretends, the fix comes in like a tunnel's.
            var drill = _gpsDrill.poll(Clock.nowMs(), Config.gpsDrillMin());
            if (drill == GpsDrill.EVENT_START) {
                Diag.add("gps drill: the watch fakes no gps for " + (_gpsDrill.LENGTH_MS / 1000).toString() + "s");
            } else if (drill == GpsDrill.EVENT_END) {
                Diag.add("gps drill: end, the watch gps is back");
            }
            if (_gpsDrill.muting) {
                quality = null;
            }
        }
        _nav.fixSource = FixSource.GPS;
        applyFix(
            Projection.degreesToE5(degrees[0] as Double),
            Projection.degreesToE5(degrees[1] as Double),
            speed != null ? (speed as Float) : 0.0,
            info.heading as Float?,
            quality
        );
    }

    //! The virtual ride (C3a) turns this on while it injects its fixes.
    function setReplayActive(active as Boolean) as Void {
        _replayActive = active;
    }

    function isReplaying() as Boolean {
        return _replay != null;
    }

    //! "Simular trajeto" from the menu: the virtual motorcycle walks, in real time, the route that
    //! came from the phone, through the same `applyFix` as the GPS, with the real GPS
    //! mute. It serves to see the map, the arrow and the warnings at the desk, without leaving home.
    //! Restarts from the start of the route, even if the rider has already arrived.
    function startReplay() as Void {
        if (_replay != null) {
            return;
        }
        if (!_route.isComplete() || _nav.phase == NavPhase.IDLE || _nav.phase == NavPhase.RECEIVING) {
            Diag.add("simulation: no route");
            return;
        }
        _phaseBeforeReplay = _nav.phase;
        _nav.endTrip();
        _matcher.reset();
        _alerts.reset();
        _gap.reset();
        resetOffRoute();
        _nav.invalidateFix();
        _hasLastFix = false;
        _nav.phase = NavPhase.NAVIGATING;
        _replay = new ReplayRunner(_route, ReplayProfile.standard(), false);
        _replayActive = true;
        Diag.add("simulation start");
        WatchUi.requestUpdate();
    }

    //! Live deviation of the virtual motorcycle (C11, `tools/e2e.py --detour`): without a
    //! simulation running there is nothing to deviate. The channel is the bridge's; the real
    //! app never calls this.
    function setReplayDetour(metres as Float) as Void {
        var replay = _replay;
        if (replay == null) {
            Diag.add("live detour: no simulation");
            return;
        }
        replay.setDetour(metres);
        Diag.add("live detour " + metres.format("%.0f") + "m");
    }

    //! Live fix gap on the virtual motorcycle (C13b, `tools/e2e.py --no-fix`): for
    //! `seconds` seconds it keeps moving and no fix reaches [applyFix], as
    //! in a tunnel. The channel is the bridge's; the real app never calls this.
    function setReplayHole(seconds as Number) as Void {
        var replay = _replay;
        if (replay == null) {
            Diag.add("fix gap: no simulation");
            return;
        }
        replay.setHole(seconds);
        Diag.add("fix gap " + seconds.toString() + "s");
    }

    //! The virtual motorcycle starts saying where it is at each step (`PONTE:POS`), so
    //! `tools/e2e.py` carries the emulator's GPS along with it. Also bridge-only.
    function setReplayReport() as Void {
        var replay = _replay;
        if (replay == null) {
            Diag.add("motorcycle position: no simulation");
            return;
        }
        replay.reportPosition = true;
        Diag.add("motorcycle position: on");
    }

    //! Drops the simulation, whatever the reason, and gives the map back to the GPS: zeroes the
    //! matching, the warnings and the gap (otherwise the `AlertPolicy` guard would silence the
    //! turns that the simulation has already "passed") and goes back to the earlier phase, with the GPS that
    //! phase had.
    function stopReplay(reason as String) as Void {
        var replay = _replay;
        if (replay == null) {
            return;
        }
        replay.release();
        Diag.add("simulation end: " + reason + " in " + replay.fixes().toString() + " fixes");
        _replay = null;
        _replayActive = false;
        _matcher.reset();
        _alerts.reset();
        _gap.reset();
        resetOffRoute();
        _nav.invalidateFix();
        _hasLastFix = false;
        _nav.phase = _phaseBeforeReplay;
        if (_phaseBeforeReplay == NavPhase.NAVIGATING) {
            try {
                startGps();
            } catch (ex) {
                Diag.add("startGps failed");
            }
        }
        WatchUi.requestUpdate();
    }

    //! What the recorder kept, stated in the log: without this line a track that
    //! lost fixes would be indistinguishable from a short ride.
    private function logTrackSummary() as Void {
        Diag.add("trail " + _track.recorded.toString() + " fixes lost " + _track.lost.toString());
    }

    //! Entry of the **own** fix: the GPS and the virtual ride go through here, so
    //! what the ride proves is the path the real fix travels. Whoever calls
    //! sets `fixSource` first. The phone's fix enters through [applyPhoneFix], and
    //! both end up in [moveTo].
    function applyFix(latE5 as Number, lonE5 as Number, speed as Float, heading as Float?, quality as Number?) as Void {
        // A bad fix does not move the map: keeping the last state is less wrong than
        // jumping to an invented position.
        var weak = quality == null || quality < Position.QUALITY_USABLE;
        var nowMs = Clock.nowMs();
        var phoneGiving = _fallback.phoneGiving(nowMs);
        if (weak && (_nav.hasFix || phoneGiving)) {
            // The origin stays that of whoever moved the map last. And with the
            // phone giving the position (C13b), the watch's weak fix is not news:
            // marking "weak GPS" here would flash the warning every second of the tunnel. If
            // the phone went quiet, it goes back to being.
            _nav.fixSource = _appliedSource;
            if (!phoneGiving) {
                _nav.weakFix = true;
                WatchUi.requestUpdate();
            }
            return;
        }
        _nav.weakFix = weak;

        // What gets past here weak is only the trip's first fix, which moves the map
        // because an approximate position is better than none.
        var silence = _gap.onFix(nowMs);
        if (silence > 0) {
            Diag.add("fix back after " + (silence / 1000).toString() + "s");
        }
        if (!weak) {
            // Only a good fix dismisses the phone: a last known position is not
            // the GPS coming back, and counting it would silence the backup for 5 s.
            _fallback.onOwnFix(nowMs);
            notePhoneEpisode();
        }
        _track.offer(nowMs, latE5, lonE5, speed, heading, _nav.fixSource == FixSource.REPLAY);
        moveTo(nowMs, latE5, lonE5, speed, heading);
    }

    //! A valid PHONE_FIX (C13b, `05 §PHONE_FIX`): the phone's GPS position,
    //! which only counts while the watch does not have its own ([FixFallback]). **It does not
    //! feed [FixGap] nor the track recorder**: the first keeps measuring
    //! the watch's GPS, which is the street's instrument, and the track stays only
    //! real GPS. Logs on change, never per fix.
    private function applyPhoneFix(fix as PhoneFix) as Void {
        var nowMs = Clock.nowMs();
        var first = _fallback.phoneFixes == 0;
        var verdict = _fallback.acceptPhoneFix(nowMs, fix.accuracyM);
        if (verdict == FixFallback.PHONE_NOT_NEEDED) {
            return;
        }
        if (verdict == FixFallback.PHONE_WEAK) {
            if (_fallback.weakFixes == 1) {
                Diag.add("phone fix weak: accuracy " + fix.accuracyM.toString() + "m");
            }
            _nav.weakFix = true;
            WatchUi.requestUpdate();
            return;
        }
        if (first) {
            Diag.add("phone fix: start, accuracy " + fix.accuracyM.toString() + "m, age "
                + fix.ageMs.toString() + "ms");
        }
        _nav.weakFix = false;
        _nav.fixSource = FixSource.PHONE;
        bridgePhoneFix(fix.latE5, fix.lonE5, fix.accuracyM, fix.ageMs, fix.hasHeading() ? fix.headingDeg : -1);
        moveTo(
            nowMs,
            fix.latE5,
            fix.lonE5,
            (fix.speedDms / 10.0).toFloat(),
            fix.hasHeading() ? (fix.headingDeg * Math.PI / 180.0).toFloat() : null
        );
    }

    //! The phone GPS episode ended (the own fix came back, or navigation
    //! finished): one line with how long it lasted and how many fixes were used.
    private function notePhoneEpisode() as Void {
        if (_fallback.takeEnded()) {
            Diag.add("phone fix: end after " + (_fallback.endedMs / 1000).toString() + "s, "
                + _fallback.endedFixes.toString() + " fixes");
        }
    }

    //! What every accepted fix does, wherever it comes from: converts to the route's
    //! local plane, matches with the polyline, measures the off-route, evaluates the warnings and asks
    //! for the redraw — there is no render timer of its own (`03 §Rendering`).
    private function moveTo(nowMs as Number, latE5 as Number, lonE5 as Number, speed as Float, heading as Float?) as Void {
        _appliedSource = _nav.fixSource;
        _hasLastFix = true;
        _lastLatE5 = latE5;
        _lastLonE5 = lonE5;

        var x =Projection.toLocalX(lonE5, _route.lon0, _route.lonScale);
        var y = Projection.toLocalY(latE5, _route.lat0);
        _nav.applyFix(x, y, speed, heading);
        _nav.tickTrip(nowMs);

        _matcher.update(x, y);
        trackOffRoute(nowMs);
        _nav.updateAutoZoom(System.getTimer(), _matcher.distToNextTurnM());
        checkNavEvents();
        WatchUi.requestUpdate();
    }

    //! Nothing measured on the previous route holds for the next one (see `OffRoute.reset`).
    private function resetOffRoute() as Void {
        _offRoute.reset();
        _nav.offRoute = OffRoute.ON_ROUTE;
        _assembler.noteRerouteOver();
    }

    //! Off-route (RF-11, ADR-4, C11). Feeds the detector with the already matched fix and
    //! does what the event dictates: vibrate and ask for the new route on leaving, ask
    //! again every 20 s, give up on the phone at 10 s. Only while navigating and matched: with no
    //! route or phase there is no "outside" to measure.
    private function trackOffRoute(nowMs as Number) as Void {
        if (_nav.phase != NavPhase.NAVIGATING || !_matcher.matched) {
            return;
        }
        var event = _offRoute.update(
            nowMs, _matcher.crossTrack, _matcher.distAlong, _assembler.isSwapPending());
        _nav.offRoute = _offRoute.state;
        if (event == OffRoute.EVENT_TRIGGERED) {
            Diag.add("off route " + _matcher.crossTrack.toNumber().toString() + "m");
            _alerts.alertOffRoute();
            _assembler.noteRerouteRequest();
            requestReroute();
        } else if (event == OffRoute.EVENT_RETRY) {
            requestReroute();
        } else if (event == OffRoute.EVENT_NO_PHONE) {
            // The phrase that `e2e.py --estresse` (C14) looks for: without the phone the
            // watch keeps navigating along the route it has, and says why it does not recalculate.
            Diag.add("recalculation needs the phone: new route did not arrive");
        } else if (event == OffRoute.EVENT_ANSWERING) {
            Diag.add("new route arriving");
        } else if (event == OffRoute.EVENT_BACK) {
            Diag.add("back on route");
            _assembler.noteRerouteOver();
        }
    }

    //! The REROUTE_REQ (`05 §REROUTE_REQ`): the fix position, the heading (or
    //! "unknown": `0` would be telling Mapbox the motorcycle points north) and
    //! the progress of the **last fix on the route**, not the current one.
    private function requestReroute() as Void {
        var degrees = Protocol.HEADING_UNKNOWN;
        if (_nav.hasHeading) {
            var d = (_nav.headingRad * 180.0 / Math.PI + 0.5).toNumber() % 360;
            degrees = d < 0 ? d + 360 : d;
        }
        _link.sendRerouteReq(
            _route.routeId, _lastLatE5, _lastLonE5, degrees, _offRoute.lastOnRouteM.toNumber());
    }

    //! Warnings that depend on progress, evaluated on every fix (RF-07, RF-12).
    //!
    //! Arrival is tested **before** the turn: the route's last point usually has
    //! an arrival maneuver attached, and warning "turn right" a second
    //! after "you have arrived" is contradictory noise at the worst moment.
    private function checkNavEvents() as Void {
        if (_nav.phase != NavPhase.NAVIGATING) {
            return;
        }
        // Off the route neither turn nor arrival count: `matched` is true at
        // any distance, and the progress is that of a route point the rider
        // is not stepping on.
        if (_offRoute.isOff()) {
            return;
        }

        if (NavEngine.hasArrived(_matcher)) {
            _nav.phase = NavPhase.ARRIVED;
            _alerts.alertArrival();
            // The simulation's arrival is the desk's: it does not tell the phone the route ended and
            // does not turn off the real GPS ([stopReplay] gives back the earlier phase).
            if (_replay == null) {
                _link.sendNavEnded(_route.routeId, Protocol.NAV_ENDED_ARRIVED);
            }
            // C16.6: the deviation, the segment and the fix source say where a false arrival
            // came from (the parked "You're here" ~400 m from Copan, 26/10). `sim.py` reads the start.
            Diag.add("arrived at destination at " + _matcher.remainingM().toNumber().toString() + "m detour "
                + _matcher.crossTrack.toNumber().toString() + "m seg " + _matcher.segmentIdx.toString()
                + " source " + _nav.fixSource.toString());
            logTrackSummary();
            if (_replay == null) {
                stopGps();
                _arrivalExit.arrived(Clock.nowMs());
            }
            return;
        }

        if (_matcher.matched) {
            _alerts.updateRadar(_route, _matcher.distAlong, _nav.speedMps);
        }

        var index = _matcher.nextTurnIndex();
        if (index < 0 || index >= _route.turnType.size()) {
            return;
        }
        _alerts.update(
            index,
            _route.turnType[index] as Number,
            _matcher.distToNextTurnM(),
            _nav.speedMps
        );
    }

    function onTick() as Void {
        var replay = _replay;
        if (replay != null) {
            var reason = replay.tick();
            if (reason != null) {
                stopReplay(reason);
            }
        }
        if (_nav.phase == NavPhase.NAVIGATING && _nav.hasFix) {
            var silence = _gap.poll(Clock.nowMs());
            if (silence > 0) {
                Diag.add("no fix for " + (silence / 1000).toString() + "s");
            }
        }
        // The GPS backup (C13b): asks for the phone after 5 s without its own fix, renews
        // every 20 s and dismisses it when the GPS comes back or navigation ends.
        var fixEvent = _fallback.poll(Clock.nowMs(), _nav.phase == NavPhase.NAVIGATING);
        if (fixEvent == FixFallback.EVENT_ASK) {
            _link.sendFixReq(true);
        } else if (fixEvent == FixFallback.EVENT_STOP) {
            _link.sendFixReq(false);
        }
        notePhoneEpisode();
        if (_nav.phase == NavPhase.ARRIVED) {
            var exit = _arrivalExit.poll(Clock.nowMs());
            if (exit == ArrivalExit.ANNOUNCE) {
                Diag.add("arrival: the app closes by itself after "
                    + (_arrivalExit.CLOSE_AFTER_MS / 1000).toString() + "s without touch");
                _link.flushLog();
            } else if (exit == ArrivalExit.EXIT) {
                System.exit();
            }
        }
        _assembler.checkTimeouts(System.getTimer());
        if (_favoriteAsk.update(System.getTimer())) {
            Diag.add((_favoriteAsk.isShared() ? "route stopped arriving" : "favorite got no answer")
                + " in " + (FavoriteAsk.TIMEOUT_MS / 1000).toString() + "s");
            WatchUi.requestUpdate();
        }
        // POLY and corridor are read in slices, one per tick (and, with a slice left to read, one more
        // every [CATCHUP_MS], C16): read whole on
        // arrival, SP's LOD 0 (DECISIONS §2026-09-29 C2b) and the POLY of a
        // 16 km route (§C6a: the pre-flight) blew the watchdog. The POLY that
        // ends here completes the route, and this is where the map comes in.
        pumpJobs();
        sendTelemetry();

        // **One redraw per second, not two.** Navigating with a fix, whoever orders the
        // redraw is the GPS callback, which arrives at 1 Hz — asking for another here
        // doubled the frame rate and, with the frame costing tens of ms, doubled
        // the CPU cost and the watchdog risk too, showing nothing new:
        // between two fixes the map is identical. Outside navigation the tick remains
        // the screen's only clock — the home screen shows link counters and
        // is precisely the one that stays up when nothing arrives.
        if (_nav.phase == NavPhase.NAVIGATING && _nav.hasFix) {
            return;
        }
        WatchUi.requestUpdate();
    }

    //! A slice of the POLY or the corridor; the POLY that ends completes the route, and this is where the map
    //! comes in. From the tick and [onCatchUp].
    private function pumpJobs() as Void {
        if (_assembler.stepJobs() && _route.isComplete()) {
            showNav();
        }
        if (hasPendingJobs()) {
            if (_waitShown == WAIT_HOME) {
                // The POLY of a long route is read in slices after the last piece:
                // the route is moving, and the wait deadline cannot expire because of this.
                _favoriteAsk.noteRouteChunk(System.getTimer());
            }
            scheduleCatchUp();
        }
    }

    private function hasPendingJobs() as Boolean {
        return _assembler.isPolyPending() || _assembler.isCorridorPending();
    }

    //! Asks for the next step in [CATCHUP_MS], if it has not already asked. See [_catchUpTimer].
    function scheduleCatchUp() as Void {
        if (_catchUpArmed) {
            return;
        }
        var timer = _catchUpTimer;
        if (timer == null) {
            timer = new Timer.Timer();
            _catchUpTimer = timer;
        }
        _catchUpArmed = true;
        timer.start(method(:onCatchUp), CATCHUP_MS, false);
    }

    //! **The streets as an image also move here** (`StreetCache`): one step per callback, with the watchdog
    //! of the callback just for it. The step does not ask for a frame: the screen would show the same image as before.
    //! Only the ready image asks, or the street-by-street sweep while no image covers the glass.
    //! With a POLY or corridor slice left to read, the step waits (the two in the same callback would add up), and
    //! so it does with the menu holding the map: `NavView` asks again when the map comes back.
    function onCatchUp() as Void {
        _catchUpArmed = false;
        pumpJobs();
        var frame = true;
        // The drawing lever in the frame (v1.2.6): the timer only asks for the frame, and the frame runs the step.
        if (_map.streetsBuilding() && !hasPendingJobs() && !_nav.menuHoldsTheMap(System.getTimer())) {
            frame = _map.stepStreets(_assembler.getCorridor()) || _map.scanWantsFrames();
            if (!frame) {
                scheduleCatchUp();
            }
        }
        if (frame) {
            WatchUi.requestUpdate();
        }
    }

    //! Navigation telemetry to the phone, with nobody asking.
    //!
    //! **Why this exists:** the watch is the only place where the app really runs
    //! and the only one that has no logcat, profiler or big screen. Until now,
    //! diagnosing meant Igor reading a number on the screen and transcribing it to the
    //! chat — which spends his time, loses precision and only works if someone
    //! knows beforehand what to ask. His explicit request: *"do everything that
    //! will help you go to the phone, so you can get better diagnostics
    //! than just asking me"*.
    //!
    //! One line every [TELEMETRY_EVERY_S] and one send every
    //! [LOG_FLUSH_EVERY_S] — the send costs a BLE message of up to 1.2 KB, so
    //! it is rare and only during navigation.
    //! **The watch always reports, in any phase.**
    //!
    //! The previous version only reported while navigating — and so, when the app stopped
    //! on the transfer screen without reaching the map, it simply **went mute**.
    //! From the phone's side that is indistinguishable from "the app closed", and it cost an entire
    //! round of diagnosis with Igor testing on the road. A diagnostic channel
    //! that only works when everything is fine is not a diagnostic
    //! channel: the phase went into the line precisely to say where it stopped.
    private function sendTelemetry() as Void {
        _ticks++;

        // The weather: the first reading in the 1st second and one every 15 min.
        if (_ticks % WeatherInfo.REFRESH_S == 1) {
            WeatherInfo.readNow();
        }

        if (_ticks % TELEMETRY_EVERY_S == 0) {
            Diag.add(_map.frameSummary());
            _map.resetFrameStats();

            var stats = System.getSystemStats();
            Diag.add(Telemetry.line(
                phaseName(),
                _navShown ? "map" : (_waitShown != WAIT_NONE ? "transfer" : "initial"),
                _route,
                _assembler.getCorridor(),
                _map.visibleWays(),
                _nav,
                _matcher,
                stats.usedMemory,
                stats.totalMemory,
                stats.battery
            ));
        }

        if (_ticks % LOG_FLUSH_EVERY_S == 0) {
            _link.flushLog();
        }
    }

    private function phaseName() as String {
        if (_nav.phase == NavPhase.NAVIGATING) { return "navigating"; }
        if (_nav.phase == NavPhase.ARRIVED) { return "arrived"; } // lang: log
        if (_nav.phase == NavPhase.RECEIVING) { return "receiving"; } // lang: log
        return "idle";
    }
}

function getApp() as MotoNavApp {
    return Application.getApp() as MotoNavApp;
}
