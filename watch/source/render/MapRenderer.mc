import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;

//! Draws the track-up map (`03 §Rendering`, `01 §Identity`).
//!
//! Order per frame: corridor → route ahead → destination point → rider (sheet 4).
//!
//! **Screen sizes.** Every layout number below is in px of the reference glass (the Venu 4 45 mm, 454 px,
//! see [Screen]); the members that hold one are `var`s set in [initialize] through [Screen.px] / [Screen.pxf],
//! the identity at 454. The zoom is converted in **one place**, [beginAt]: `NavState.metersPerPx` is the ground
//! per px of the reference glass, and `_scale` the ground per px of **this** screen, so the same area shows on
//! every size. Everything that is a distance on the glass (cull radius, widths, puck) is scaled with it;
//! everything that is a distance on the ground (meters, the zoom levels, [WIDTH_REF_MPP]) is not.
//!
//! **Tilted** (v1.1.5, sheet 8, option 25): everything that goes to the screen passes through a vertical scale
//! [_k] around the rider, `y' = anchor + K · (y − anchor)`. It is a flattened map, with no vanishing
//! point: widths do not flatten and the destination point stays round. The street image
//! ([StreetCache]) is pasted with the same K in the matrix.
//!
//! Per-vertex transform, with sine and cosine computed **once per
//! frame**:
//!
//! ```
//! screen = anchor + R(heading) · (p − center) / metersPerPixel
//! ```
//!
//! **The sign of the angle is R(+heading), not R(−heading).** The world is (x = east,
//! y = north) and the heading `h` is 0 at north increasing toward east, so the displacement
//! vector is `(sin h, cos h)`; applying the rotation by angle `θ` in
//! mathematical coordinates it becomes `(sin(h−θ), cos(h−θ))`, which only points
//! up on the screen when `θ = h`. With `θ = −h` the map rotated `2h` — invisible
//! when stopped (h = 0) and completely wrong in motion. See `DECISIONS.md`
//! §Track-up rotation.
//!
//! The rider stays **at the center of the screen**. The first version anchored it at (227,
//! 295), arguing that on a motorcycle what lies ahead matters — but
//! in the road test the practical effect was the opposite: stuck to the bottom strip,
//! it was squeezed against the speed. Centering was Igor's request
//! after riding with both (`DECISIONS.md`, 2026-07-31).
class MapRenderer {

    //! The rider's `x` on the reference glass; [ANCHOR_X] is it on this screen. The phone's preview mirrors the
    //! reference values of this class (`WatchFace.kt`, `WatchFaceTest`).
    static const ANCHOR_X_REF = 227;
    var ANCHOR_X as Number;
    //! **The rider moves down from the center to y = 276** (C15b, dark Waze look approved by Igor on
    //! 2026-10-14): more road ahead, which is what the bike asks for and what Waze does. The decision of
    //! 2026-07-31 (center it) held with the speed strip stuck at the bottom; it no longer exists.
    //! **v1.1.5: to y = 330** (sheet 6), with the sign on top and the map tilted.
    var ANCHOR_Y as Number;

    //! Largest distance from the anchor to a lit pixel, in pixels.
    //!
    //! **The Venu 4 screen is round**, so the point farthest from the center is
    //! at 227 px — the radius —, not 321, which is the half-diagonal of a 454
    //! square. Inherited from a rectangle, 321 asked for a cull radius √2 times larger
    //! than the screen uses: **double the area and double the streets** loaded per
    //! frame, all outside the glass. It was half the cost that blew the watchdog on
    //! 2026-08-01.
    //! With the rider at y = 330 the lit pixel farthest from the anchor is the one at the top of the glass: 227 + 103.
    //! Tilted, that pixel shows the world at 330 / K ≈ 458 px from the rider ([beginAt]).
    //! In px of this screen, like [ANCHOR_Y]: the cull radius is `CORNER_PX` times the ground per px of this
    //! screen, which is the same number of meters on every size.
    var CORNER_PX as Float;

    //! Cull margin, so a line entering through the edge does not vanish.
    //!
    //! Raised from 1.2 to 1.4 together with the visible-ways cache: the list stays
    //! valid for [CACHE_REBUILD_M] of displacement, and that slack has to fit
    //! inside the margin, otherwise a street would enter the screen before the cache is
    //! rebuilt and would show up late.
    const CULL_MARGIN = 1.4;

    //! How far the center may move before the visible-ways list is rebuilt.
    //! It must be smaller than the slack that [CULL_MARGIN] gives over the screen radius.
    const CACHE_REBUILD_M = 25.0;

    //! The route color comes from `DesignTokens` (C4): purple ahead, faded purple behind.

    //! Route (C15b): 12 px with a 3 px casing on each side, and **without the stretch already ridden**, like
    //! Waze. The casing is the same line, wider, underneath. Widths at the riding zoom; in the
    //! frame [_routeWidth] and [_casingWidth] apply ([widthScale]). **v1.1.5: Maps blue**
    //! (`ROUTE_LINE`) with the `ROUTE_EDGE` casing; cyan stayed on the rider.
    //! In px of this screen.
    var WIDTH_AHEAD as Number;
    var WIDTH_CASING as Number;

    //! Corridor by road class (`01 §Identity`): dark gray, always more
    //! faded than the route. It is peripheral reference — what must jump to the
    //! eye is the white line of the path, and a very light street mesh competes
    //! with it exactly where the eye has the least time to search.
    //! **Lightened on 2026-08-01.** `01 §Identity` asks for
    //! `8A/6E/56/3C`; the code was one step **below** that
    //! (`70/5A/48/38`), for fear of the mesh competing with the white line. On an
    //! AMOLED under sun, with the watch at arm's length inside the
    //! helmet, `#383838` on a 1 px line is not discreet: it is invisible. A
    //! street drawn that cannot be seen costs exactly the same frame as
    //! a visible street and returns nothing.
    //!
    //! The hierarchy still stands — light expressway, dark local, and **all
    //! well below the pure white of the route**, which is what has to jump to the eye.
    //! This is a tuning knob: if it gets cluttered on the road, darken it again.
    //! **C15b: from `DesignTokens`** (`tokens.json`, `mapa`): dark slate, `#3A4550` → `#262E36`.
    //! **v1.1.5: Maps on black** (sheet 8): the expressway in `#5E5442`, the others in slate.
    //! **v1.2.3: lightened again** (`#8C7A58` → `#4A535E`): on the wrist only the expressway showed,
    //! the local had 1.45:1 against black. Each class stays below the route (6.45:1).
    static const LOD_COLOR = DesignTokens.ROAD_COLORS;

    //! Collector went up to 2 px for the same reason as the color: 1 px of mid gray
    //! on a 454 px screen is a hint of a street, not a street.
    //! **C15b: wide, dark strips, 14/11/9/7 px** (dark Waze: texture, not frame).
    //! **v1.1.5: 16/12/9/7** (sheet 8), with the black casing only inside the image ([StreetCache]).
    //! **C16.5: these widths apply at the riding zoom ([WIDTH_REF_MPP])** and thin out when the
    //! map opens ([widthScale]). In px of the reference glass: [beginAt] turns them into px of this screen.
    static const LOD_WIDTH = DesignTokens.ROAD_WIDTHS;

    //! The scale at which the `DesignTokens` widths apply: 1.2 m/px, the riding zoom
    //! (`NavState.ZOOM_LEVELS[1]`), where C15b approved them. In meters per px of the **reference** glass,
    //! like `NavState.metersPerPx`: it is compared with that, never with [_scale].
    const WIDTH_REF_MPP = 1.2;

    //! How much the width follows the zoom: `(1.2 / m per px) ^ 0.5`, between [WIDTH_MIN_SCALE] and 1.
    //! With a fixed width in pixels, at 2.5 m/px the 14 px avenue was 35 m wide and the map became a
    //! gray block (`shots/tela_far.png`, 2026-10-17); Maps and Waze thin the street as the
    //! map opens. Half power, not the whole proportion, because a 3 px street vanishes on the watch.
    //! A choice based on the photo, not a measurement: 2.5 m/px gets 69% (14 → 10 px), 5 gets 49%.
    const WIDTH_EXPONENT = 0.5;
    const WIDTH_MIN_SCALE = 0.35;

    //! The route thins less than the street (exponent 0.35, floor 60%): it is the information.
    const ROUTE_WIDTH_EXPONENT = 0.35;
    const ROUTE_MIN_SCALE = 0.6;

    //! Finest LOD drawn with antialiasing: only the expressways, as Igor chose on the bench of
    //! C6b (2026-10-03, "middle ground and antialias on the expressways"). C16.5 tried all the LODs and
    //! went back: in the simulator the corridor went from 15 to 31–47 ms per frame, the leash fell to the
    //! floor (220) and the photo came out with almost no streets. The cost on the wrist was not measured (left for C16);
    //! 3 turns it on for all.
    const ANTIALIAS_MAX_LOD = 0;

    //! Round join **only where the line bends** (C16.5). A thick line on the `Dc` ends flat, and at a
    //! bend it opens a wedge of size `radius · sin θ`; a disc at the vertex closes the wedge. On a straight
    //! the disc changes nothing and costs a call, so it only enters when the wedge would exceed
    //! [JOIN_PX] pixels. The 1st stroke bench (`sim.py shots --traco`, 2026-10-17) used 0.75 px and
    //! the route casing on a curve with a vertex every 2.5 px came out jagged: each wedge too small
    //! to earn a disc became a tooth. With 0.25 px the curve gets a disc at every vertex and
    //! the straight still gets none. A choice based on the photo, not a cost measurement.
    const JOIN_PX = 0.25;

    //! A disc costs like a short segment: one call to the `Dc` and no transform.
    const DISC_COST = 2;

    //! The corridor plan ([planCorridor]) looks at each way once: two reads and one computation,
    //! less than one point of the [drawWay] traversal. A choice, not a measurement.
    const PLAN_COST = 1;

    //! The smallest % of the ceiling that the plan uses ([_costPct]). With it, the drawing exceeds the plan by at
    //! most double, and the absolute cutoff in [WORK_MAX] holds the rest. A choice, not a measurement.
    const COST_PCT_MIN = 50;

