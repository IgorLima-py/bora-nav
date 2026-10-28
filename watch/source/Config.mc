import Toybox.Application.Storage;
import Toybox.Lang;

//! **Fine tuning without a cable** (C5, `05 §CONFIG`): the numbers the rider
//! wants to tweak after riding — warning lead time, its floor, near
//! warning, vibration pulse, initial zoom, corridor brightness, HUD scale,
//! since C10 the HUD anti burn-in orbit (amplitude and step) and, since
//! C16.5, the size of each HUD group — arrive from the phone in the `CONFIG`
//! message (0x09), no sideload.
//!
//! **The watch is the authority on the ranges.** The phone only packs; this module
//! refuses, and logs why. A key outside its range refuses the **whole**
//! message: applying half of an adjustment is a state nobody asked for.
//!
//! Applies **without restarting**: whoever uses a value reads it from here at the time of use
//! (`AlertPolicy`, `MapRenderer`, `Hud`, `TurnArrow`), and the `Hud` rebuilds its fonts
//! when [revision] changes. Saves to `Storage` (key `config`, `03 §Storage`) and
//! [restore] brings everything back on the next launch.
module Config {

    //! Key ids on the wire (`05 §CONFIG`), mirror of `CONFIG_KEYS` in
    //! `tools/packer.py` and of `ConfigKey.kt`. The array index is `id - 1`.
    const KEY_LEAD_S = 1;
    const KEY_LEAD_MIN_M = 2;
    const KEY_NEAR_M = 3;
    const KEY_PULSE_MS = 4;
    const KEY_ZOOM = 5;
    const KEY_CORRIDOR_PCT = 6;
    const KEY_HUD_PCT = 7;
    const KEY_ORBIT_PX = 8;
    const KEY_ORBIT_S = 9;
    //! C16.5: the size of each HUD group, in %, on top of `hud_pct` (see [groupPct]).
    const KEY_DIST_PCT = 10;
    const KEY_ETA_PCT = 11;
    const KEY_TEXT_PCT = 12;
    const KEY_ARROW_PCT = 13;
    //! v1.1.5: the warning plate's padding, in %, at the sides and at top and bottom (see [plateWidePct]).
    const KEY_PLATE_W_PCT = 14;
    const KEY_PLATE_H_PCT = 15;
    //! C16: the GPS gap drill, in minutes after departure (see [gpsDrillMin]).
    const KEY_GPS_DRILL_MIN = 16;
    //! C16: the map test switches, 0/1, sent from the phone (see [streetImage]).
    const KEY_STREET_IMG = 17;
    const KEY_MAP_TILT = 18;
    const KEY_STREET_16BIT = 19;
    //! C16 (v1.2.5): the street image diagnostic lever, 0 to 10 (see [streetDiag]).
    const KEY_STREET_DIAG = 20;
    //! The lever's ceiling, the same 10 as in [MAXS] (a literal there, because the phone's `WatchSettingsTest`
    //! reads `MAXS` and only resolves numbers and `DesignTokens` constants).
    const STREET_DIAG_MAX = 10;
    //! C16 (v1.2.7): the wrist vibration, 0/1, sent from the phone (see [vibrateOn]).
    const KEY_VIBE_ON = 21;
    //! C16.6 (v1.2.9): the radar warning vibration, 0/1, separate from 21 (see [radarVibrate]).
    const KEY_RADAR_VIBE = 22;
    const KEY_COUNT = 22;

    const NAMES = ["lead_s", "lead_min_m", "near_m", "pulse_ms", "zoom", "corridor_pct", "hud_pct", "orbit_px", "orbit_s",
        "dist_pct", "eta_pct", "text_pct", "arrow_pct", "plate_w_pct", "plate_h_pct",
        "gps_drill_min", "street_img", "map_tilt", "street_16bit", "street_diag", "vibe_on", "radar_vibe"] as Array<String>;

