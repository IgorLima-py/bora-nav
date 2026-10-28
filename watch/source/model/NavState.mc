import Toybox.Lang;
import Toybox.Math;

//! Navigation phases (`03 §State machine`). F2 uses the subset up to
//! NAVIGATING; OFFROUTE/REROUTING arrive in F4 with the reroute.
module NavPhase {
    enum {
        IDLE = 0,
        RECEIVING = 1,
        NAVIGATING = 2,
        ARRIVED = 3
    }
}

//! Where the last fix came from. Today only the GPS exists; the virtual-ride replay
//! (C3a) and the phone's position (C8) will just mark their own value. It goes in the
//! telemetry because a virtual-ride log read as a real ride
//! would repeat the mistake of debugging the wrong build.
module FixSource {
    enum {
        NONE = 0,
        GPS = 1,
        REPLAY = 2,
        PHONE = 3
    }
}

//! Live navigation state: where the rider is, where they are heading, how fast,
//! and how the map is being looked at (zoom, pan).
//!
//! The heading is smoothed in **components** (sin/cos) and not in the angle: a direct
//! exponential average would jump from 359° to 1° and the map would spin a full turn.
//! Below [HEADING_FREEZE_MPS] the heading freezes — stopped, the GPS spins the
//! heading randomly and the track-up would jitter (`03 §GPS`).
class NavState {

    const HEADING_ALPHA = 0.4;

    //! 1 m/s ≈ 3.6 km/h. It used to be 2.0 m/s (7.2 km/h), which left the map stuck to
    //! north in any test on foot — and a test on foot is the only one that can be done
    //! without taking the motorcycle out of the garage. Still high enough not to spin with
    //! the motorcycle stopped, which is the case the lock exists to cover.
    const HEADING_FREEZE_MPS = 1.0;

    //! Below this the motorcycle is stopped: the fix does not leave the trip nor add
    //! kilometers to [tripMovedM] (a stopped GPS wanders a few meters per second for nothing).
    const MOVING_FLOOR_MPS = 1.5;

    //! Until the trip has this much since departure, [tripSpeedMps] stays at zero and the ETA is
    //! just the API's. A choice, not a measurement: 2 min takes leaving home and the first
    //! corner out of the average, and on a 30 min trip it is still early.
    const TRIP_WARMUP_MS = 120000;

    //! From [TRIP_WARMUP_MS] to this, the weight of the trip average in the ETA ([tripWeight])
    //! rises from 0 to 1 in a straight line. Without the ramp, the slow start came back as a step
    //! at 2 min (at 9 km/h, from ~1200 s to ~2600 s in one fix). A choice, not a measurement.
    const TRIP_FULL_MS = 600000;

    //! A stretch between two fixes faster than this (252 km/h) is a GPS jump, not a
    //! motorcycle, and stays out of [tripMovedM].
    const TRIP_MAX_MPS = 70.0;

    //! Zoom levels in meters per pixel (`03 §Rendering`).
    static const ZOOM_LEVELS = [0.6, 1.2, 2.5, 5.0, 10.0, 20.0] as Array<Float>;

    //! Level where the map is born and where it stays: **1.2 m/px**. With the rider in the
    //! center of a 454 px screen, that gives ~270 m ahead and ~136 m to each
    //! side — about three blocks, which was exactly Igor's request
    //! after the `v0.9.0-f2` test ("it should stay still, a bit closer,
    //! so I can see about 3 streets ahead").
    static const DEFAULT_ZOOM_INDEX = 1;

    //! From this index on the level is "look at the whole route", not "ride".
    //! Manual zoom from here up is a lookup and returns on its own; below it is a
    //! preference and stays (Igor's request, 2026-07-31).
    const BROWSE_ZOOM_INDEX = 4;

    //! Only a **very wide** manual zoom hands control back to the automatic one, and in
    //! 10 s. At the riding levels the value chosen by hand holds until the next
    //! touch — the automatic one returning by itself after 15 s was exactly what
    //! undid the rider's choice without them asking.
    const BROWSE_ZOOM_HOLD_MS = 10000;

    //! Tightening of ~15% on the automatic zoom targets: with the rider in the center
    //! of the screen, the old levels left the map too wide to follow.
    const ZOOM_TIGHTEN = 0.87;

    //! With no touch on the screen for 5 s, the map goes back to following the rider (`01 §Interaction`).
    const BROWSE_TIMEOUT_MS = 5000;