    //! Finest street LOD that gets round caps and joins. **Only the expressways and arterials**:
    //! the corridor's ways have 2.5 to 3 points (454 ways and 1,378 points in LOD 0 of
    //! `sim.py shots`), so two discs per way nearly double the calls to the `Dc`, and in the simulator
    //! that dropped the leash to the floor and the map came out with almost no streets (2026-10-17: budget of
    //! 220 to 280 against 416 to 834 of the previous stroke, in the same scene). On the 9 and 7 px strips the
    //! bend wedge is 2 px and barely shows. A choice based on the photo and the simulator leash; the cost on the
    //! wrist is left for C16.
    const CAP_MAX_LOD = 1;

    //! On streets the join only enters on a real bend, a wedge of 1 px or more: the street does not have the dense
    //! curve of the route, where the [JOIN_PX] of 0.25 px avoids the jaggedness. A choice, not a measurement.
    const STREET_JOIN_PX = 1.0;

    //! Above this scale the LOD disappears. **Igor, 2026-10-02 (C6b, on the bench): streets
    //! must appear at any zoom** — the old ceiling (`40/20/8/4`) erased
    //! collectors and locals already at 10 m/px. All went to the highest zoom level
    //! (`NavState.ZOOM_LEVELS`, 20 m/px). The CPU cost the ceiling held back is
    //! contained by the corridor budget ([drawCorridor]): in a dense region the
    //! first to vanish is the local and the last, the expressway. In meters per pixel.
    static const LOD_MAX_SCALE = [20.0, 20.0, 20.0, 20.0] as Array<Float>;

    //! **Out in v1.** The north needle is a development instrument: it
    //! exists to prove on the screen that track-up rotates, and that is how the inverted
    //! rotation showed up. Igor wants the map clean in the final app, so this is
    //! a switch and not a line to hunt later — set to `false` in the
    //! F4 visual polish (`07-ROADMAP.md`).
    const SHOW_NORTH = false;

    // The rider and the end of the route (sheet 4, rider 6 and destination 8): measures from the sheet, in px
    // of the reference glass. The frame draws the copies in px of this screen (`_ringR` and the like, set in
    // [initialize]); these stay as the sheet's numbers, for [puckLitPx] and the burn-in test.
    static const PUCK_RING_R = 22;
    static const PUCK_RING_W = 4;
    static const PUCK_DASHES = 16;
    static const PUCK_DASH_DEG = 10;
    //! The tip of the "?": base 30, height 30 x 33.2 / 52 = 19.2, with the ring center at 45% of it.
    static const PUCK_ARROW_HALF = 15.0;
    static const PUCK_ARROW_BELOW = 8.6;
    static const PUCK_ARROW_ABOVE = 10.5;
    //! The faded "?" in the ring, with no position: the `Signs` 190 frame at 30 px.
    static const PUCK_SIGN_PX = 30;
    static const DEST_DOT_R = 10;
    static const DEST_EDGE_R = 13.5;
    static const DEST_MAX_PX = 240.0;

    //! The rider ring states ([puckState]).
    static const PUCK_OK = 0;
    static const PUCK_RECALC = 1;
    static const PUCK_WEAK = 2;
    static const PUCK_LOST = 3;
    static const PUCK_ARRIVED = 4;

    //! Compass rose: center and lengths of the needle and the "N" label.
    //! It sits in the upper right corner, inside the screen circumference even
    //! with the "N" at the farthest point.
    var NORTH_CX as Number;
    var NORTH_CY as Number;
    var NORTH_NEEDLE_PX as Number;
    var NORTH_LABEL_PX as Number;
    const COLOR_NORTH = 0xFF4040;

    //! How many segments the last frame actually drew (route + corridor).
    //!
    //! It is the metric that was missing: "the map is lagging" is an opinion, "1,240 segments
    //! in 180 ms" is a number that says what to cut. It goes out in [frameSummary], which the
    //! app sends to the phone every 10 s — the previous version drew this on the
    //! screen, and the line cost 34 px of map per frame.
    var segmentsDrawn as Number = 0;

    //! Only the corridor's, from the last frame: the test of the streets that blinked (C16.5) looks at this.
    var corridorSegments as Number = 0;

    // Frame statistics accumulated between two telemetry sends. It lives here
    // because `MotoNavApp` already holds the renderer and `NavView` is not reachable
    // from it — and because measuring the drawing is the business of whoever draws.
    var frames as Number = 0;
    var frameSumMs as Number = 0;
    var frameMaxMs as Number = 0;

    // ── Watchdog leash ───────────────────────────────────────────────────────
    //
    // The `venu445mm` kills an app that exceeds `watchdogCount: 240000` instructions
    // **in a single callback**, and that is how the app died on 2026-08-01: the
    // watch's `CIQ_LOG.YML` names `onUpdate → draw → drawRoute →
    // refreshRouteRanges → visible`, that is, the frame ran out of budget in the middle
    // of the work. It is not a hot spot: it is the **sum** of the frame.
    //
    // There is no API to read the watchdog counter, so the app counts what it
    // does itself. A *work point* is a rectangle test, a point test
    // or a drawn segment — quantities proportional to instructions, with a
    // constant stable enough to serve as a leash.
    //
    // **The leash is adaptive on purpose.** A fixed ceiling chosen here would be
    // one more limit calibrated for one situation and wrong in the next — the failure
    // mode that already cost two rounds in this project (`DECISIONS.md` §The deadline that
    // killed the good query). Here the clock rules: if the frame exceeded
    // [FRAME_TARGET_MS], the corridor shrinks; if there was slack **and there was a street
    // wanting to enter**, it grows. The target stays well below what kills, so
    // not even the transient gets close to the watchdog.
    //
    // What gets cut is always the corridor, never the route: the corridor is peripheral
    // reference and the path line is the information the app exists for.

    //! Time target per frame. The watchdog fires shortly after ~185 ms
    //! measured on this watch (a 184 ms frame with 385 ways died), so the target
    //! is half of that.
    const FRAME_TARGET_MS = 90;

    //! How much of the frame the **corridor** may take.
    //!
    //! The first version of the leash reacted to the whole frame time, and that
    //! was wrong in a way only the hardware showed: in the log of
    //! 2026-08-01, `frame avg 143ms · corr 45 route 89 hud 8`. The frame blew the
    //! target because of the **route** — which the leash, on purpose, never cuts — and
    //! the corridor took the beating, shrunk to the floor frame after frame.
    //! `work 1239/220 CORTOU`: of 262 visible streets, about 17 drawn.
    //!
    //! *A controller must measure the variable it controls.* The leash
    //! controls the corridor, so it measures the corridor. The whole frame is still
    //! watched, but by a safety limit, not by the target.
    const CORRIDOR_TARGET_MS = 45;

    //! Above this the frame is too close to the watchdog and the corridor shrinks,
    //! whoever is to blame. It is the net under the net, **in work points**:
    //! the watchdog counts instructions, and [work] is the ruler for them that the app has.
    //!
    //! Until `v1.2.9` this net was the whole frame time (130 ms), and that pinned
    //! the leash to the floor all night (C16.6, `work peak 1017/220 CAPPED`): with the route
    //! at ~86 ms and the HUD at ~35, no frame was below 110 ms for it to grow.
    //! Time does not say whether the watchdog is near: 208 ms frames lived in `v1.2.9`, and
    //! the 184 ms one that died on 2026-08-01 cost ~3000 points. The difference is native
    //! drawing (thick line with antialiasing, image pasting), which spends time and
    //! almost no instructions. Four fifths of [WORK_FATAL]: slack chosen.
    const WORK_HARD = 2400;

    //! A drawn segment costs more than a box test: two full
    //! transforms and a `drawLine` against four comparisons.
    const SEGMENT_COST = 3;

    //! Budget floor: even in the worst urban frame, the expressways and arterials
    //! of the immediate surroundings stay drawn. A map with no streets around
    //! is worse than a map with the main ones.
    const WORK_MIN = 220;

    //! While the visible-ways list is being rebuilt, a third of the budget goes
    //! to the sweep and the rest to drawing (C16.5). At the floor that is 73 sweep
    //! points, and the `WatchdogTest` city (~290 points) closes the list in four
    //! frames; drawing gets 147, close to the 20–34 segments the watch drew
    //! at the floor in C16. A choice, not a measurement: the watch will say if the list lags.
    const SCAN_SHARE = 3;

    //! How far the scale moves, as a fraction of the sweep scale, to be worth a new list in the middle
    //! of another ([scaleJumped]). The smallest knob step is 1.2 → 0.6 (50%); the [CULL_MARGIN] of
    //! 40% over the radius covers the rest. A choice, not a measurement.
    const RESCAN_SCALE = 0.1;

    //! Absolute ceiling, and it is **not** decorative: the frame that killed the app on
    //! 2026-08-01 cost around 3,000 work points, which puts the
    //! watchdog at ~80 instructions per point. 1,800 for the corridor plus what the
    //! route spends leaves the worst frame at about three quarters of what kills, with the
    //! adaptive loop taking care of the rest. Raising this is touching the watchdog
    //! again.
    const WORK_MAX = 1800;

    //! How much, in this same currency, the frame that **killed the app** cost on
    //! 2026-08-01 — reconstructed from that day's corridor (~920 ways
    //! swept, ~75 drawn) and from the loop that `CIQ_LOG.YML` caught. It puts the
    //! `venu445mm` watchdog at around 80 instructions per work point.
    //!
    //! Not used in production: it is the ruler against which the watchdog test
    //! asserts that the frame stayed far from death. A number that only exists in a
    //! comment does not fail when someone contradicts it.
    const WORK_FATAL = 3000;

    //! Work points spent in the last frame (route + corridor).
    var work as Number = 0;

    //! The largest [work] since the last [resetFrameStats]. It is what goes to the
    //! telemetry: the watchdog kills on the **worst** frame, and the last frame of a
    //! 10 s window is almost never the worst.
    var workMax as Number = 0;

    //! How much the corridor may spend. It starts **below** what the watch can take
    //! because the first frame of a dense region is exactly the one with no
    //! measurement to guide it — it is cheaper to climb in two frames than to
    //! die on the first.
    var corridorBudget as Number = 800;

    //! Did the last frame leave out streets for lack of budget?
    var corridorCapped as Boolean = false;

