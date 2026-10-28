import Toybox.Lang;

//! The phone GPS as a backup (C13b, `05 §FIX_REQ` and `§PHONE_FIX`): it decides
//! when to ask, when to renew the request, when the phone fix is worth using and when
//! to dismiss it.
//!
//! The watch decides, not the phone, because only it knows whether it has a fix: a
//! phone transmitting all the time would cost radio and battery for the whole trip
//! (`DECISIONS.md` §2026-07-31). Pure like [FixGap] and [OffRoute]: it receives
//! `nowMs` from outside, knows nothing about the link or the screen, and the caller
//! (`MotoNavApp`) does what the event says.
//!
//! "Own fix" is the watch's **good** fix, the one that passed the `applyFix` quality
//! cutoff. Weak GPS and mute GPS count the same here: in both the map stopped.
class FixFallback {

    //! Asks again every 20 s while it lasts: the request can get lost in the `PhoneLink`
    //! queue, and the renewal is what keeps the phone transmitting (it stops
    //! by itself after 50 s, `05 §FIX_REQ`). Same interval as `OffRoute`.
    const RENEW_MS = 20000;

    //! Dismisses the phone after this long of own fix back, with no other
    //! gap in between: a fix that shows up between two dropouts and vanishes is not the GPS
    //! coming back (`DECISIONS.md` §2026-07-31, "about 5 s").
    const RELEASE_MS = 5000;

    //! To dismiss, the own fix must be **arriving**: the last one at most
    //! this old. GPS gives one per second; two seconds is one lost.
    //! More than this between two fixes is another gap, and the 5 s start over.
    const FRESH_MS = 2000;

    //! The phone is "giving the position" while its last used fix is younger
    //! than this. Past that it went quiet (radio dropped, Android
    //! cut the GPS, the request deadline expired) and the map is stopped again.
    const PHONE_SILENT_MS = 5000;

    //! A phone fix with accuracy worse than this is a weak fix and does not move the
    //! map: it is the off-route threshold (RF-11), and a fix more uncertain than the
    //! threshold cannot feed the detector.
    const MAX_ACCURACY_M = 40;

    //! What [poll] just decided.
    enum {
        EVENT_NONE = 0,
        //! Send `FIX_REQ 1` (the first request or a renewal).
        EVENT_ASK = 1,
        //! Send `FIX_REQ 0`.
        EVENT_STOP = 2
    }

    //! What to do with a phone fix ([acceptPhoneFix]).
    enum {
        //! Worth it: it is the bike's position now.
        PHONE_USED = 0,
        //! The watch has a recent own fix (or is not navigating): ignore.
        PHONE_NOT_NEEDED = 1,
        //! Too imprecise: treat as a weak fix.
        PHONE_WEAK = 2
    }

    //! The phone is being requested (between the first `FIX_REQ 1` and the `FIX_REQ 0`).
    var asking as Boolean = false;

    //! Phone fixes used in the current episode. An episode starts at the
    //! first one used and ends when the own fix returns or navigation ends.
    var phoneFixes as Number = 0;

    //! Phone fixes rejected for imprecision since the first request.
    var weakFixes as Number = 0;

    //! The episode that ended last: how many fixes and how long. Only valid
    //! after [takeEnded] returns `true`.
    var endedFixes as Number = 0;
    var endedMs as Number = 0;

    private var _navigating as Boolean = false;

    //! The last own fix, or the start of navigation if none has come yet.
    private var _lastOwnMs as Number = 0;

    //! The first own fix after the last gap; only valid with [_hasStreak].
    private var _hasStreak as Boolean = false;
    private var _streakSinceMs as Number = 0;

    private var _askedMs as Number = 0;
    private var _phoneSinceMs as Number = 0;
    private var _lastPhoneMs as Number = 0;
    private var _ended as Boolean = false;

    function initialize() {
    }