    //! Defaults: the values the code had before C5 (`AlertPolicy` 8 s,
    //! 80 m and 25 m; 200 ms pulse; zoom 1 = 1.2 m/px; grays and HUD as they are).
    //! The orbit (C10) is the exception: its default is the ceiling (`ORBIT_MAX_PX`), and the
    //! step is the maximum (60 s), which spreads the wear the most per minute.
    //! The plate (v1.1.5) comes out tight in height (`plate_h_pct` 0, Igor's choice
    //! on 2026-10-18, looking at the photos at 100, 50 and 0%) and with the usual gap
    //! at the sides (`plate_w_pct` 100). The GPS drill (C16) comes out off, and the
    //! map switches (C16) on, like the watch menu with no saved value. The street diagnostic
    //! lever (v1.2.5) comes out at 0, the normal drawing. The vibration (v1.2.7) comes out
    //! off, as it has been since 2026-10-02 (`AlertPolicy`): Igor turns it on from the phone to test.
    //! The radar one (v1.2.9) comes out on: a radar is the warning that costs the most to miss.
    const DEFAULTS = [8, 80, 25, 200, 1, 100, 100, DesignTokens.ORBIT_MAX_PX, 60, 100, 100, 100, 100, 100, 0, 0,
        1, 1, 1, 0, 0, 1] as Array<Number>;

    //! Ranges approved by Igor on 2026-09-30 (DECISIONS §C5). Zoom goes up to 3
    //! because 4 onward are the browse levels (`NavState.BROWSE_ZOOM_INDEX`),
    //! which are not riding zoom. The HUD scale and each group's come from
    //! `DesignTokens`: the floor is the legibility one (no text below 13 px,
    //! C16.5) and the ceiling is the glass, both computed by `design_tokens.py`.
    //!
    //! **Orbit (C10):** `orbit_px` 0 turns it off; the ceiling is the `ORBIT_MAX_PX` that
    //! `design_tokens.py` computes (the largest amplitude whose cost at the ceiling of the HUD
    //! scale fits the limit, `DECISIONS.md` §2026-10-10 — C10). `orbit_s` is
    //! how long the HUD stays at each of the 8 points of the ring: 10..60 s, and the ceiling
    //! of 60 s guarantees that two consecutive minutes never repeat the pixel.
    //!
    //! **Plate padding (v1.1.5):** 0..100%, only tightens. 100% is the plate that
    //! `design_tokens.py` proves on the glass at the ceiling of the scale; above that it
    //! would grow beyond what the calculation checked.
    //!
    //! **GPS drill (C16):** 0 turns it off; up to 30 min after departure. The
    //! map switches and the vibrations are 0 or 1, and the streets lever goes from 0 to 10.
    const MINS = [4, 30, 10, 100, 0, 50, DesignTokens.HUD_SCALE_MIN_PCT, 0, 10, DesignTokens.HUD_SCALE_MIN_PCT,
        DesignTokens.HUD_SCALE_MIN_PCT, DesignTokens.HUD_SCALE_MIN_PCT, DesignTokens.HUD_SCALE_MIN_PCT, 0, 0, 0,
        0, 0, 0, 0, 0, 0] as Array<Number>;
    const MAXS = [15, 200, 60, 500, 3, 160, DesignTokens.HUD_SCALE_MAX_PCT, DesignTokens.ORBIT_MAX_PX, 60,
        DesignTokens.HUD_SCALE_MAX_PCT, DesignTokens.HUD_SCALE_MAX_PCT, DesignTokens.HUD_SCALE_MAX_PCT,
        DesignTokens.HUD_SCALE_MAX_PCT, 100, 100, 30, 1, 1, 1, 10, 1, 1] as Array<Number>;

    const STORAGE_KEY = "config";

    //! Values in use, indexed by `id - 1`. The launch [restore] rebuilds them
    //! from [DEFAULTS]; the literal here only holds until it runs.
    var values as Array<Number> = [8, 80, 25, 200, 1, 100, 100, DesignTokens.ORBIT_MAX_PX, 60, 100, 100, 100, 100, 100, 0, 0,
        1, 1, 1, 0, 0, 1] as Array<Number>;

    //! Goes up with every applied adjustment: the `Hud` compares it with its own to know whether
    //! it needs to rebuild the fonts.
    var revision as Number = 0;