    //! How many ways of each LOD the last frame planned to draw ([planCorridor]).
    var planned as Array<Number> = [0, 0, 0, 0] as Array<Number>;

    //! Corridor work points in the last frame: plan and drawing, without the sweep.
    var corridorWork as Number = 0;

    //! How much of the drawing ceiling ([planCorridor]) each LOD actually paid in the last frame, in
    //! %. The ceiling counts every segment and one disc per point; the real drawing skips the segment outside
    //! the view and the straight with no disc. With the pure ceiling, the `WatchdogTest` city at the floor of 220 closed
    //! the whole frame, route included, at 134 (C16.5, 2026-10-17): far fewer streets than before, in the
    //! most common case of the watch in São Paulo (the leash at the floor, C16).
    private var _costPct as Array<Number> = [100, 100, 100, 100] as Array<Number>;
    private var _planTrav as Array<Number> = [0, 0, 0, 0] as Array<Number>;
    private var _planBound as Array<Number> = [0, 0, 0, 0] as Array<Number>;

    //! The LOD of the first and last way drawn in the last frame, or -1. The last one stays on
    //! top; for the tests that the avenue does not vanish under the local street.
    var firstLodDrawn as Number = -1;
    var lastLodDrawn as Number = -1;

    //! Records the cost of a frame and **readjusts the leash**. Called by
    //! [NavView] at the end of `onUpdate`.
    function noteFrame(ms as Number) as Void {
        frames++;
        frameSumMs += ms;
        if (ms > frameMaxMs) {
            frameMaxMs = ms;
        }
        if (work > workMax) {
            workMax = work;
        }

        if (msCorridor > CORRIDOR_TARGET_MS || work > WORK_HARD) {
            // Shrinks fast: the risk of an expensive frame is the app dying.
            var down = corridorBudget * 2 / 3;
            corridorBudget = down < WORK_MIN ? WORK_MIN : down;
        } else if (corridorCapped) {
            // Grows **only when there was a lack of streets to draw** — without that the
            // budget would rise in open country and the first dense block
            // would catch the app with a loose leash.
            //
            // With wide slack the step is multiplicative, and that is what makes the
            // map fill in two or three frames instead of half a minute: the
            // difference between the floor and a full city is four times, and
            // adding 60 per frame Igor would see the street appear after the corner.
            // The growth ceiling is the **safety limit**, not the target. With
            // `ms < FRAME_TARGET_MS` here, the leash became a ratchet: it was enough for the
            // route to cost 89 ms for the frame to never be below 90, and then the
            // budget only knew how to go down — stuck at the floor forever, an absorbing
            // state. The same ratchet came back with the 130 ms ceiling
            // (C16.6), and that is why the slack is now counted in work: the step
            // only enters if the frame, added to it, is still below [WORK_HARD].
            // It is also the dead band against ping-pong around the limit.
            var up = corridorBudget;
            if (msCorridor * 3 < CORRIDOR_TARGET_MS && work + corridorBudget / 2 < WORK_HARD) {
                up += corridorBudget / 2;
            } else if (msCorridor * 2 < CORRIDOR_TARGET_MS && work + 60 < WORK_HARD) {
                up += 60;
            }
            corridorBudget = up > WORK_MAX ? WORK_MAX : up;
        }
    }

    //! Summary since the last [resetFrameStats], ready for the log: average, peak and
    //! how many segments the last frame drew.
    //!
    //! **The average alone lies.** A map that averages 30 ms and spikes to 400 ms
    //! when the rider reaches a dense region is felt as frozen, and the average
    //! does not show that — so the peak goes along with it.
    function frameSummary() as String {
        if (frames == 0) {
            return "frame no sample"; // lang: log
        }
        return "frame avg " + (frameSumMs / frames).toString()
            + "ms peak " + frameMaxMs.toString()
            + "ms n" + frames.toString()
            + " seg " + segmentsDrawn.toString()
            + " · corr " + msCorridor.toString()
            + " route " + msRoute.toString() // lang: log
            + " hud " + msHud.toString() + "ms"
            // The watchdog leash in three numbers: the window's worst frame, how
            // much the corridor may spend today and whether it fell short. `CAPPED` on with
            // the budget at the floor is the sign of "the region is too dense for this
            // zoom"; `CAPPED` off is slack. It is the peak, not the last frame:
            // the watchdog kills on the worst.
            + " · work peak " + workMax.toString() + "/" + corridorBudget.toString()
            + (corridorCapped ? " CAPPED" : "")
            + streetsSummary()
            + (_streets.diag != StreetCache.DIAG_OFF ? " · diag " + _streets.diag.toString() : "")
            // With the casing and the tilt on, the `frame avg` lines are told apart in `frames.py`.
            + (routeCasing ? " · casing" : "") // lang: log
            + (_k < 1.0 ? " · tilted" : (_streets.tiltRefused ? " · tilt failed" : "")); // lang: log
    }

    //! The image streets in the summary, short because the log send has a cap (`MAX_LOG_BYTES`):
    //! ` · img 2x 310ms/5p 412v max598` = two images ready in the window, the last took 310 ms
    //! adding 5 steps, with 412 ways, and the costliest step spent 598 points. ` slack 31` = the smallest
    //! slack in the window between the glass and the edge of the pasted image, in px; negative, the glass showed
    //! black at the edge. ` bare 4` = 4 frames with no image covering the glass, drawn street by
    //! street. Without the cache, nothing, and `corr` is the street drawing; with it, `corr` is pasting the image.
    function streetsSummary() as String {
        if (!imageOn()) {
            return "";
        }
        if (_streets.failed) {
            return " · img failed";
        }
        var s = _streets;
        var line = " · img " + s.builds.toString() + "x " + s.lastBuildMs.toString() + "ms/"
            + s.lastBuildSteps.toString() + "p " + s.lastBuildWays.toString() + "v max"
            + s.stepWorkMax.toString();
        var low = s.slackMin;
        if (low != null) {
            line += " slack " + (low as Number).toString();
        }
        if (s.fallbacks > 0) {
            line += " bare " + s.fallbacks.toString(); // lang: log
        }
        // ` cache 12/12` = of the window's pastes, how many found the image still in memory
        // (`isCached`). Fewer than the total: the pool recycled the image and it pasted empty (v1.2.6).
        if (s.cachedChecks > 0) {
            line += " cache " + (s.cachedChecks - s.cachedMisses).toString() + "/" + s.cachedChecks.toString();
        }
        return line;
    }

    function resetFrameStats() as Void {
        frames = 0;
        frameSumMs = 0;
        frameMaxMs = 0;
        workMax = 0;
        _streets.resetStats();
    }

    // Cost of each stage of the last frame, in ms. Without this, "the map is slow"
    // does not say whether the culprit is the corridor, the route, the HUD or `clear()` itself
    // — and guessing that has already cost two rounds.
    var msCorridor as Number = 0;
    var msRoute as Number = 0;
    var msHud as Number = 0;

    // List of ways that may appear, per LOD. See [refreshVisible].
    private var _visible as Array<Array<Number> > = CorridorModel.emptyNumberLods();
    private var _cacheX as Float = 0.0;
    private var _cacheY as Float = 0.0;
    private var _cacheScale as Float = -1.0;
    private var _cacheRevision as Number = -1;

    // Where the ways sweep stopped, in **blocks** of
    // `CorridorModel.WAYS_PER_BLOCK`. It is **resumable**: one frame spends what it
    // can and the next continues from here, so that no frame pays for the
    // whole corridor. `_scanLod = -1` means "nothing pending".
    private var _scanLod as Number = -1;
    private var _scanBlock as Number = 0;
    private var _scanFound as Array<Number> = [] as Array<Number>;
    //! The scale with which the sweep in progress started ([RESCAN_SCALE]).
    private var _scanScale as Float = -1.0;
    //! The sweep in progress came from a zoom or a new corridor, not from the map moving: the app
    //! asks for extra frames until it closes ([wantsCatchUp]).
    private var _catchUp as Boolean = false;

    // Visible intervals of the route, in pairs `[from, to, …]`. See [drawRoute].
    private var _routeRanges as Array<Number> = [] as Array<Number>;
    private var _routeCacheX as Float = 0.0;
    private var _routeCacheY as Float = 0.0;
    private var _routeCacheScale as Float = -1.0;
    private var _routeCacheSize as Number = -1;
    //! `RouteModel.revision` from when the intervals were computed: the route
    //! can be swapped for another with the same number of points (C11).
    private var _routeCacheRevision as Number = -1;

    // Recomputed once per frame in [begin].
    private var _sin as Float = 0.0;
    private var _cos as Float = 1.0;
    private var _centreX as Float = 0.0;
    private var _centreY as Float = 0.0;
    //! Ground per px of **this** screen, in meters. It is `NavState.metersPerPx` times 454 / size, so the same area
    //! shows on every size ([beginAt]); the transform, the cull and the street images use this one.
    private var _scale as Float = 2.5;
    //! The ground per px of the **reference** glass, as `NavState` holds it: what the zoom levels, the LOD ceiling
    //! ([LOD_MAX_SCALE]), the width law ([widthScale]) and the decimation step are written in.
    private var _refScale as Float = 2.5;
    private var _cullM as Float = 1000.0;
    //! The frame's flattening ([tilt]) and the sine and cosine of the heading already times it: the bottom row
    //! of the transform.
    private var _k as Float = 1.0;
    private var _ksin as Float = 0.0;
    private var _kcos as Float = 1.0;

    //! Square of the smallest distance, in meters, between two drawn vertices.
    //! See [MIN_STEP_PX] and the decimation in [drawRange] / [drawWay].
    private var _stepSqM as Float = 0.0;

    // Frame widths, already at the zoom scale ([widthScale]); recomputed only when the scale changes.
    private var _roadWidth as Array<Number> = [14, 11, 9, 7] as Array<Number>;
    private var _routeWidth as Number = 12;
    private var _casingWidth as Number = 18;
    private var _widthMpp as Float = -1.0;

    // The rider and destination sizes in px of this screen ([initialize]).
    private var _haloR as Number;
    private var _ringR as Number;
    private var _ringW as Number;
    private var _arrowHalf as Float;
    private var _arrowBelow as Float;
    private var _arrowAbove as Float;
    private var _signPx as Number;
    private var _destDotR as Number;
    private var _destEdgeR as Float;
    private var _destMaxPx as Float;