    var phase as Number = NavPhase.IDLE;

    var hasFix as Boolean = false;
    var weakFix as Boolean = false;

    //! [FixSource] of the last fix. Whoever calls [applyFix] marks it, because only they
    //! know where the fix came from.
    var fixSource as Number = FixSource.NONE;

    //! Rider position in local meters, in the route's plane.
    var x as Float = 0.0;
    var y as Float = 0.0;

    var speedMps as Float = 0.0;

    //! **The trip's average speed, stops included**, for the ETA (`03 §ETA local`):
    //! [tripMovedM] ÷ the time since departure. Zero until [TRIP_WARMUP_MS].
    //!
    //! It used to be a moving average of only the in-motion samples, which was born at the first
    //! one. On an October ride that gave the jump seen on the wrist: the trip
    //! started at 23 km/h and the remainder was born at 4750 s (Mapbox said 2736),
    //! to fall to 1960 s in 4 min; and at a traffic light the average without stops froze the
    //! remainder. With the stops in the calculation, today's traffic light counts like
    //! tomorrow's, and the remainder moves slowly while the motorcycle is stopped
    //! (`DECISIONS.md` §"2026-10-21", the arrival time).
    var tripSpeedMps as Float = 0.0;

    //! How much of the trip average goes into the ETA: 0 until [TRIP_WARMUP_MS], 1 from
    //! [TRIP_FULL_MS] on, and a straight line in between.
    var tripWeight as Float = 0.0;

    //! Meters traveled since departure, summed fix by fix with the motorcycle moving.
    var tripMovedM as Float = 0.0;

    //! Smoothed heading, in radians, 0 = north, increasing eastward.
    var headingRad as Float = 0.0;

    //! Has any fix brought a trustworthy heading yet? Before that [headingRad] is the birth
    //! zero, not "north": the recalculation request sends "unknown heading" instead of
    //! telling Mapbox the motorcycle points north (`05 §REROUTE_REQ`).
    var hasHeading as Boolean = false;

    //! The off-route substate (`OffRoute.ON_ROUTE`, `REQUESTED`,
    //! `NO_PHONE`), mirrored here by `MotoNavApp` for the `Hud` and the telemetry
    //! to read. **It is not a phase:** [phase] stays `NAVIGATING` (see `OffRoute`).
    var offRoute as Number = 0;

    //! Current scale and level. Born at [DEFAULT_ZOOM_INDEX] (1.2 m/px) — the
    //! literals are repeated here because Monkey C does not let a field be initialized
    //! from a constant of its own class.
    var metersPerPx as Float = 1.2;
    var zoomIndex as Number = 1;

    //! Last **riding** level chosen (below [BROWSE_ZOOM_INDEX]).
    //! This is where the lookup zoom returns when it expires — going back to the
    //! default would undo the preference of someone who likes 0.6 or 2.5 m/px.
    var ridingZoomIndex as Number = 1;

    //! **Automatic zoom off by default.**
    //!
    //! It works — it opens at highway speed, closes near the turn — and that is
    //! precisely what Igor did not like in the `v0.9.0-f2` test: the scale
    //! changing by itself under the eye costs more attention than the extra field of view
    //! gives back, in a glance of ≤1 s with a helmet on. The code stays, reachable
    //! from the right-hand menu, because the decision is a matter of taste and may come back.
    var autoZoom as Boolean = false;

    //! Map offset in browse mode, in local meters.
    var panX as Float = 0.0;
    var panY as Float = 0.0;
    var browsing as Boolean = false;

    //! **The arrival predicted at the start of the trip** (C16.5), in epoch seconds
    //! (`Time.now()`), for the delta next to the arrival time. -1 = not yet
    //! marked: the 1st estimate with the motorcycle matched to the route is the one that counts. It survives the
    //! recalculation and `ROUTE_UPDATE` (same destination); a new destination resets it ([beginTrip]).
    var plannedArrivalS as Number = -1;

    //! A route end within this distance of the previous one's end is the same trip (recalculation). Mapbox
    //! anchors the end of the same destination at the same point on the street, a few meters off;
    //! two different destinations of Igor's are kilometers apart. A choice, not a measurement.
    const SAME_DEST_M = 150.0;

    private var _hasTrip as Boolean = false;
    private var _tripDestLat as Number = 0;
    private var _tripDestLon as Number = 0;