    //! Ids that the last adjustment brought (all of them, on "back to default"). The app looks
    //! here to know whether the zoom has to change now.
    var lastKeys as Array<Number> = [] as Array<Number>;

    //! The corridor's 4 grays with the brightness applied (see [corridorColor]).
    var corridorColors as Array<Number> = [0x9A9A9A, 0x808080, 0x686868, 0x545454] as Array<Number>;

    function leadSeconds() as Float {
        return (values[KEY_LEAD_S - 1] as Number).toFloat();
    }

    function leadMinM() as Float {
        return (values[KEY_LEAD_MIN_M - 1] as Number).toFloat();
    }

    function nearM() as Float {
        return (values[KEY_NEAR_M - 1] as Number).toFloat();
    }

    function pulseMs() as Number {
        return values[KEY_PULSE_MS - 1] as Number;
    }

    function zoomIndex() as Number {
        return values[KEY_ZOOM - 1] as Number;
    }

    //! HUD orbit amplitude, in px (C10). 0 = stopped.
    function orbitPx() as Number {
        return values[KEY_ORBIT_PX - 1] as Number;
    }

    //! Seconds the HUD stays at each orbit point.
    function orbitStepS() as Number {
        return values[KEY_ORBIT_S - 1] as Number;
    }

    //! The side plate padding, in % (v1.1.5, Igor's request on 2026-10-18): 100 is the usual gap
    //! between the text and the plate edge, 0 puts the text against the frame. The letters do not change.
    function plateWidePct() as Number {
        return values[KEY_PLATE_W_PCT - 1] as Number;
    }

    //! The plate padding at top and bottom, in %: 0 (the default) leaves the arrow, the number and the name
    //! 2 px from the frame and the rule, and 100 is the tall plate, with the top line at the height of the
    //! tallest of the 31 arrows (`Hud.drawPlate`).
    function plateTallPct() as Number {
        return values[KEY_PLATE_H_PCT - 1] as Number;
    }

    //! The GPS gap drill ([GpsDrill], C16): how many minutes after
    //! departure the watch fakes 90 s without GPS, once per trip. 0 (the default) turns it off.
    function gpsDrillMin() as Number {
        return values[KEY_GPS_DRILL_MIN - 1] as Number;
    }

    //! **The map switches (C16):** "Ruas em imagem", "Mapa deitado" and the 16-bit image,
    //! the same test settings as the watch menu, brought to the phone so Igor can compare on the
    //! wrist without ending the route (2026-10-19: the streets did not show up on the first ride with the image).
    //! What counts for the map is the `Storage` preference that the menu also writes: the app rewrites it
    //! when one of these keys arrives (`MotoNavApp.applyMapSwitches`), and the last one to touch it wins.
    function streetImage() as Boolean {
        return (values[KEY_STREET_IMG - 1] as Number) == 1;
    }

    function mapTilt() as Boolean {
        return (values[KEY_MAP_TILT - 1] as Number) == 1;
    }

    function street16Bit() as Boolean {
        return (values[KEY_STREET_16BIT - 1] as Number) == 1;
    }

    //! **The street diagnostic lever (C16, v1.2.5):** on the wrist the street image is assembled and
    //! pasted but does not show up (log of 2026-10-22), while street by street the avenue shows up. 1 is the street
    //! by street control; 2 and 3 the single image of 454 and 480 px, 4 to 7 the probes and 8 to [STREET_DIAG_MAX] the
    //! tile grids (`StreetCache.DIAG_NAMES`, v1.2.9); 0 is the normal drawing. It is a single number, so only one
    //! holds at a time.
    function streetDiag() as Number {
        return values[KEY_STREET_DIAG - 1] as Number;
    }

    //! **The wrist vibration (C16, v1.2.7):** turned off on the bench on 2026-10-02 (Igor's request,
    //! `DECISIONS.md`), it was an `AlertPolicy` constant; it became a key so Igor can turn it on from the
    //! phone and decide on the road whether it stays. Applies to turn warnings, arrival and leaving the route.
    function vibrateOn() as Boolean {
        return (values[KEY_VIBE_ON - 1] as Number) == 1;
    }