    //! On every 1 s tick. `navigating` = the phase is `NAVIGATING`: outside it there is
    //! nothing for the backup to protect, and an open request is dismissed.
    function poll(nowMs as Number, navigating as Boolean) as Number {
        if (!navigating) {
            _navigating = false;
            closeEpisode(nowMs);
            if (asking) {
                asking = false;
                return EVENT_STOP;
            }
            return EVENT_NONE;
        }
        if (!_navigating) {
            // Navigation just started: the silence counts from here, not from a fix
            // of another trip.
            _navigating = true;
            _lastOwnMs = nowMs;
            _hasStreak = false;
        }

        var silentMs = nowMs - _lastOwnMs;
        if (!asking) {
            if (silentMs >= fixFallbackAskMs()) {
                asking = true;
                weakFixes = 0;
                _askedMs = nowMs;
                return EVENT_ASK;
            }
            return EVENT_NONE;
        }
        if (_hasStreak && silentMs <= FRESH_MS && nowMs - _streakSinceMs >= RELEASE_MS) {
            asking = false;
            return EVENT_STOP;
        }
        if (nowMs - _askedMs >= RENEW_MS) {
            _askedMs = nowMs;
            return EVENT_ASK;
        }
        return EVENT_NONE;
    }

    //! A good own fix arrived. Closes the phone episode, if there was one: the
    //! own fix is valid immediately, without waiting for the `FIX_REQ 0`.
    function onOwnFix(nowMs as Number) as Void {
        if (!_hasStreak || nowMs - _lastOwnMs > FRESH_MS) {
            _hasStreak = true;
            _streakSinceMs = nowMs;
        }
        _lastOwnMs = nowMs;
        closeEpisode(nowMs);
    }

    //! A valid PHONE_FIX arrived, with `accuracyM` of accuracy. Only valid while navigating
    //! and with the own fix silent for as long as it takes to ask; the phone
    //! keeps transmitting for a few seconds after the GPS returns, and those
    //! fixes must not compete for the position with the watch's.
    function acceptPhoneFix(nowMs as Number, accuracyM as Number) as Number {
        if (!_navigating || nowMs - _lastOwnMs < fixFallbackAskMs()) {
            return PHONE_NOT_NEEDED;
        }
        if (accuracyM > MAX_ACCURACY_M) {
            weakFixes++;
            return PHONE_WEAK;
        }
        if (phoneFixes == 0) {
            _phoneSinceMs = nowMs;
        }
        phoneFixes++;
        _lastPhoneMs = nowMs;
        return PHONE_USED;
    }

    //! The phone is giving the position now: there is an open episode and the last
    //! used fix is recent. With this, the weak fix from the watch's own GPS does not light
    //! "weak GPS"; without it, it lights, because the map stopped.
    function phoneGiving(nowMs as Number) as Boolean {
        return phoneFixes > 0 && nowMs - _lastPhoneMs < PHONE_SILENT_MS;
    }

    //! `true` once per ended episode, with [endedFixes] and [endedMs]
    //! filled in: it is the cue for the caller's log line.
    function takeEnded() as Boolean {
        var ended = _ended;
        _ended = false;
        return ended;
    }

    private function closeEpisode(nowMs as Number) as Void {
        if (phoneFixes == 0) {
            return;
        }
        endedFixes = phoneFixes;
        endedMs = nowMs - _phoneSinceMs;
        phoneFixes = 0;
        _ended = true;
    }
}

//! How long without an own fix makes the watch ask the phone, in ms. 5 s is the
//! window in which off-route already lost its count (`OffRoute.WINDOW_MS`,
//! RF-11) and stays below the 8 s lead of the turn warning: with the request
//! going out at 5 s, the phone fix arrives before the rider misses a turn.
//! Below that, motorcycle GPS in a city fails all the time (overpass, short
//! tunnel) and the phone would turn on and off the whole trip.
//!
//! Outside the canary build it is this one; `watch/canary.jungle` puts the twin below,
//! with 4 s, for `sim.py test --canary` to prove that `FixFallbackTest` bites
//! (`fourSecondsWithoutFixDoesNotAsk` must fail).
(:no_canary)
function fixFallbackAskMs() as Number {
    return 5000;
}

(:canary)
function fixFallbackAskMs() as Number {
    return 4000;
}