    //! **Streets in an image** ([StreetCache]): the frame pastes the rotated image instead of drawing
    //! street by street, and the leash stops cutting streets. Off here and in the tests; the app turns it on at
    //! launch ([setStreetCache]).
    var streetCache as Boolean = false;
    private var _streets as StreetCache;

    //! **The route outline** (sheet 4, 2026-10-17): the dark route casing, without antialiasing and underneath.
    //! The default since v1.1.5 (sheet 8: the blue route without casing vanishes over the expressway); the test
    //! switch that turned it off left the watch menu in v1.5.1.
    var routeCasing as Boolean = true;

    //! **The tilted map** (v1.1.5, sheet 8): the map flattened by `DesignTokens.TILT_K` around the rider. Off here
    //! and in the tests; the app turns it on at launch, with no switch since v1.5.1.
    var tilt as Boolean = false;

    //! The last frame's flattening: 1 is flat. The pool that refused the tilted image leaves the map
    //! flat ([StreetCache.tiltRefused]).
    function tiltK() as Float {
        return _k;
    }

    //! Reads the screen ([Screen], set by the app before this) once: from here on the geometry of the frame is in
    //! px of this screen. At 454 every line is the identity, and the tests (which never call `Screen.init`) get that.
    function initialize() {
        _streets = new StreetCache();
        ANCHOR_X = Screen.px(ANCHOR_X_REF);
        ANCHOR_Y = Screen.px(DesignTokens.PUCK_Y);
        CORNER_PX = Screen.half.toFloat() + (ANCHOR_Y - Screen.half);
        WIDTH_AHEAD = Screen.px(DesignTokens.ROUTE_PX);
        WIDTH_CASING = WIDTH_AHEAD + 2 * Screen.px(DesignTokens.ROUTE_CASING_PX);
        NORTH_CX = Screen.px(376);
        NORTH_CY = Screen.px(112);
        NORTH_NEEDLE_PX = Screen.px(15);
        NORTH_LABEL_PX = Screen.px(30);
        DIAG_LABEL_X = Screen.px(DIAG_LABEL_X_REF);
        DIAG_LABEL_Y = Screen.px(DIAG_LABEL_Y_REF);
        _haloR = Screen.px(DesignTokens.HALO_RADIUS);
        _ringR = Screen.px(PUCK_RING_R);
        _ringW = Screen.px(PUCK_RING_W);
        _arrowHalf = Screen.pxf(PUCK_ARROW_HALF);
        _arrowBelow = Screen.pxf(PUCK_ARROW_BELOW);
        _arrowAbove = Screen.pxf(PUCK_ARROW_ABOVE);
        _signPx = Screen.px(PUCK_SIGN_PX);
        _destDotR = Screen.px(DEST_DOT_R);
        _destEdgeR = Screen.pxf(DEST_EDGE_R);
        _destMaxPx = Screen.pxf(DEST_MAX_PX);
    }

    //! Turns the image streets on or off. Turning off drops the two images; turning on tries again
    //! even after the pool refused (the image and the tilted image).
    function setStreetCache(on as Boolean) as Void {
        if (!on) {
            _streets.drop();
        }
        _streets.failed = false;
        _streets.tiltRefused = false;
        streetCache = on;
    }

    //! **Streets in tiles (C16.6, v1.2.9):** the normal drawing moves from the single 640 px image,
    //! which the Venu 4 does not show, to the `StreetCache.GRID_DEFAULT` grid. The app turns it on at startup; the
    //! single-image tests create the map without turning it on.
    function useStreetGrid() as Void {
        _streets.useGrid();
    }

    //! **The street diagnostic lever (C16, v1.2.5, `StreetCache.diag`).** When on (1 to 10),
    //! the map uses the image even with "Street images" off ([imageOn]): every lever is a
    //! hypothesis about the image.
    function setStreetDiag(value as Number) as Void {
        _streets.setDiag(value);
    }

    //! Does the map draw the streets from the image? The switch or a diagnostic lever on.
    function imageOn() as Boolean {
        var lever = _streets.diag;
        if (lever == StreetCache.DIAG_LIVE) {
            return false;
        }
        return streetCache || lever != StreetCache.DIAG_OFF;
    }

    //! Where the lever's "D" appears: to the left of the rider, away from the top HUD and the cards.
    //! In reference px; [DIAG_LABEL_X] and [DIAG_LABEL_Y] are them on this screen.
    static const DIAG_LABEL_X_REF = 60;
    static const DIAG_LABEL_Y_REF = 227;
    var DIAG_LABEL_X as Number;
    var DIAG_LABEL_Y as Number;

    //! The streets image in 16 bits or at the SDK default depth (C16). Changed: the images go out and
    //! the next is born in the new format, and the pool gets another chance (the image and the tilted one).
    function setStreet16Bit(on as Boolean) as Void {
        _streets.setSixteenBits(on);
    }

    //! The street cache, for the tests and for the frame summary.
    function streets() as StreetCache {
        return _streets;
    }

    //! Is the cache still drawing the new image? It is what the app's recovery timer steps.
    function streetsBuilding() as Boolean {
        return imageOn() && !_streets.failed && _streets.building();
    }

    //! A step of the new image, outside `onUpdate` (`MotoNavApp.onCatchUp`). Returns `true` when
    //! it is ready: only then does a frame show something new.
    function stepStreets(corridor as CorridorModel) as Boolean {
        if (!streetsBuilding()) {
            return false;
        }
        return _streets.step(corridor);
    }