    //! **The radar vibration (C16.6, v1.2.9):** Igor wanted a separate key, apart from [vibrateOn];
    //! it applies to the single buzz when a radar's plate shows up (`AlertPolicy.alertRadar`).
    function radarVibrate() as Boolean {
        return (values[KEY_RADAR_VIBE - 1] as Number) == 1;
    }

    function corridorColor(lod as Number) as Number {
        return corridorColors[lod] as Number;
    }

    //! The effective scale of a HUD group (`KEY_DIST_PCT`..`KEY_ARROW_PCT`), in %:
    //! `hud_pct` times the group's %, **clamped to the `DesignTokens` range**. The
    //! `design_tokens.py` proves the 3 states fit on the glass with all the
    //! groups at the ceiling, and shrinking one text never pushes another off the glass: with the
    //! clamp, any mix of adjustments fits.
    function groupPct(key as Number) as Number {
        var pct = ((values[KEY_HUD_PCT - 1] as Number) * (values[key - 1] as Number) + 50) / 100;
        if (pct < DesignTokens.HUD_SCALE_MIN_PCT) {
            return DesignTokens.HUD_SCALE_MIN_PCT;
        }
        return pct > DesignTokens.HUD_SCALE_MAX_PCT ? DesignTokens.HUD_SCALE_MAX_PCT : pct;
    }

    //! `px` size from `DesignTokens` at the scale of group `key`, rounded. **The
    //! same integer arithmetic as `escala()` in `tools/design_tokens.py`**: it is what
    //! guarantees that the range generated there holds here.
    function groupPx(px as Number, key as Number) as Number {
        return (px * groupPct(key) + 50) / 100;
    }

    //! Payload of a `CONFIG` (without the header): validates everything, and only then applies.
    //! `persist` false is for tests, which must not dirty the app's `Storage`.
    //! Returns whether it applied.
    function applyPayload(payload as ByteArray, persist as Boolean) as Boolean {
        // A refused one brings no key at all: without this the app saw the keys of the
        // last accepted adjustment and changed the zoom because of a refused CONFIG (C5 reviewer).
        lastKeys = [] as Array<Number>;
        if (payload.size() < 1) {
            Diag.add("config refused: empty");
            return false;
        }
        var count = payload[0] as Number;
        if (!Protocol.hasBytes(payload, 1, count * 3)) {
            Diag.add("config refused: short");
            return false;
        }
        if (count == 0) {
            reset(persist);
            Diag.add("config default applied");
            return true;
        }

        var ids = [] as Array<Number>;
        var given = [] as Array<Number>;
        for (var i = 0; i < count; i++) {
            var id = payload[1 + 3 * i] as Number;
            if (id < 1 || id > KEY_COUNT) {
                // Key from a newer companion: the two sides bump their versions
                // each at its own pace, and this must not block the rest.
                Diag.add("config key " + id.toString() + " ignored");
                continue;
            }
            if (ids.indexOf(id) >= 0) {
                Diag.add("config refused " + NAMES[id - 1] + " repeated");
                return false;
            }
            ids.add(id);
            given.add(Protocol.readU16(payload, 2 + 3 * i));
        }
        if (ids.size() == 0) {
            Diag.add("config refused: no known key");
            return false;
        }

        var next = merge(ids, given);
        if (next == null) {
            return false;
        }
        commit(next, ids, persist);

        var text = "config";
        for (var i = 0; i < ids.size(); i++) {
            text += " " + NAMES[(ids[i] as Number) - 1] + "=" + (given[i] as Number).toString();
        }
        Diag.add(text + " applied");
        return true;
    }