    //! Departure: the first moving fix after [invalidateFix]. -1 = stopped
    //! since then.
    private var _tripStartMs as Number = -1;
    private var _tripLastMs as Number = 0;
    private var _tripLastX as Float = 0.0;
    private var _tripLastY as Float = 0.0;

    private var _headingSin as Float = 0.0;
    private var _headingCos as Float = 1.0;
    //! Flag instead of comparing with zero: `_manualZoomMs = 0` would mean "manual zoom
    //! at instant 0", and since `System.getTimer()` starts near zero,
    //! the automatic one stayed suspended precisely during the first 15 s of navigation.
    private var _zoomTouched as Boolean = false;
    private var _manualZoomMs as Number = 0;
    private var _lastTouchMs as Number = 0;

    function initialize() {
    }

    //! New route on screen (`MotoNavApp.showNav`): if its end (`latE5`, `lonE5`, in
    //! 1e-5 degree) is the destination of the trip in progress, it is a recalculation and the predicted arrival
    //! stays; if not, it is a new trip and it gets marked again.
    function beginTrip(latE5 as Number, lonE5 as Number) as Void {
        if (_hasTrip) {
            // 1e-5 degree of latitude = 1.1132 m; longitude shrinks with the cosine.
            var dy = (latE5 - _tripDestLat) * 1.1132;
            var dx = (lonE5 - _tripDestLon) * 1.1132 * Math.cos(latE5 / 100000.0 * Math.PI / 180.0);
            if (dx * dx + dy * dy <= SAME_DEST_M * SAME_DEST_M) {
                return;
            }
        }
        _hasTrip = true;
        _tripDestLat = latE5;
        _tripDestLon = lonE5;
        plannedArrivalS = -1;
    }

    //! Route ended or simulation restarted: the next estimate marks the plan again.
    function endTrip() as Void {
        _hasTrip = false;
        plannedArrivalS = -1;
    }

    //! Seconds of delay (+) or slack (−) of the arrival predicted now (`nowS` plus
    //! `remainingS`) against that of the start of the trip. The first call marks the plan and
    //! returns 0.
    function arrivalDelta(nowS as Number, remainingS as Number) as Number {
        var eta = nowS + remainingS;
        if (plannedArrivalS < 0) {
            plannedArrivalS = eta;
            return 0;
        }
        return eta - plannedArrivalS;
    }

    //! Applies a GPS fix. `headingRad` only goes in if the heading is trustworthy.
    function applyFix(newX as Float, newY as Float, speed as Float, heading as Float?) as Void {
        x = newX;
        y = newY;
        speedMps = speed;
        hasFix = true;

        if (heading != null && speed >= HEADING_FREEZE_MPS) {
            var target = heading as Float;
            _headingSin = (_headingSin + (Math.sin(target) - _headingSin) * HEADING_ALPHA).toFloat();
            _headingCos = (_headingCos + (Math.cos(target) - _headingCos) * HEADING_ALPHA).toFloat();
            headingRad = Math.atan2(_headingSin, _headingCos).toFloat();
            hasHeading = true;
        }
    }

    //! Takes the fix that [applyFix] just applied to the trip odometer and
    //! recomputes [tripSpeedMps]. `nowMs` is `Clock.nowMs()`, which in the compressed
    //! virtual ride runs on the motorcycle's time. Stopped, only time runs: that is what makes
    //! the remainder move at a traffic light instead of freezing.
    function tickTrip(nowMs as Number) as Void {
        var moving = speedMps >= MOVING_FLOOR_MPS;
        if (_tripStartMs < 0) {
            if (!moving) {
                return;
            }
            _tripStartMs = nowMs;
        } else if (moving) {
            var dx = x - _tripLastX;
            var dy = y - _tripLastY;
            var metres = Math.sqrt(dx * dx + dy * dy).toFloat();
            if (metres <= (nowMs - _tripLastMs) * TRIP_MAX_MPS / 1000.0) {
                tripMovedM += metres;
            }
        }
        _tripLastMs = nowMs;
        _tripLastX = x;
        _tripLastY = y;

        var elapsedMs = nowMs - _tripStartMs;
        if (elapsedMs < TRIP_WARMUP_MS) {
            tripSpeedMps = 0.0;
            tripWeight = 0.0;
            return;
        }
        tripSpeedMps = (tripMovedM * 1000.0 / elapsedMs).toFloat();
        var ramp = (elapsedMs - TRIP_WARMUP_MS).toFloat() / (TRIP_FULL_MS - TRIP_WARMUP_MS);
        tripWeight = ramp < 1.0 ? ramp : 1.0;
    }