    function draw(
        dc as Dc,
        route as RouteModel,
        nav as NavState,
        matcher as MapMatcher,
        corridor as CorridorModel?
    ) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_BLACK);
        dc.clear();
        segmentsDrawn = 0;
        corridorSegments = 0;
        work = 0;
        corridorCapped = false;

        if (route.xs.size() < 2) {
            return;
        }

        begin(nav);
        dc.setAntiAlias(true);

        // The corridor goes first: it is background, and the route has to stay on top of it
        // at every crossing.
        var mark = System.getTimer();
        if (corridor != null) {
            if (imageOn() && !_streets.failed) {
                drawStreets(dc, corridor as CorridorModel);
            } else {
                drawCorridor(dc, corridor as CorridorModel);
            }
        }
        msCorridor = System.getTimer() - mark;
        if (_streets.diag != StreetCache.DIAG_OFF) {
            // Which lever is on, so Igor knows the phone reached the watch.
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(DIAG_LABEL_X, DIAG_LABEL_Y, Graphics.FONT_XTINY, "D" + _streets.diag.toString(),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        // Traversed first: where the two touch, what ends up on top is the
        // route ahead, which is the information that matters.
        mark = System.getTimer();
        drawRoute(dc, route, matcher);
        msRoute = System.getTimer() - mark;

        if (nav.phase != NavPhase.ARRIVED) {
            drawDestination(dc, route);
        }
        Radars.drawMarkers(dc, self, route);
        drawRider(dc, nav);
        if (SHOW_NORTH) {
            drawNorth(dc);
        }
    }

    //! Draws the surrounding streets: **the local street underneath and the expressway on top**, like Maps and
    //! Waze. Until C16.5 the order was the opposite, and at the crossing the local street went over the
    //! avenue (Igor saw it in the simulator photo, 2026-10-17).
    //!
    //! Each LOD has a scale ceiling: with the map very open, the local mesh
    //! does not fit in any pixel and would only cost CPU. This `continue` is what holds
    //! the corridor cost down when auto-zoom opens at 5 m/px.
    //! **What is left out stays the local street** when the budget runs out: the
    //! [planCorridor] decides, from coarse to fine, how many ways of each LOD fit, and only
    //! then does the drawing go from fine to coarse. The cut is by budget and not by
    //! a fixed segment count — see the watchdog leash, above.
    //!
    //! **Draw before sweeping** (C16.5). The sweep came first and shared the same
    //! budget: with the leash at the floor, the frame that rebuilt the list spent everything on it and
    //! drew no street at all, and the list is rebuilt every [CACHE_REBUILD_M] (at 50 km/h,
    //! every two frames). That was the C16 "streets blink". Now the drawing uses the
    //! previous list, which [CULL_MARGIN] covers, and the sweep goes with what is left, never
    //! with less than its share ([SCAN_SHARE]).
    function drawCorridor(dc as Dc, corridor as CorridorModel) as Void {
        prepareVisible(corridor);
        var limit = scanPending() ? corridorBudget - corridorBudget / SCAN_SHARE : corridorBudget;
        var start = work;
        planCorridor(corridor, limit);
        firstLodDrawn = -1;
        lastLodDrawn = -1;

        // The budget cut is the plan's. Inside the loop only the absolute cut in
        // [WORK_MAX] remains, the watchdog net for a plan that got it badly wrong: with the fine one first,
        // a cut at `limit` here would take out exactly the expressway, the last to be drawn.
        for (var lod = Protocol.CORRIDOR_LOD_COUNT - 1; lod >= 0; lod--) {
            var count = planned[lod] as Number;
            if (count == 0) {
                continue;
            }
            var before = work;
            var whole = true;
            var indexes = _visible[lod] as Array<Number>;
            var xs = corridor.xs[lod] as Array<Float>;
            var ys = corridor.ys[lod] as Array<Float>;
            var starts = corridor.wayStart[lod] as Array<Number>;

            // The brightness comes from the fine tuning (`Config`, C5); LOD_COLOR is 100%.
            dc.setColor(Config.corridorColor(lod), Graphics.COLOR_TRANSPARENT);
            var width = _roadWidth[lod] as Number;
            dc.setPenWidth(width);
            // Antialiasing per LOD ([ANTIALIAS_MAX_LOD]): only on the expressways.
            dc.setAntiAlias(lod <= ANTIALIAS_MAX_LOD);
            // Radius 0 means no disc at all ([CAP_MAX_LOD]).
            var radius = lod <= CAP_MAX_LOD ? capRadius(width) : 0;
            var limit2 = radius > 0 ? (STREET_JOIN_PX * STREET_JOIN_PX / (radius * radius)).toFloat() : 2.0;

            for (var i = 0; i < count; i++) {
                if (work - start >= WORK_MAX) {
                    corridorCapped = true;
                    whole = false;
                    break;
                }
                var w = indexes[i] as Number;
                // A way may have arrived after the cache was built, or the
                // corridor may have been swapped in the middle of a sweep: the
                // index stored between frames is checked before becoming an array
                // access. Out of range here would be an exception inside `onUpdate`.
                if (w + 1 >= starts.size()) {
                    continue;
                }
                var drawn = drawWay(dc, xs, ys, starts[w] as Number, starts[w + 1] as Number, radius, limit2);
                segmentsDrawn += drawn;
                corridorSegments += drawn;
            }
            if (firstLodDrawn < 0) {
                firstLodDrawn = lod;
            }
            lastLodDrawn = lod;
            var bound = _planBound[lod] as Number;
            if (whole && bound > 0) {
                var pct = (work - before - (_planTrav[lod] as Number)) * 100 / bound;
                _costPct[lod] = pct < COST_PCT_MIN ? COST_PCT_MIN : (pct > 100 ? 100 : pct);
            }
        }
        corridorWork = work - start;
        dc.setAntiAlias(true);
        scanVisible(corridor);
    }

    //! The streets via [StreetCache]: checks whether the image still serves (and starts another if not) and pastes the
    //! one that is ready. No street is drawn here, so nothing enters the frame's [work].
    //! While the first image is not ready, the glass is left without streets for a few tenths of a
    //! second; the recovery timer steps the drawing ([wantsCatchUp]).
    function drawStreets(dc as Dc, corridor as CorridorModel) as Void {
        corridorWork = 0;
        firstLodDrawn = -1;
        lastLodDrawn = -1;
        if (corridor.isEmpty()) {
            return;
        }
        // The glass center, seen from the world, is (anchor − glass center) / K ahead of the rider.
        _streets.setTilt(_k);
        _streets.plan(corridor, _centreX, _centreY, _sin, _cos, _scale,
            ((ANCHOR_Y - Screen.half) / _k).toFloat(), _roadWidth);
        if (!_streets.covers()) {
            // No image covers the glass (the first is still being made, the GPS jumped, the zoom changed
            // a lot): street by street, with the leash, as without the cache, until the new one is ready.
            _streets.fallbacks++;
            drawCorridor(dc, corridor);
            return;
        }
        parkScan();
        _streets.blit(dc, _centreX, _centreY, _sin, _cos, _scale,
            ANCHOR_X.toFloat(), ANCHOR_Y.toFloat());
    }

    //! **The corridor plan** (C16.5): how many ways of each LOD enter this frame, counted
    //! from coarse to fine until the budget runs out, in [planned]. Each way costs the traversal
    //! of its `n` points, which [drawWay] always charges, plus the drawing: its **ceiling**
    //! (`n − 1` segments and, with a disc, `n` discs: two ends and at most `n − 2` bends)
    //! times how much of that ceiling the LOD paid in the previous frame ([_costPct]). The list changes
    //! slowly, so the previous frame's % holds for this one.
    //! As in the old loop, the cut comes **before** the way: the last one that starts within the
    //! budget enters whole, so a long expressway never vanishes at the leash floor.
    //! The plan itself costs [PLAN_COST] per way, in the same count.
    function planCorridor(corridor as CorridorModel, limit as Number) as Void {
        var spent = work;
        var ways = 0;
        var full = true;
        for (var lod = 0; lod < Protocol.CORRIDOR_LOD_COUNT; lod++) {
            planned[lod] = 0;
            _planTrav[lod] = 0;
            _planBound[lod] = 0;
            if (!full) {
                continue;
            }
            var indexes = _visible[lod] as Array<Number>;
            var starts = corridor.wayStart[lod] as Array<Number>;
            var perPoint = SEGMENT_COST + (lod <= CAP_MAX_LOD ? DISC_COST : 0);
            var pct = _costPct[lod] as Number;
            var trav = 0;
            var bound = 0;
            var size = indexes.size();
            var i = 0;
            while (i < size) {
                if (spent >= limit) {
                    full = false;
                    corridorCapped = true;
                    break;
                }
                var w = indexes[i] as Number;
                if (w + 1 < starts.size()) {
                    var n = (starts[w + 1] as Number) - (starts[w] as Number);
                    var most = n * perPoint - SEGMENT_COST;
                    trav += n;
                    bound += most;
                    spent += n + most * pct / 100;
                }
                spent += PLAN_COST;
                i++;
            }
            planned[lod] = i;
            _planTrav[lod] = trav;
            _planBound[lod] = bound;
            ways += i;
        }
        work += ways * PLAN_COST;
    }

    //! Recomputes which ways may appear, **and only when it is worth it**.
    //!
    //! This is the fix that saved the app from closing by itself. Traversing the 385
    //! ways of an urban corridor on every frame — even rejecting almost all of them in
    //! four comparisons — cost **106 ms per frame** measured on the Venu 4 (78 ms
    //! without the corridor, 184 ms with it, drawing practically the same ~90
    //! segments). Monkey C is interpreted: the loop itself is the cost, not the
    //! drawing. And the device's `watchdogCount` is 240,000 — exceeding it in one
    //! `onUpdate` makes the system **kill the app**, which is exactly what Igor
    //! saw happen the moment the corridor arrived.
    //!
    //! The observation that solves it: the map moves slowly. Between two frames the
    //! center moves meters, and the list of visible ways is the same. So it is
    //! recomputed only when the center moves [CACHE_REBUILD_M], when the scale
    //! changes, or when a new corridor arrives. On the other frames the loop goes only over
    //! the ways that can actually appear.
    //! The sweep is **resumable**, and that is what makes it safe. A corridor in
    //! São Paulo has almost a thousand ways; testing them all at once is a work
    //! spike in a single `onUpdate` — exactly the form of death the watchdog
    //! punishes. Here each frame spends what fits in the leash and the next continues
    //! from where it stopped, LOD by LOD and way by way. While an LOD is being
    //! swept, the drawing uses its **previous** list: a bit old, never
    //! invalid — the [CULL_MARGIN] slack exists to cover that lag.
    function refreshVisible(corridor as CorridorModel) as Void {
        prepareVisible(corridor);
        scanVisible(corridor);
    }

    //! The cheap part of [refreshVisible]: decides whether the list is still good, restarts the
    //! sweep and drops the list of a geometry that changed. It comes before the drawing,
    //! which cannot read an index from a corridor that no longer exists.
    private function prepareVisible(corridor as CorridorModel) as Void {
        var dx = _centreX - _cacheX;
        var dy = _centreY - _cacheY;
        var moved = dx * dx + dy * dy > CACHE_REBUILD_M * CACHE_REBUILD_M;
        var newGeometry = _cacheRevision != corridor.revision;

        var stale = _cacheScale != _scale || moved;
        var jumped = scaleJumped();
        if (newGeometry) {
            // New geometry: the stored indices point to the old arrays
            // and are worth nothing now. Dropping the list is mandatory —
            // reusing it would read outside the array at drawing time.
            _visible = CorridorModel.emptyNumberLods();
            restartScan();
            _catchUp = true;
        } else if (_scanLod >= 0 && jumped) {
            // **A zoom in the middle of the sweep restarts it** (C16, bench of 2026-10-17: "every time the
            // zoom changes it seems to reset the streets appearing"). Until then the sweep in
            // progress carried on, and the LODs already swept kept the old-scale list: opening the
            // zoom, without the edge streets; and stopped, no movement asked for another list.
            restartScan();
            _catchUp = true;
        } else if (stale && _scanLod < 0) {
            // **Only whoever is not halfway restarts.** Above ~90
            // km/h the map moves more than [CACHE_REBUILD_M] between two frames, and
            // restarting the sweep on every frame would make the last LOD never
            // finish — the map would lose the streets precisely for going fast.
            // Letting the sweep in progress carry on costs an inconsistency the
            // size of the displacement, which is what [CULL_MARGIN] covers.
            restartScan();
            _catchUp = jumped;
        }
        if (newGeometry || stale) {
            _cacheRevision = corridor.revision;
            _cacheScale = _scale;
            _cacheX = _centreX;
            _cacheY = _centreY;
        }
    }

    //! The expensive part: steps the sweep until the budget runs out, and the next frame
    //! continues from where it stopped.
    private function scanVisible(corridor as CorridorModel) as Void {
        var span = CorridorModel.WAYS_PER_BLOCK;

        while (_scanLod >= 0 && _scanLod < Protocol.CORRIDOR_LOD_COUNT) {
            // Above the LOD scale ceiling the mesh becomes noise and CPU cost
            // with no information: the screen has no pixel to tell one street from another.
            var overScale = _refScale > (LOD_MAX_SCALE[_scanLod] as Float);
            var boxes = corridor.wayBox[_scanLod] as Array<Float>;
            var blocks = corridor.blockBox[_scanLod] as Array<Float>;
            var ways = overScale ? 0 : boxes.size() / 4;
            var blockCount = overScale ? 0 : blocks.size() / 4;

            // The sweep goes **by block**: 32 ways die in a single test when
            // the whole block is out of view. See `CorridorModel.blockBox`.
            while (_scanBlock < blockCount) {
                if (work >= corridorBudget) {
                    corridorCapped = true;
                    return;
                }
                var bb = _scanBlock * 4;
                work++;
                if (boxVisible(
                        blocks[bb] as Float,
                        blocks[bb + 1] as Float,
                        blocks[bb + 2] as Float,
                        blocks[bb + 3] as Float)) {
                    var from = _scanBlock * span;
                    var to = from + span;
                    if (to > ways) {
                        to = ways;
                    }
                    for (var w = from; w < to; w++) {
                        var base = w * 4;
                        work++;
                        if (boxVisible(
                                boxes[base] as Float,
                                boxes[base + 1] as Float,
                                boxes[base + 2] as Float,
                                boxes[base + 3] as Float)) {
                            _scanFound.add(w);
                        }
                    }
                }
                _scanBlock++;
            }

            _visible[_scanLod] = _scanFound;
            _scanFound = [] as Array<Number>;
            _scanBlock = 0;
            _scanLod++;
        }
        _scanLod = -1;
        _catchUp = false;
    }

    //! The visible route intervals computed in the last frame, in pairs
    //! `[from, to, …]`. It exists so the test can compare the block-index result
    //! with the point-by-point sweep — the two **must** give the
    //! same thing, otherwise the index is an optimization that changes the drawing.
    function routeRanges() as Array<Number> {
        return _routeRanges;
    }

    //! How many ways survived the cut, summing the LODs. It goes in the telemetry —
    //! compared with the total received, it says at a glance whether the cache is
    //! cutting too much (empty map) or too little (expensive frame).
    function visibleWays() as Number {
        var total = 0;
        for (var lod = 0; lod < Protocol.CORRIDOR_LOD_COUNT; lod++) {
            total += (_visible[lod] as Array<Number>).size();
        }
        return total;
    }

    //! How many ways of one LOD are in the visible list. For the [planCorridor] tests.
    function visibleIn(lod as Number) as Number {
        return (_visible[lod] as Array<Number>).size();
    }

    //! Rebuilds the visible ways list on the next pass. Test only: in
    //! production the trigger is the map's own movement.
    function invalidateVisible() as Void {
        _cacheRevision = -1;
    }

    //! Does the sweep still have LODs to go through?
    function scanPending() as Boolean {
        return _scanLod >= 0;
    }

    private function restartScan() as Void {
        _scanLod = 0;
        _scanBlock = 0;
        _scanFound = [] as Array<Number>;
        _scanScale = _scale;
    }

    //! Did the scale move more than [RESCAN_SCALE] since the start of the last sweep? The button zoom
    //! jumps level by level (1.2 → 2.5 → 5 m/px); the automatic one arrives in steps of 20%
    //! of what is left, and its tail, of small steps, restarts nothing.
    private function scaleJumped() as Boolean {
        if (_scanScale <= 0.0) {
            return true;
        }
        var delta = _scale - _scanScale;
        if (delta < 0.0) {
            delta = -delta;
        }
        return delta > _scanScale * RESCAN_SCALE;
    }

    //! **The app asks for extra frames while this is true** (C16, bench of 2026-10-17: "the streets
    //! take a long time to appear"). While navigating, what asks for a frame is the GPS, at 1 Hz, and the sweep
    //! goes one piece per frame: at the leash floor, a new list took seconds. Only for zoom and
    //! new corridor; the sweep of whoever moves on the map follows the GPS pace, so as not to change the
    //! CPU cost for whoever is riding.
    function wantsCatchUp() as Boolean {
        return scanWantsFrames() || streetsBuilding();
    }

    //! The street-by-street drawing sweep wants extra frames (zoom, new corridor). With image
    //! streets, only on frames with no image covering the glass: [drawStreets] parks the sweep
    //! when the image returns.
    function scanWantsFrames() as Boolean {
        return _catchUp && _scanLod >= 0;
    }

    //! With the image on the glass, the sweep stops: nothing of it is worth anything until the next frame without an image, which
    //! restarts from zero. Without this, a half-done sweep would ask for extra frames forever.
    private function parkScan() as Void {
        _scanLod = -1;
        _catchUp = false;
        _cacheRevision = -1;
    }

    //! Does the way's rectangle cross the frame's cull square?
    function boxVisible(minX as Float, maxX as Float, minY as Float, maxY as Float) as Boolean {
        return maxX > _centreX - _cullM && minX < _centreX + _cullM
            && maxY > _centreY - _cullM && minY < _centreY + _cullM;
    }

    //! One way, from `from` (inclusive) to `to` (exclusive). Same cull by
    //! visibility as the route: one end inside is enough for the segment to be drawn.
    //!
    //! **The end point of a segment becomes the start point of the next**, instead
    //! of being transformed twice. On a fully drawn polyline this
    //! cuts half the frame's multiplications — and the previous version called
    //! `screenX`/`screenY` four times per segment, each redoing the
    //! subtraction and the division from scratch.
    //!
    //! **Round cap and join** (C16.5, "the streets are very ugly"): the 14 px street ended
    //! flat and opened a wedge at every bend, and two ways meeting at a crossing ended up with
    //! square corners on top of each other. Now the way gets a disc of [capRadius] at each
    //! end and at the bends that would open a visible wedge ([JOIN_PX]); on straights, nothing extra. It is the
    //! stroke of Waze and Maps: smooth tube, round end.
    //! `public` for the stroke bench (`watch/demo/traco`) to draw exactly this.
    function drawWay(
        dc as Dc,
        xs as Array<Float>,
        ys as Array<Float>,
        from as Number,
        to as Number,
        radius as Number,
        limit2 as Float
    ) as Number {
        if (to - from < 2) {
            return 0;
        }
        // The way traversal is paid even for the vertices that do not become a line:
        // it is `onUpdate` work like any other, and a 200-point way
        // off-screen would cost a lot while drawing nothing if it did not enter the count.
        work += to - from;
        var drawn = 0;
        var discs = 0;
        // `ax`/`ay` are the last vertex **emitted**, not `xs[i]`: with
        // decimation on the two stop being the same thing, and using `xs[i]`
        // here would open a hole in the street at every discarded point.
        var ax = xs[from] as Float;
        var ay = ys[from] as Float;
        var aVisible = visible(ax, ay);
        var apx = 0.0;
        var apy = 0.0;
        var haveA = false;
        // The previous segment, on screen, if it was drawn and ends at `a`: it is against it that
        // the bend at `a` is measured.
        var ux = 0.0;
        var uy = 0.0;
        var linked = false;
        var first = true;

        for (var i = from; i < to - 1; i++) {
            var bx = xs[i + 1] as Float;
            var by = ys[i + 1] as Float;
            var last = i + 2 >= to;

            // Decimation by scale; the last vertex of the way always passes, so
            // it does not shrink at the end. See [MIN_STEP_PX].
            if (!last) {
                var sx = bx - ax;
                var sy = by - ay;
                if (sx * sx + sy * sy < _stepSqM) {
                    continue;
                }
            }

            var bVisible = visible(bx, by);
            var bpx = 0.0;
            var bpy = 0.0;
            var haveB = false;

            if (aVisible || bVisible) {
                if (!haveA) {
                    apx = screenX(ax, ay);
                    apy = screenY(ax, ay);
                }
                bpx = screenX(bx, by);
                bpy = screenY(bx, by);
                haveB = true;
                var vx = bpx - apx;
                var vy = bpy - apy;
                // Radius 0 means no disc at all ([CAP_MAX_LOD]).
                if (radius > 0 && linked) {
                    // Bend at `a`: sin² θ = cross² / (|u|² |v|²), no root. A reversal (dot < 0) is
                    // always a bend, however small the cross product comes out.
                    var cross = ux * vy - uy * vx;
                    var dot = ux * vx + uy * vy;
                    if (dot < 0.0 || cross * cross > limit2 * (ux * ux + uy * uy) * (vx * vx + vy * vy)) {
                        dc.fillCircle(apx, apy, radius);
                        discs++;
                    }
                } else if (radius > 0 && first) {
                    dc.fillCircle(apx, apy, radius);
                    discs++;
                }
                dc.drawLine(apx, apy, bpx, bpy);
                drawn++;
                if (last && radius > 0) {
                    dc.fillCircle(bpx, bpy, radius);
                    discs++;
                }
                ux = vx;
                uy = vy;
                linked = true;
            } else {
                linked = false;
            }

            first = false;
            aVisible = bVisible;
            apx = bpx;
            apy = bpy;
            haveA = haveB;
            ax = bx;
            ay = by;
        }
        work += drawn * SEGMENT_COST + discs * DISC_COST;
        return drawn;
    }

    //! North direction on the screen, as a unit vector in pixels (y grows
    //! downward). Comes from applying the frame transform to the world vector (0, 1).
    function northOnScreen() as Array<Float> {
        return [-_sin, -_cos] as Array<Float>;
    }

    //! North needle. It exists for two reasons: without it there is nothing on the screen that
    //! proves track-up is rotating (that is how the inverted rotation
    //! went unnoticed), and on a rotated map the rider loses the reference of
    //! which way north is.
    private function drawNorth(dc as Dc) as Void {
        var north = northOnScreen();
        var nx = north[0] as Float;
        var ny = north[1] as Float;

        dc.setColor(COLOR_NORTH, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(Screen.px(3));
        dc.drawLine(
            (NORTH_CX - nx * NORTH_NEEDLE_PX).toNumber(),
            (NORTH_CY - ny * NORTH_NEEDLE_PX).toNumber(),
            (NORTH_CX + nx * NORTH_NEEDLE_PX).toNumber(),
            (NORTH_CY + ny * NORTH_NEEDLE_PX).toNumber()
        );
        dc.drawText(
            (NORTH_CX + nx * NORTH_LABEL_PX).toNumber(),
            (NORTH_CY + ny * NORTH_LABEL_PX).toNumber(),
            Graphics.FONT_XTINY,
            "N",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    //! Smallest distance between two drawn vertices, in px of the reference glass: [beginAt] multiplies it by
    //! the ground per reference px, so the step is the same number of meters (and the same work) on every size.
    //!
    //! **Decimation by scale.** At 20 m/px, two consecutive route points (about
    //! 26 m apart) fall 1.3 px apart: transforming and drawing the
    //! two produces exactly the same pixels as drawing one. That is where the 89 ms of route
    //! that the telemetry showed at the open zoom came from.
    //!
    //! 2.5 px is the point at which the discard stops being visible on a line
    //! 3–5 px thick. At 1.2 m/px that is 3 m, and since the Mapbox route has a
    //! point every ~26 m, **at the riding zoom nothing is discarded** — the
    //! decimation only acts where it is invisible, which is the only honest way to
    //! optimize drawing.
    const MIN_STEP_PX = 2.5;

    //! Freezes the frame's heading, center and scale.
    function begin(nav as NavState) as Void {
        beginAt(nav.centreX(), nav.centreY(), nav.metersPerPx, nav.headingRad);
    }

    //! The same, without `NavState`: the stroke bench (`watch/demo/traco`) draws with it.
    function beginAt(centreX as Float, centreY as Float, metersPerPx as Float, heading as Float) as Void {
        _sin = Math.sin(heading).toFloat();
        _cos = Math.cos(heading).toFloat();
        _centreX = centreX;
        _centreY = centreY;
        // **The one place where the zoom meets the screen size.** `metersPerPx` is the ground per px of the
        // 454 px glass; on a 390 px one each px has to cover 454 / 390 times more ground, or the map would show less.
        // At 454 the factor is skipped, so `_scale` is `metersPerPx` itself, bit for bit.
        _refScale = metersPerPx;
        _scale = Screen.size == Screen.REF ? metersPerPx : (metersPerPx * Screen.REF / Screen.size).toFloat();
        _k = tilt && !_streets.tiltRefused ? DesignTokens.TILT_K.toFloat() : 1.0;
        _ksin = _sin * _k;
        _kcos = _cos * _k;
        // The cull is a square around the rider, so it holds at any heading without redoing the
        // lists on every turn: the side is that of the glass pixel farthest from the rider in the world, which
        // tilted is the top one, at CORNER_PX / K.
        _cullM = (CORNER_PX / _k * _scale * CULL_MARGIN).toFloat();
        var step = MIN_STEP_PX * _refScale;
        _stepSqM = (step * step).toFloat();
        if (metersPerPx != _widthMpp) {
            _widthMpp = metersPerPx;
            var roads = widthScale(metersPerPx, WIDTH_EXPONENT, WIDTH_MIN_SCALE);
            var widths = new [LOD_WIDTH.size()] as Array<Number>;
            for (var lod = 0; lod < widths.size(); lod++) {
                widths[lod] = scaledWidth(Screen.px(LOD_WIDTH[lod] as Number), roads);
            }
            _roadWidth = widths;
            var route = widthScale(metersPerPx, ROUTE_WIDTH_EXPONENT, ROUTE_MIN_SCALE);
            _routeWidth = scaledWidth(WIDTH_AHEAD, route);
            var border = scaledWidth(Screen.px(DesignTokens.ROUTE_CASING_PX), route);
            _casingWidth = _routeWidth + 2 * (border < 2 ? 2 : border);
        }
    }

    //! `(WIDTH_REF_MPP / m per px) ^ exponent`, between `floor` and 1: near does not thicken, far thins.
    //! `metersPerPx` is the reference glass's ([_refScale]), the same unit as [WIDTH_REF_MPP].
    function widthScale(metersPerPx as Float, exponent as Float, floor as Float) as Float {
        if (metersPerPx <= WIDTH_REF_MPP) {
            return 1.0;
        }
        var k = Math.pow(WIDTH_REF_MPP / metersPerPx, exponent).toFloat();
        return k < floor ? floor : k;
    }

    //! The width `base` at scale `k`, rounded, never below 2 px.
    static function scaledWidth(base as Number, k as Float) as Number {
        var w = (base * k + 0.5).toNumber();
        return w < 2 ? 2 : w;
    }

    //! The width of each street LOD in the current frame, for the test and for the bench.
    function roadWidth(lod as Number) as Number {
        return _roadWidth[lod] as Number;
    }

    //! Radius of the disc that rounds the join and end of a line of `width` px: **(w − 2) / 2**, not
    //! w / 2. Measured on the stroke bench ruler (`sim.py shots --traco`, `venu445mm` simulator,
    //! 2026-10-17): `fillCircle(r)` lights 2r + 1 full pixels and one more of antialiasing on each
    //! side, and the pen line `w` lights w − 1 full plus the two edge ones (12 px: 11 + 2). The
    //! disc of r = w / 2 came out **2 px wider** than the line: it was the lump at every route vertex.
    //! With (w − 2) / 2 the width matches on the even ones (12, 14, 18) and stays half a pixel inside on the
    //! odd ones (7, 9, 11).
    function capRadius(width as Number) as Number {
        var radius = (width - 2) / 2;
        return radius < 1 ? 1 : radius;
    }

    //! The join threshold in `sin² θ`, for a line of radius `radius`: see [JOIN_PX].
    function joinLimit(radius as Number) as Float {
        if (radius < 1) {
            return 2.0;
        }
        return (JOIN_PX * JOIN_PX / (radius * radius)).toFloat();
    }

    //! Cull in local coordinates, **before** rotating: a point beyond this
    //! radius does not fit on the screen at any rotation. It is a circle instead of the
    //! exact rectangle on purpose — it costs 4 comparisons per point and spares
    //! rotating what will be discarded, which is the case for most vertices.
    function visible(x as Float, y as Float) as Boolean {
        var dx = x - _centreX;
        var dy = y - _centreY;
        return dx > -_cullM && dx < _cullM && dy > -_cullM && dy < _cullM;
    }

    //! In Float since C16.5: the `Dc` accepts `Numeric`, and truncating each vertex to an integer
    //! bent the line by up to a pixel, in a different direction at each vertex.
    function screenX(x as Float, y as Float) as Float {
        var dx = (x - _centreX) / _scale;
        var dy = (y - _centreY) / _scale;
        return (ANCHOR_X + dx * _cos - dy * _sin).toFloat();
    }

    //! The screen Y axis grows downward and the world's toward north: hence the swapped
    //! sign, otherwise the map comes out mirrored. Tilted, K flattens around the anchor.
    function screenY(x as Float, y as Float) as Float {
        var dx = (x - _centreX) / _scale;
        var dy = (y - _centreY) / _scale;
        return (ANCHOR_Y - (dx * _ksin + dy * _kcos)).toFloat();
    }

    //! Converts a drag on the screen into a displacement in local meters, undoing
    //! the frame rotation — without this, dragging on a rotated map moves the content
    //! in a direction that has nothing to do with the finger.
    function screenDeltaToWorld(dsx as Number, dsy as Number) as Array<Float> {
        var u = dsx * _scale;
        var v = -dsy * _scale / _k;
        return [
            (u * _cos + v * _sin).toFloat(),
            (-u * _sin + v * _cos).toFloat()
        ] as Array<Float>;
    }

    //! Draws the route: the stretch already ridden faded, what is left in white.
    //!
    //! **This is where the 130 ms per frame came from.** The per-phase telemetry, the
    //! first time it was read, gave `corr 1 · route 149 · hud 7` — the corridor
    //! cost 1 ms and the route, 149. The cause: the traversal tested the visibility of
    //! **all ~600 route points on every frame** to draw the ~110 that
    //! appear. A map app cannot pay the route length per frame;
    //! it has to pay what fits on the screen.
    //!
    //! The solution is the same as the corridor's, and for the same reason: the map moves slowly,
    //! so the list of visible stretches holds for several frames. Here it is a
    //! list of **intervals** `[from, to, from, to, …]` and not a single index,
    //! because a route re-enters the screen as many times as it likes — a return,
    //! a U-shaped block or a cloverleaf put two pieces of it in the same view.
    private function drawRoute(dc as Dc, route as RouteModel, matcher as MapMatcher) as Void {
        refreshRouteRanges(route);

        var split = matcher.matched ? matcher.segmentIdx : 0;
        var xs = route.xs;
        var ys = route.ys;
        var lastPoint = xs.size() - 1;

        // Sheet 8 (v1.1.5): the antialiased blue line, of what is left to ride, over the dark casing
        // of option 2 of sheet 4: wider, **without antialiasing** and underneath ([routeCasing], on
        // by default). Round end, and round join only where the line bends ([drawRange]).
        var passes = routeCasing ? 2 : 1;
        for (var pass = 0; pass < passes; pass++) {
            var casing = routeCasing && pass == 0;
            dc.setAntiAlias(!casing);
            dc.setColor(casing ? DesignTokens.ROUTE_EDGE : DesignTokens.ROUTE_LINE, Graphics.COLOR_TRANSPARENT);
            var width = casing ? _casingWidth : _routeWidth;
            dc.setPenWidth(width);
            var radius = capRadius(width);
            var limit2 = joinLimit(radius);

            for (var i = 0; i + 1 < _routeRanges.size(); i += 2) {
                var from = _routeRanges[i] as Number;
                var to = _routeRanges[i + 1] as Number;
                // The interval where the rider is starts **at them** (the matched point), not at the vertex
                // behind: on a 200 m straight the cyan line came out 200 m behind the arrow, and
                // Waze does not draw what was left behind (C16.5).
                var fromSnap = matcher.matched && from <= split;
                from = from > split ? from : split;
                if (to > from) {
                    segmentsDrawn += drawRange(dc, xs, ys, from, to, radius, limit2,
                        fromSnap ? matcher.snapX : null, fromSnap ? matcher.snapY : null,
                        fromSnap || from == 0, to == lastPoint);
                }
            }
        }
    }

    //! Recomputes the route's visible intervals, with the same trigger as the corridor:
    //! only when the center moved, the scale changed or the route was swapped.
    //!
    //! **This is where the app died.** The `CIQ_LOG.YML` of 2026-08-01 points to this
    //! loop (`refreshRouteRanges` → `visible`) as the place where the watchdog
    //! blew: it tested the ~800 route points one by one, and that computation landed in the
    //! same `onUpdate` that had already swept and drawn the São Paulo corridor.
    //!
    //! The fix is the block index of [RouteModel.blockBox]: 16 points die
    //! in a single rectangle test, and only the 2–4 blocks touching the screen are
    //! opened point by point. An 800-point route went from 800 tests to
    //! ~50 + ~64 — and, what matters more, the cost became proportional to what
    //! **appears**, not to the trip length. A 200 km route stopped being
    //! more expensive to draw than a 2 km one.
    private function refreshRouteRanges(route as RouteModel) as Void {
        var dx = _centreX - _routeCacheX;
        var dy = _centreY - _routeCacheY;
        var moved = dx * dx + dy * dy > CACHE_REBUILD_M * CACHE_REBUILD_M;

        // The size stays in the key: a route assembled by hand in a test swaps the
        // arrays without going through `beginRoute`/`adopt`, and the revision does not change.
        if (_routeCacheRevision == route.revision && _routeCacheSize == route.xs.size()
                && _routeCacheScale == _scale && !moved) {
            return;
        }
        _routeCacheRevision = route.revision;
        _routeCacheSize = route.xs.size();
        _routeCacheScale = _scale;
        _routeCacheX = _centreX;
        _routeCacheY = _centreY;

        var ranges = [] as Array<Number>;
        var xs = route.xs;
        var ys = route.ys;
        var count = xs.size();
        var boxes = route.blockBox;
        var blocks = boxes.size() / 4;
        var span = RouteModel.BLOCK_POINTS;
        var open = -1;

        // Without an index (route assembled by hand in a test, or not yet projected) the
        // old path still holds: a single block that covers everything.
        if (blocks == 0) {
            blocks = 1;
            span = count;
        }

        for (var b = 0; b < blocks; b++) {
            var from = b * span;
            var to = from + span;
            if (to > count) {
                to = count;
            }
            work++;
            if (boxes.size() >= (b + 1) * 4 && !boxVisible(
                    boxes[b * 4] as Float,
                    boxes[b * 4 + 1] as Float,
                    boxes[b * 4 + 2] as Float,
                    boxes[b * 4 + 3] as Float)) {
                // Whole block out of view: closes the interval open at the
                // first invisible point, which is the first of this block.
                if (open >= 0) {
                    ranges.add(open);
                    ranges.add(from);
                    open = -1;
                }
                continue;
            }

            work += to - from;
            for (var i = from; i < to; i++) {
                if (visible(xs[i] as Float, ys[i] as Float)) {
                    if (open < 0) {
                        // One point earlier, so the segment entering through the edge
                        // is not born out of nowhere inside the screen.
                        open = i > 0 ? i - 1 : 0;
                    }
                } else if (open >= 0) {
                    ranges.add(open);
                    ranges.add(i);
                    open = -1;
                }
            }
        }
        if (open >= 0) {
            ranges.add(open);
            ranges.add(count - 1);
        }
        _routeRanges = ranges;
    }

    //! Draws the segments from `from` to `to` **without testing visibility**: the caller
    //! already knows the interval appears, and the `dc` clips what goes past the
    //! edge.
    //!
    //! The transform is written by hand instead of calling [screenX]/[screenY]
    //! because both redo the same subtraction and the same division, and a function call
    //! in Monkey C costs. Inline, and reusing the end of the previous
    //! segment, each point is transformed **once**.
    //!
    //! **C16.5, the smooth route.** In Float (the truncated vertex bent the line by up to a pixel), and
    //! a disc only on a bend that would open a wedge ([JOIN_PX]) and at real ends: `capStart` at the
    //! start of the route or at the rider, `capEnd` at the destination. The end of an interval that just leaves the
    //! screen gets no disc: it stays outside the glass. `startX`/`startY`, when given, replace the first
    //! vertex with the matched point ([drawRoute]).
    //! `public` for the stroke bench (`watch/demo/traco`) to draw exactly this.
    function drawRange(
        dc as Dc,
        xs as Array<Float>,
        ys as Array<Float>,
        from as Number,
        to as Number,
        radius as Number,
        limit2 as Float,
        startX as Float?,
        startY as Float?,
        capStart as Boolean,
        capEnd as Boolean
    ) as Number {
        var lastX = startX != null ? startX : xs[from] as Float;
        var lastY = startY != null ? startY : ys[from] as Float;
        var anchorX = ANCHOR_X;
        var anchorY = ANCHOR_Y;
        var dx = (lastX - _centreX) / _scale;
        var dy = (lastY - _centreY) / _scale;
        var ax = anchorX + dx * _cos - dy * _sin;
        var ay = anchorY - (dx * _ksin + dy * _kcos);
        var ux = 0.0;
        var uy = 0.0;
        var drawn = 0;
        var discs = 0;

        if (capStart) {
            dc.fillCircle(ax, ay, radius);
            discs++;
        }

        for (var i = from; i < to; i++) {
            var px = xs[i + 1] as Float;
            var py = ys[i + 1] as Float;

            // Decimation: a vertex that lands on top of the previous one on screen does not become a
            // line. The last point of the interval always passes, otherwise the route
            // would shrink at the end. See [MIN_STEP_PX].
            if (i + 1 < to) {
                var sx = px - lastX;
                var sy = py - lastY;
                if (sx * sx + sy * sy < _stepSqM) {
                    continue;
                }
            }

            dx = (px - _centreX) / _scale;
            dy = (py - _centreY) / _scale;
            var bx = anchorX + dx * _cos - dy * _sin;
            var by = anchorY - (dx * _ksin + dy * _kcos);
            var vx = bx - ax;
            var vy = by - ay;

            // Bend at `a` against the previous segment: see [drawWay].
            if (drawn > 0) {
                var cross = ux * vy - uy * vx;
                var dot = ux * vx + uy * vy;
                if (dot < 0.0 || cross * cross > limit2 * (ux * ux + uy * uy) * (vx * vx + vy * vy)) {
                    dc.fillCircle(ax, ay, radius);
                    discs++;
                }
            }
            dc.drawLine(ax, ay, bx, by);
            ux = vx;
            uy = vy;
            ax = bx;
            ay = by;
            lastX = px;
            lastY = py;
            drawn++;
        }
        if (capEnd && drawn > 0) {
            dc.fillCircle(ax, ay, radius);
            discs++;
        }
        work += drawn * SEGMENT_COST + discs * DISC_COST;
        return drawn;
    }

    //! The route end point (sheet 4, destination 8, 2026-10-17), with 3.5 px of black around it so it does
    //! not vanish in the route arriving at it. Since v1.1.5 in the route color (`ROUTE_LINE`): cyan is the
    //! rider's.
    //! Only when it falls less than [DEST_MAX_PX] (`_destMaxPx`) from the glass center; otherwise, the `dc` would clip everything.
    private function drawDestination(dc as Dc, route as RouteModel) as Void {
        var last = route.xs.size() - 1;
        var x = screenX(route.xs[last] as Float, route.ys[last] as Float);
        var y = screenY(route.xs[last] as Float, route.ys[last] as Float);
        var center = Screen.half.toFloat();
        var dx = x - center;
        var dy = y - center;
        if (dx * dx + dy * dy > _destMaxPx * _destMaxPx) {
            return;
        }
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, _destEdgeR);
        dc.setColor(DesignTokens.ROUTE_LINE, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, _destDotR);
    }

    //! The rider (sheet 4, rider 6, 2026-10-17): the tip of the "?" in a ring, over the halo, at the anchor
    //! (y = 330). The ring stays cyan over the blue route (v1.1.5). **The ring shows the position**, as the home screen ring shows the connection:
    //! - whole and cyan with a good position;
    //! - dark track with a 90 degree cyan arc that moves while the new route has not arrived;
    //! - dashed with weak GPS;
    //! - dashed, with the faded "?" in place of the arrow, with no position at all: the map does not know where
    //!   the bike is.
    //! Health comes before activity: with weak GPS, the dashes beat the arc.
    //! On arrival, the arrow becomes the destination point inside the ring. Track-up: the arrow always points
    //! up, because it is the map that rotates. White, not cyan: cyan would vanish over the route.
    private function drawRider(dc as Dc, nav as NavState) as Void {
        var px = screenX(nav.x, nav.y);
        var py = screenY(nav.x, nav.y);

        dc.setColor(DesignTokens.HALO, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(px, py, _haloR);
        dc.setPenWidth(_ringW);

        var state = puckState(nav);
        if (state == PUCK_ARRIVED) {
            dc.setColor(DesignTokens.ROUTE_AHEAD, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(px, py, _ringR);
            dc.fillCircle(px, py, _destDotR);
            dc.setPenWidth(1);
            return;
        }
        if (state == PUCK_OK) {
            dc.setColor(DesignTokens.ROUTE_AHEAD, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(px, py, _ringR);
        } else if (state == PUCK_RECALC) {
            dc.setColor(DesignTokens.ROUTE_CASING, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(px, py, _ringR);
            // A step of 45 degrees per second, on the next frame (the GPS asks for one per second):
            // the arc moves without a timer of its own.
            var start = 90 - (System.getTimer() / 1000 % 8) * 45;
            dc.setColor(DesignTokens.ROUTE_AHEAD, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(px, py, _ringR, Graphics.ARC_CLOCKWISE, start, start - 90);
        } else {
            // 16 dashes of 10 degrees (3.8 px) around the 138 px circuit: the gap comes out at 4.8 px and closes with no seam.
            dc.setColor(DesignTokens.RING_OFF, Graphics.COLOR_TRANSPARENT);
            for (var i = 0; i < PUCK_DASHES; i++) {
                var a = i * 360 / PUCK_DASHES;
                dc.drawArc(px, py, _ringR, Graphics.ARC_COUNTER_CLOCKWISE, a, a + PUCK_DASH_DEG);
            }
        }
        dc.setPenWidth(1);

        if (state == PUCK_LOST) {
            Signs.draw(dc, Signs.QUESTION, Signs.QUESTION_DOT, px, py, _signPx,
                DesignTokens.SIGN_OFF, DesignTokens.ARROW_REST);
            return;
        }
        // The arrow tip of the "?" (base 52, height 33.2) with a 30 px base.
        dc.setColor(DesignTokens.PUCK, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([
            [px - _arrowHalf, py + _arrowBelow],
            [px + _arrowHalf, py + _arrowBelow],
            [px, py - _arrowAbove]
        ] as Array<[Numeric, Numeric]>);
    }

    //! The rider ring state. Pure function of `NavState`, for the test.
    static function puckState(nav as NavState) as Number {
        if (nav.phase == NavPhase.ARRIVED) {
            return PUCK_ARRIVED;
        }
        if (!nav.hasFix) {
            return PUCK_LOST;
        }
        if (nav.weakFix) {
            return PUCK_WEAK;
        }
        if (nav.offRoute == OffRoute.REQUESTED) {
            return PUCK_RECALC;
        }
        return PUCK_OK;
    }

    //! Pixels the rider lights **stopped in the same place** for the whole trip (the ring and the arrow; the
    //! halo is dark). It does not enter the HUD orbit, so `BurnInTest` holds this. Of the reference glass: the share
    //! of the glass it lights is the same on every size.
    static function puckLitPx() as Number {
        var ring = 2.0 * Math.PI * PUCK_RING_R * PUCK_RING_W;
        var arrow = PUCK_ARROW_HALF * (PUCK_ARROW_BELOW + PUCK_ARROW_ABOVE);
        return (ring + arrow + 0.5).toNumber();
    }
}