    //! At launch: restores the saved adjustment, by the same rules as one arriving
    //! from the phone. An invalid saved one (old version, corrupted `Storage`) is
    //! deleted and the watch stays at the default.
    function restore() as Void {
        // Start from the default through the same `commit` as always, and not from the initial
        // literals of [values] and [corridorColors] (C5 reviewer).
        commit(DEFAULTS.slice(0, null) as Array<Number>, [] as Array<Number>, false);
        var stored = Storage.getValue(STORAGE_KEY);
        if (stored == null) {
            return;
        }
        if (!(stored instanceof Dictionary)) {
            discard("format");
            return;
        }
        var dict = stored as Dictionary;
        var ids = [] as Array<Number>;
        var given = [] as Array<Number>;
        for (var id = 1; id <= KEY_COUNT; id++) {
            var value = dict.get(id);
            if (value == null) {
                continue;
            }
            if (!(value instanceof Number)) {
                discard(NAMES[id - 1]);
                return;
            }
            ids.add(id);
            given.add(value as Number);
        }
        var next = merge(ids, given);
        if (next == null) {
            discard("range");
            return;
        }
        commit(next, ids, false);

        var text = "config";
        for (var i = 0; i < KEY_COUNT; i++) {
            if ((values[i] as Number) != (DEFAULTS[i] as Number)) {
                text += " " + NAMES[i] + "=" + (values[i] as Number).toString();
            }
        }
        Diag.add((text.equals("config") ? "config default" : text) + " restored from Storage");
    }

    //! Everything back to default. `persist` clears the `Storage` too.
    function reset(persist as Boolean) as Void {
        var all = [] as Array<Number>;
        for (var id = 1; id <= KEY_COUNT; id++) {
            all.add(id);
        }
        commit(DEFAULTS.slice(0, null) as Array<Number>, all, false);
        if (persist) {
            Storage.deleteValue(STORAGE_KEY);
        }
    }

    //! The current values with `ids`/`given` on top, or `null` (with the refusal's
    //! log line) if any falls outside the range.
    function merge(ids as Array<Number>, given as Array<Number>) as Array<Number>? {
        var next = values.slice(0, null) as Array<Number>;
        for (var i = 0; i < ids.size(); i++) {
            var index = (ids[i] as Number) - 1;
            var value = given[i] as Number;
            var low = MINS[index] as Number;
            var high = MAXS[index] as Number;
            if (value < low || value > high) {
                Diag.add("config refused " + NAMES[index] + "=" + value.toString() + " outside "
                    + low.toString() + ".." + high.toString());
                return null;
            }
            next[index] = value;
        }
        // The near warning within the minimum lead: otherwise the 1st warning would already
        // go out in the 2nd's window, and the turn would get only one (`AlertPolicy`).
        var near = next[KEY_NEAR_M - 1] as Number;
        var leadMin = next[KEY_LEAD_MIN_M - 1] as Number;
        if (near >= leadMin) {
            Diag.add("config refused near_m=" + near.toString() + " not lower than lead_min_m="
                + leadMin.toString());
            return null;
        }
        return next;
    }

    function commit(next as Array<Number>, ids as Array<Number>, persist as Boolean) as Void {
        values = next;
        lastKeys = ids;
        revision++;

        // Corridor brightness: the `MapRenderer` grays times the percentage,
        // channel by channel, capped at 0xFF.
        var pct = values[KEY_CORRIDOR_PCT - 1] as Number;
        var colors = [] as Array<Number>;
        for (var lod = 0; lod < MapRenderer.LOD_COLOR.size(); lod++) {
            var base = MapRenderer.LOD_COLOR[lod] as Number;
            var colour = 0;
            for (var shift = 16; shift >= 0; shift -= 8) {
                var channel = ((base >> shift) & 0xFF) * pct / 100;
                colour = (colour << 8) | (channel > 0xFF ? 0xFF : channel);
            }
            colors.add(colour);
        }
        corridorColors = colors;

        if (persist) {
            var dict = {} as Dictionary<Number, Number>;
            for (var id = 1; id <= KEY_COUNT; id++) {
                dict.put(id, values[id - 1] as Number);
            }
            try {
                Storage.setValue(STORAGE_KEY, dict);
            } catch (ex) {
                // Applied, but not saved: holds until the app closes.
                Diag.add("config not saved to Storage");
            }
        }
    }

    function discard(why as String) as Void {
        Storage.deleteValue(STORAGE_KEY);
        Diag.add("config from Storage discarded (" + why + ")");
    }
}