    //! Discards the current fix. Mandatory when changing route: `x`/`y` are in the
    //! local plane of the **previous** route (another `lat0`/`lon0`), so keeping them
    //! draws the rider kilometers from where they are until the next fix arrives.
    function invalidateFix() as Void {
        hasFix = false;
        weakFix = false;
        fixSource = FixSource.NONE;
        speedMps = 0.0;
        x = 0.0;
        y = 0.0;
        resetTripSpeed();
        recenter();
    }

    //! Departure goes back to being the next moving fix. Goes along with the fix, in
    //! [invalidateFix]: the recalculation goes through [rebase] and the average stays.
    private function resetTripSpeed() as Void {
        tripSpeedMps = 0.0;
        tripWeight = 0.0;
        tripMovedM = 0.0;
        _tripStartMs = -1;
    }

    //! The same position, in another local plane: the route changed along the way
    //! (recalculation, C11) and the new one's `lat0`/`lon0` is different. The caller reprojects the
    //! last fix; heading, speed and averages belong to the rider, not the route, and stay.
    //! It is what avoids [invalidateFix] on the swap: with it the map lost the arrow and
    //! the HUD said "no GPS" for a second on every recalculation.
    function rebase(newX as Float, newY as Float) as Void {
        x = newX;
        y = newY;
        // The odometer measures in the new plane from here on: without this, the plane swap
        // would become a stretch of kilometers between the last fix and the next.
        _tripLastX = newX;
        _tripLastY = newY;
    }

    //! Moves the map center **without** claiming a fix. It is for the watch's last
    //! known position: it puts the map on top of the rider right away, but is not a
    //! live reading — the arrow stays hidden and the HUD keeps saying there is no
    //! GPS, which is the truth.
    function seedCentre(newX as Float, newY as Float) as Void {
        x = newX;
        y = newY;
    }

    //! Automatic zoom by speed and maneuver proximity
    //! (`03 §Rendering`). Negative `distToTurnM` = no next maneuver.
    function updateAutoZoom(nowMs as Number, distToTurnM as Float) as Void {
        if (!autoZoom) {
            return;
        }
        if (manualZoomHolds(nowMs)) {
            return;
        }
        _zoomTouched = false;

        var target;
        if (speedMps < 1.0) {
            target = 0.6;
        } else if (speedMps < 8.0) {
            target = 1.2;
        } else if (speedMps < 17.0) {
            target = 2.5;
        } else {
            target = 5.0;
        }

        // Turn coming up: zoom in, whatever it costs in field of view.
        if (distToTurnM >= 0.0 && distToTurnM < 250.0 && target > 1.2) {
            target = 1.2;
        }

        target *= ZOOM_TIGHTEN;

        // Smooth transition: 20% per frame keeps the map from "jumping" in scale.
        metersPerPx = (metersPerPx + (target - metersPerPx) * 0.2).toFloat();
    }

    //! Is the zoom chosen by hand in command? At the riding levels, forever;
    //! at the lookup levels, for the first [BROWSE_ZOOM_HOLD_MS].
    function manualZoomHolds(nowMs as Number) as Boolean {
        if (!_zoomTouched) {
            return false;
        }
        if (zoomIndex < BROWSE_ZOOM_INDEX) {
            return true;
        }
        return nowMs - _manualZoomMs < BROWSE_ZOOM_HOLD_MS;
    }

    //! A level only counts as "where I was riding" if it stayed on the screen for
    //! this long. Taps in sequence are **one gesture**, not five choices: whoever
    //! presses four times in a row to peek at the whole route did not choose the
    //! levels in the middle of the way, they passed through them.
    const ZOOM_SETTLE_MS = 3000;

    //! Up button: cycles the zoom and suspends the automatic one.
    function cycleZoom(nowMs as Number) as Void {
        // Saves the riding level **before** leaving it, and only if it had
        // settled. Without this condition, Igor's 1.2 m/px would become 5.0 on the
        // way to 20 and the lookup zoom would return to the wrong place.
        if (zoomIndex < BROWSE_ZOOM_INDEX
            && (!_zoomTouched || nowMs - _manualZoomMs >= ZOOM_SETTLE_MS)) {
            ridingZoomIndex = zoomIndex;
        }
        setZoomIndex((zoomIndex + 1) % ZOOM_LEVELS.size());
        _manualZoomMs = nowMs;
        _zoomTouched = true;
    }

    //! Turns the automatic one on/off from the menu. On turning off, the scale goes back to the
    //! **named** level chosen on the button: without this the map would freeze at the
    //! intermediate value the automatic interpolation was passing through, which
    //! is none of the six levels and is not reproducible.
    function setAutoZoom(enabled as Boolean) as Void {
        autoZoom = enabled;
        if (!enabled) {
            metersPerPx = ZOOM_LEVELS[zoomIndex] as Float;
            _zoomTouched = false;
        }
    }

    //! Dragging a finger leaves "follow" mode and enters browse mode.
    function pan(dxMetres as Float, dyMetres as Float, nowMs as Number) as Void {
        panX += dxMetres;
        panY += dyMetres;
        browsing = true;
        _lastTouchMs = nowMs;
    }

    function recenter() as Void {
        panX = 0.0;
        panY = 0.0;
        browsing = false;
    }

    //! **The map stops redrawing itself with the action menu open** (C16, bench of 2026-10-17:
    //! "I open the side menu, ultra mega slow to scroll it"). The menu sits on top of the map, and each
    //! GPS (1 Hz) and phone position asked for a frame of 118 to 177 ms (median of `frame med` in the
    //! bench log) that competed for the CPU with the menu's scrolling. While open, [NavView] leaves the last
    //! frame as it is. The menu closes itself on choice or on BACK (`showActionMenu` doc,
    //! SDK 9.2.0), and both reach the `NavMenuDelegate`; [MENU_FREEZE_MS] is the safety net for a
    //! closing that does not go through there.
    var menuOpenAt as Number = -1;

    //! A choice, not a measurement: the menu has six items, and 20 s is plenty to pick one with gloves on.
    const MENU_FREEZE_MS = 20000;

    function menuOpened(nowMs as Number) as Void {
        menuOpenAt = nowMs;
    }

    function menuClosed() as Void {
        menuOpenAt = -1;
    }

    function menuHoldsTheMap(nowMs as Number) as Boolean {
        return menuOpenAt >= 0 && nowMs - menuOpenAt < MENU_FREEZE_MS;
    }

    //! Call on every frame: hands the browse **and the lookup zoom** back to the rider
    //! after the timeout.
    //!
    //! **The trap this fixes.** The up button cycles the six levels,
    //! and the last two (10 and 20 m/px) are "look at the whole route", not riding.
    //! The intent was always that they return by themselves — but the only thing that
    //! consulted [manualZoomHolds] was the **automatic** zoom, which is off
    //! by default. Result: whoever went past index 4 stayed at 20 m/px
    //! forever, even after closing the app, because the level is persisted.
    //!
    //! That is exactly what happened: the 2026-08-01 log shows `zoom 20.0`
    //! across the whole session. At 20 m/px the screen covers 9 km, and each
    //! LOD's scale ceiling erases collector and local roads on purpose — Igor saw the white line in an
    //! empty space and had no way of knowing why. Now the lookup level expires
    //! to the last riding level, with or without the automatic one.
    function tickBrowse(nowMs as Number) as Void {
        if (browsing && nowMs - _lastTouchMs > BROWSE_TIMEOUT_MS) {
            recenter();
        }
        if (_zoomTouched
            && zoomIndex >= BROWSE_ZOOM_INDEX
            && nowMs - _manualZoomMs > BROWSE_ZOOM_HOLD_MS) {
            setZoomIndex(ridingZoomIndex);
            _zoomTouched = false;
        }
    }

    //! Applies a zoom level by index, keeping scale and index consistent.
    //! **Does not touch [ridingZoomIndex]** — who decides what is "where I was
    //! riding" is [cycleZoom], by the settling rule.
    function setZoomIndex(index as Number) as Void {
        if (index < 0 || index >= ZOOM_LEVELS.size()) {
            return;
        }
        zoomIndex = index;
        metersPerPx = ZOOM_LEVELS[index] as Float;
    }

    //! Map center in local meters — the rider, or the dragged point.
    function centreX() as Float {
        return x + panX;
    }

    function centreY() as Float {
        return y + panY;
    }
}
