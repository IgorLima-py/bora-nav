import Toybox.Application.Storage;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;

//! **The streets in one image** (Igor's request on 2026-10-17: "all the streets always show up and
//! faster").
//!
//! On the wrist, each street point drawn on every frame costs about 0.19 ms: the interpreted Monkey C
//! loop, not the pixel. All the streets of the SP corridor give 800 to 2,200 points, or 150 to 420
//! ms per frame, and the whole frame already took 182 ms (bench of 2026-10-17). That is why the leash
//! stayed at the floor and the mirror drew 15 of the scene's 139 ways.
//!
//! Here the streets are drawn **once**, north up, in an image of [SIDE] px, bigger than the
//! glass, and the frame only pastes that image rotated (`Dc.drawBitmap2` with `AffineTransform` and a
//! bilinear filter). Pasting is a single call, made by the firmware. So the cost per frame no longer
//! depends on how many streets there are, and all of them fit.
//!
//! **The stroke is Maps' on black** (v1.1.5, sheet 8, option 25): each class with a black edge of
//! `ROAD_EDGE_PX` on each side and the core on top, from local to expressway, so that the
//! bigger class cuts the smaller one at the crossing. Antialias and round caps on every class: here the cost is
//! once per image, not per frame. The street-by-street drawing of `MapRenderer` (when the
//! image is missing) stays on the cheap stroke from before.
//!
//! **Tilted** ([tiltK] < 1): the paste flattens the image on the heading axis around the rider
//! ([matrix]), and the glass, seen from the image, becomes an ellipse with 227 / K px along the heading. That is why the
//! tilted image is bigger ([SIDE_TILT]) and the slack is measured by the ellipse ([slack]).
//!
//! The image is rebuilt when the rider gets near its edge, when the zoom changes, when a new
//! corridor arrives and when the streets' brightness changes. It is rebuilt **in steps** ([step]), outside
//! `onUpdate`, on the app's catch-up timer (`MotoNavApp.onCatchUp`): the watchdog is per callback,
//! and the app already uses the three timers the system gives. There are two images: one on screen and another being
//! drawn, swapped when the new one is ready. The frame never shows a half-drawn image.
//!
//! Both live in the graphics pool (4 MB on the `venu445mm`, `simulator.json`), outside the 512 KB heap.
//! If the pool refuses, the cache turns itself off ([failed]) and the map goes back to per-frame drawing.
//!
//! **Tiles (C16.6, v1.2.9).** On the wrist, the 640 px image never showed up, and the 480 one did
//! (`DECISIONS.md` §"the street image ceiling"). With [grid] > 0, the world is covered by tiles of
//! [side] px pinned to a world grid ([planGrid]): the [grid]² around the glass sit in slots, and
//! only the missing tile is drawn, one at a time, on the spare image. Moving one row redraws one
//! row; rotating redraws nothing. The app uses the [GRID_DEFAULT] grid in normal drawing; levers 8
//! to 10 pick another, and 2 to 7 go back to the single image.
//!
//! **The cost of pasting on the wrist was not measured** (left for C16). The switch in Settings
//! ("Ruas em imagem", streets in image) exists to compare the two paths on the watch.
class StreetCache {

    //! `Storage` key of the switch. Outside the `CONFIG` values: the watch menu writes it, and
    //! the phone's `CONFIG` 17 does too (C16, `MotoNavApp.applyMapSwitches`).
    static const PREF = "streetCache";

    //! The 16-bit image ([imageOptions]) or the SDK's default depth. On with no stored
    //! value. C16 test switch (`CONFIG` 19): the 16-bit image had never been
    //! checked on the wrist, and on the first ride with it the streets did not show up (2026-10-19).
    static const PREF_16BIT = "street16bit";
    var sixteenBits as Boolean = true;

    //! Image side, in px. It must contain the glass (circle of radius [GLASS_PX]) at any
    //! heading and still have slack for the rider to move while the next one is drawn: 640 leaves 93 px,
    //! or 112 m at 1.2 m/px. At 16 bits per pixel that is 800 KB per image, 1.6 MB both, inside the
    //! 4 MB pool. A choice, not a measurement.
    const SIDE_FLAT = 640;

    //! Side of the **tilted** image: the glass becomes an ellipse of 227 / 0.72 ≈ 315 px along the heading, and 816 is
    //! the side that leaves the same slack as the flat one in the worst heading (the axes): 408 − 40 − 315 = 53 px. That is
    //! 1.33 MB per image, 2.66 MB both, in the 4 MB pool; if the pool refuses, the image goes back to
    //! 640 and the map stops being tilted ([tiltRefused]). The SPEC estimated 730, which left the slack
    //! of a new image below [REBUILD_SLACK_PX] on the axes: the image would be born asking for another.
    const SIDE_TILT = 816;

    //! The side and half-side of the current image ([SIDE_FLAT] or [SIDE_TILT]).
    var side as Number = SIDE_FLAT;
    var half as Float = 320.0;

    //! The paste's flattening along the heading: 1 is flat, `DesignTokens.TILT_K` is tilted ([setTilt]).
    var tiltK as Float = 1.0;

    //! The pool refused the tilted image: the map stayed flat until the app reopens.
    var tiltRefused as Boolean = false;

    //! Glass radius, in px.
    const GLASS_PX = 227.0;

    //! The image center goes this far ahead of the glass center, along the heading: whoever moves
    //! forward uses the front slack.
    const LEAD_PX = 40.0;

    //! Below this slack, in image px, the next one starts. With [LEAD_PX], a new image has
    //! 53 px of slack; the rider moves about 80 px until the next one starts, leaving ~40 px (50 m at
    //! 1.2 m/px) for it to be ready.
    const REBUILD_SLACK_PX = 50.0;

    //! A zoom that changes less than this keeps the current image, pasted at another scale. More
    //! than this asks for another (the one already being drawn continues if the difference is smaller than
    //! [RESTART_SCALE]: the auto-zoom arrives in small steps and cannot restart everything on each one).
    const RESCALE = 0.03;
    const RESTART_SCALE = 0.15;

    //! Work per step, in the currency of the `MapRenderer` leash (one point ≈ 80 instructions, the
    //! watchdog kills at ~3,000). 600 keeps the step at a fifth of what kills. A choice, not a measurement.
    const SLICE_WORK = 600;

    //! And time per step: the step also stops here, so it does not hold the screen. On the simulator, which
    //! draws thick lines slowly, the test city took 3.4 s in 4 steps of 600 points
    //! (2026-10-17); the watchdog counts instructions, not time. A choice, not a measurement.
    const SLICE_MS = 60;

    //! The paste filter. Public so the test can measure the point against bilinear.
    var filterMode as Graphics.FilterMode = Graphics.FILTER_MODE_BILINEAR;

    //! **The diagnostic lever (C16, `Config.streetDiag`).** On the wrist the 640 px image is
    //! built and pasted and the glass shows no street at all. In `v1.2.7`, the 454 one (the screen size)
    //! showed the streets at once, and the 640 one not even with a pink square on top: the Venu 4 does not show a
    //! BufferedBitmap bigger than the screen, or bigger than some limit between 454 and 640 (on the wrist, with the bike
    //! stopped). Drawing in `onUpdate` and a single `getDc()` changed nothing. Those of `v1.2.8`
    //! look for the largest side that shows up: the bigger, the more slack to move without rebuilding the image.
    //! [DIAG_OFF] is the usual path.
    var diag as Number = DIAG_OFF;
    static const DIAG_OFF = 0;
    //! Control: street by street straight on the screen, with no image (`MapRenderer.imageOn` turns it off).
    static const DIAG_LIVE = 1;
    //! Levers 2 and 3: a single image of [DIAG_SIDES] px, flat and born centered on the glass.
    //! In `v1.2.8` the wrist showed 454 and 480 px and nothing from 512 up (16 bits: 460,800 B show,
    //! 524,288 B do not; `DECISIONS.md` §"the street image ceiling").
    static const DIAG_SIZE_FIRST = 2;
    static const DIAG_SIDES = [454, 480] as Array<Number>;
    //! Levers 4 to 7 (v1.2.9) are **probes**: the 480 px streets image plus 0 to 3 more 480 px images
    //! held at the same time, each with an X of its own color pasted in miniature at the top of the
    //! glass. How many show up on the wrist says whether the ~460 KB ceiling is per image or for the whole pool.
    static const DIAG_PROBE_FIRST = 4;
    static const PROBE_SIDE = 480;
    //! Levers 8 to 10 (v1.2.9) are tile **grids** ([grid]): 2×2 of 480, 3×3 of 320 and
    //! 4×4 of 240 px.
    static const DIAG_GRID_FIRST = 8;
    static const GRID_COUNTS = [2, 3, 4] as Array<Number>;
    static const GRID_SIDES = [480, 320, 240] as Array<Number>;
    //! The grid of normal drawing when the app asks for tiles ([gridDefault]): 4×4 of 240 is the one with
    //! the most slack around the glass, 354 px from the glass center to the edge in the worst case (against 316 for
    //! 3×3 and 238 for 2×2), and it fits tilted (315 px along the heading). 17 images of 115,200 B, 1.96 MB.
    //! Chosen by the math and the simulator; the wrist decides, through levers 8 to 10.
    static const GRID_DEFAULT = 2;
    //! The names the log shows, by value.
    static const DIAG_NAMES = ["normal", "rua por rua", "imagem unica de 454", "imagem unica de 480",
        "sonda 1x480", "sonda 2x480", "sonda 3x480", "sonda 4x480", "ladrilhos 2x2 de 480",
        "ladrilhos 3x3 de 320", "ladrilhos 4x4 de 240"] as Array<String>;

    //! Normal drawing (lever 0) uses the [GRID_DEFAULT] grid instead of the single 640/816 image,
    //! which the Venu 4 does not show. The app turns it on ([MapRenderer.useStreetGrid]); the single-image tests
    //! create the map without turning it on.
    var gridDefault as Boolean = false;

    //! How many tiles per side; 0 is the single image. With a grid, [side] is the side of one tile.
    var grid as Number = 0;

    //! Tiles overlap by this much on each side, so the paste's bilinear filter does not
    //! open a seam between two neighbors.
    const OVERLAP_PX = 2;

    //! The tile set only moves when the glass center goes this far past the tile's
    //! edge: without this, stopped on the boundary, the set would swap on every GPS jump.
    const GRID_HYST = 0.1;

    //! The on-screen image's `isCached()` on every paste, for the log: how many checks and how many
    //! found the memory recycled. A BufferedBitmap purged from the pool loses its drawing and does not come back
    //! (Core Topics "Graphics", "Buffered Bitmaps and the Graphics Pool").
    var cachedChecks as Number = 0;
    var cachedMisses as Number = 0;

    //! The single image with a lever's side (2 to 7): without the 640 one's slack, it is born
    //! centered on the glass. Bench only.
    function leverSized() as Boolean {
        return diag >= DIAG_SIZE_FIRST && diag < DIAG_GRID_FIRST;
    }

    //! How many 480 images the lever's probe holds at the same time, counting the streets one; 0 without a probe.
    function probeCount() as Number {
        return diag >= DIAG_PROBE_FIRST && diag < DIAG_GRID_FIRST ? diag - DIAG_PROBE_FIRST + 1 : 0;
    }

    //! The same decimation as per-frame drawing (`MapRenderer.MIN_STEP_PX`).
    const MIN_STEP_PX = 2.5;

    //! The round joint only enters a real bend (`MapRenderer.STREET_JOIN_PX`).
    const JOIN_PX = 1.0;

    //! The first class drawn, the local one, gets no edge: black on the black ground does not show,
    //! and the edge only serves to cut the class below.
    const EDGE_FROM_LOD = Protocol.CORRIDOR_LOD_COUNT - 2;

    //! The cache cannot get an image (pool full, API missing): the map goes back to per-frame drawing.
    var failed as Boolean = false;

    // The on-screen image: where it is in the world, at what scale and with which streets.
    private var _front as BufferedBitmap? = null;
    private var _frontRef as BufferedBitmapReference? = null;
    private var _fx as Float = 0.0;
    private var _fy as Float = 0.0;
    private var _fScale as Float = -1.0;
    private var _fRev as Number = -1;
    private var _fSource as CorridorModel? = null;
    private var _fColors as Array<Number> = [] as Array<Number>;
    private var _fWidths as Array<Number> = [] as Array<Number>;

    // The image being drawn.
    private var _back as BufferedBitmap? = null;
    private var _backRef as BufferedBitmapReference? = null;
    private var _building as Boolean = false;
    private var _bx as Float = 0.0;
    private var _by as Float = 0.0;
    private var _bScale as Float = 1.0;
    private var _bInv as Float = 1.0;
    private var _bStepSq as Float = 0.0;
    private var _bRev as Number = -1;
    private var _bSource as CorridorModel? = null;
    private var _bColors as Array<Number> = [] as Array<Number>;
    private var _bWidths as Array<Number> = [] as Array<Number>;
    //! Where the drawing stopped: LOD (fine to coarse, [LOD_START] = needs clearing), pass (0 the
    //! edge, 1 the core), block and way.
    private var _bLod as Number = 0;
    private var _bPass as Number = 0;
    private var _bBlock as Number = 0;
    private var _bWay as Number = -1;
    private var _bMs as Number = 0;
    private var _bWork as Number = 0;
    private var _bSteps as Number = 0;
    private var _bWays as Number = 0;

    const LOD_START = 99;

    private var _transform as AffineTransform? = null;

    // The grid ([grid] > 0). Tiles are pinned to the world: (i, j) covers the square of side
    // [_gPitch] m from (i·pitch, j·pitch), at scale [_gScale]. Those that stay valid when the
    // rider moves are not redrawn; only the new ones, one at a time, on the spare image ([_back]).
    private var _gScale as Float = -1.0;
    private var _gPitch as Float = 1.0;
    private var _gHave as Boolean = false;
    private var _gi0 as Number = 0;
    private var _gj0 as Number = 0;
    //! The tiles' content: goes up when the corridor, the colors or the widths change. A tile
    //! of an old generation is still pasted (shows the streets from before) until it is replaced.
    private var _gGen as Number = 0;
    private var _gSource as CorridorModel? = null;
    private var _gRev as Number = -1;
    private var _gColors as Array<Number> = [] as Array<Number>;
    private var _gWidths as Array<Number> = [] as Array<Number>;
    private var _gx as Float = 0.0;
    private var _gy as Float = 0.0;
    private var _covered as Boolean = false;
    // The slots: [grid]² images, each with the tile it holds; generation −1 is an empty slot.
    private var _sImg as Array<BufferedBitmap?> = [] as Array<BufferedBitmap?>;
    private var _sRef as Array<BufferedBitmapReference?> = [] as Array<BufferedBitmapReference?>;
    private var _sX as Array<Float> = [] as Array<Float>;
    private var _sY as Array<Float> = [] as Array<Float>;
    private var _sScale as Array<Float> = [] as Array<Float>;
    private var _sI as Array<Number> = [] as Array<Number>;
    private var _sJ as Array<Number> = [] as Array<Number>;
    private var _sGen as Array<Number> = [] as Array<Number>;
    // The tile being drawn.
    private var _bI as Number = 0;
    private var _bJ as Number = 0;
    private var _bGen as Number = -1;

    // The probes (levers 4 to 7): the extra images, held, and how many the pool gave.
    private var _probes as Array<BufferedBitmap> = [] as Array<BufferedBitmap>;
    private var _probeRefs as Array<BufferedBitmapReference> = [] as Array<BufferedBitmapReference>;
    private var _probeTried as Boolean = false;
    //! For the test and the log: how many extra probe images the pool gave.
    var probesHeld as Number = 0;
    //! Tiles pasted in the last frame, for the test.
    var tilesPasted as Number = 0;

    //! For the frame summary: images ready since the last [resetStats], and the last whole one.
    var builds as Number = 0;
    var lastBuildMs as Number = 0;
    var lastBuildWork as Number = 0;
    var lastBuildSteps as Number = 0;
    var lastBuildWays as Number = 0;
    //! The most expensive step since the last [resetStats], in work points.
    var stepWorkMax as Number = 0;
    //! The smallest slack ([slack]) of a frame that pasted the image since the last [resetStats], in px;
    //! `null` with no such frame. Negative (down to −[UNCOVERED_PX]): the glass showed black at the edge.
    var slackMin as Number? = null;
    //! Frames since the last [resetStats] in which no image covered the glass ([covers]) and
    //! `MapRenderer` drew street by street.
    var fallbacks as Number = 0;

    //! How many px of black at the edge the glass accepts before the frame drops the image and draws street
    //! by street: the first image, a GPS jump or a large zoom leave the glass without it.
    const UNCOVERED_PX = 50.0;
    private var _room as Float = -320.0;

    function initialize() {
    }

    //! Flat (`k` = 1) or tilted (`k` < 1). Changed: both images are of the other size, and go away.
    //! Tiles are north up and do not change with K: only the paste and the coverage change.
    function setTilt(k as Float) as Void {
        if (k == tiltK) {
            return;
        }
        tiltK = k;
        if (grid > 0) {
            return;
        }
        resize();
        drop();
    }

    //! The image side and the grid: the lever's, otherwise the normal grid ([gridDefault]), otherwise the
    //! flat or tilted single image.
    private function resize() as Void {
        var g = -1;
        if (diag >= DIAG_GRID_FIRST) {
            g = diag - DIAG_GRID_FIRST;
        } else if (diag == DIAG_OFF && gridDefault) {
            g = GRID_DEFAULT;
        }
        if (g >= 0) {
            grid = GRID_COUNTS[g] as Number;
            side = GRID_SIDES[g] as Number;
        } else {
            grid = 0;
            if (diag >= DIAG_PROBE_FIRST) {
                side = PROBE_SIDE;
            } else if (diag >= DIAG_SIZE_FIRST) {
                side = DIAG_SIDES[diag - DIAG_SIZE_FIRST] as Number;
            } else {
                side = tiltK < 1.0 ? SIDE_TILT : SIDE_FLAT;
            }
        }
        half = side / 2.0;
    }

    //! Turns on the grid in normal drawing ([gridDefault]). The current images go away.
    function useGrid() as Void {
        if (gridDefault) {
            return;
        }
        gridDefault = true;
        resize();
        drop();
    }

    //! The diagnostic lever ([diag]). Changed: the images go away, so the new side applies on the
    //! next one, and the pool gets another chance.
    function setDiag(value as Number) as Void {
        if (value == diag) {
            return;
        }
        diag = value;
        failed = false;
        tiltRefused = false;
        resize();
        drop();
    }

    //! 16 bits or the SDK default. Changed: both images are of another format, and go away.
    function setSixteenBits(on as Boolean) as Void {
        if (on == sixteenBits) {
            return;
        }
        sixteenBits = on;
        failed = false;
        tiltRefused = false;
        drop();
    }

    //! The 16-bit switch in `Storage`. With no stored value, on.
    static function wants16Bit() as Boolean {
        var value = Storage.getValue(PREF_16BIT);
        return value instanceof Boolean ? value as Boolean : true;
    }

    //! The `Storage` switch. With no stored value, on.
    static function wanted() as Boolean {
        var value = Storage.getValue(PREF);
        return value instanceof Boolean ? value as Boolean : true;
    }

    //! Does the cache still have an image to draw?
    function building() as Boolean {
        return _building;
    }

    //! Is there an image to paste? On the grid, one tile is enough.
    function ready() as Boolean {
        if (grid > 0) {
            for (var k = 0; k < _sGen.size(); k++) {
                if ((_sGen[k] as Number) >= 0 && _sImg[k] != null) {
                    return true;
                }
            }
            return false;
        }
        return _front != null;
    }

    //! On the grid: are all the tiles around the glass ready, at the current scale and content?
    function gridComplete() as Boolean {
        if (grid == 0 || !_gHave) {
            return false;
        }
        for (var i = _gi0; i < _gi0 + grid; i++) {
            for (var j = _gj0; j < _gj0 + grid; j++) {
                if (slotOf(i, j) < 0) {
                    return false;
                }
            }
        }
        return true;
    }

    function resetStats() as Void {
        builds = 0;
        stepWorkMax = 0;
        slackMin = null;
        fallbacks = 0;
        cachedChecks = 0;
        cachedMisses = 0;
    }

    //! Does the on-screen image cover the glass of the last [plan], with at most [UNCOVERED_PX] of black at the
    //! edge? With no image, or with the glass far from it, the frame draws street by street until the new one is out.
    function covers() as Boolean {
        if (grid > 0) {
            return !failed && _covered;
        }
        return !failed && _front != null && _room >= -UNCOVERED_PX;
    }

    //! Drops both images and what was being drawn. For the switch and for the tests.
    function drop() as Void {
        _front = null;
        _frontRef = null;
        _back = null;
        _backRef = null;
        _building = false;
        _fScale = -1.0;
        _fRev = -1;
        _fSource = null;
        _bSource = null;
        var slots = grid * grid;
        _sImg = new [slots] as Array<BufferedBitmap?>;
        _sRef = new [slots] as Array<BufferedBitmapReference?>;
        _sX = new [slots] as Array<Float>;
        _sY = new [slots] as Array<Float>;
        _sScale = new [slots] as Array<Float>;
        _sI = new [slots] as Array<Number>;
        _sJ = new [slots] as Array<Number>;
        _sGen = new [slots] as Array<Number>;
        for (var k = 0; k < slots; k++) {
            _sGen[k] = -1;
            _sX[k] = 0.0;
            _sY[k] = 0.0;
            _sScale[k] = 1.0;
            _sI[k] = 0;
            _sJ[k] = 0;
        }
        _gScale = -1.0;
        _gHave = false;
        _gSource = null;
        _gRev = -1;
        _covered = false;
        _probes = [] as Array<BufferedBitmap>;
        _probeRefs = [] as Array<BufferedBitmapReference>;
        _probeTried = false;
        probesHeld = 0;
    }

    //! Checks, on every frame, whether the on-screen image still serves for this center, heading and scale, and
    //! starts another if not. `cx`/`cy` is the rider's position (the anchor), `ahead` the px from the
    //! anchor to the glass center. Cheap: a few computations and no drawing.
    function plan(
        corridor as CorridorModel,
        cx as Float,
        cy as Float,
        sin as Float,
        cos as Float,
        scale as Float,
        ahead as Float,
        widths as Array<Number>
    ) as Void {
        if (failed) {
            return;
        }
        var colors = currentColors();
        var gx = cx + ahead * scale * sin;
        var gy = cy + ahead * scale * cos;
        if (grid > 0) {
            planGrid(corridor, gx, gy, sin, cos, scale, colors, widths);
            return;
        }
        var room = slack(gx, gy, scale, sin, cos);
        _room = room;
        if (_front != null && room >= -UNCOVERED_PX) {
            var now = room.toNumber();
            var low = slackMin;
            if (low == null || now < (low as Number)) {
                slackMin = now;
            }
        }

        if (_building) {
            // The one being drawn continues, unless what it would show has changed too much.
            var restart = corridor != _bSource || corridor.revision != _bRev || !same(colors, _bColors)
                || !same(widths, _bWidths) || off(scale, _bScale) > RESTART_SCALE;
            if (!restart) {
                return;
            }
        } else if (_front != null && corridor == _fSource && corridor.revision == _fRev
                && same(colors, _fColors)
                && same(widths, _fWidths) && off(scale, _fScale) <= RESCALE
                && room >= (leverSized() ? -UNCOVERED_PX / 2 : REBUILD_SLACK_PX)) {
            return;
        }
        // A lever's image has little or no slack to go ahead: it is born centered on the glass.
        var lead = leverSized() ? 0.0 : LEAD_PX;
        start(corridor, gx + lead * scale * sin, gy + lead * scale * cos, scale, colors, widths);
    }

    //! The grid [plan]. The tile set is the [grid]² around the glass center, without
    //! going ahead: on the grid, the slack is equal on all sides (the heading changes without redrawing anything). If a
    //! tile is missing: starts the one nearest the glass. A ready tile stays until it leaves the set.
    private function planGrid(
        corridor as CorridorModel,
        gx as Float,
        gy as Float,
        sin as Float,
        cos as Float,
        scale as Float,
        colors as Array<Number>,
        widths as Array<Number>
    ) as Void {
        _gx = gx;
        _gy = gy;
        if (corridor != _gSource) {
            // Another route: the streets from before do not serve even as a preview.
            for (var k = 0; k < _sGen.size(); k++) {
                _sGen[k] = -1;
            }
            _gSource = corridor;
            _gRev = corridor.revision;
            _gColors = colors;
            _gWidths = widths;
            _gGen++;
            _building = false;
        } else if (corridor.revision != _gRev || !same(colors, _gColors) || !same(widths, _gWidths)) {
            _gRev = corridor.revision;
            _gColors = colors;
            _gWidths = widths;
            _gGen++;
        }
        if (_gScale <= 0.0 || off(scale, _gScale) > RESCALE) {
            _gScale = scale;
            _gPitch = ((side - 2 * OVERLAP_PX) * scale).toFloat();
            _gHave = false;
        }
        var fx = gx / _gPitch - (grid - 1) / 2.0;
        var fy = gy / _gPitch - (grid - 1) / 2.0;
        if (!_gHave || fx - _gi0 < -GRID_HYST || fx - _gi0 >= 1.0 + GRID_HYST) {
            _gi0 = Math.floor(fx).toNumber();
        }
        if (!_gHave || fy - _gj0 < -GRID_HYST || fy - _gj0 >= 1.0 + GRID_HYST) {
            _gj0 = Math.floor(fy).toNumber();
        }
        _gHave = true;
        _covered = coverage(gx, gy, sin, cos, scale);
        _room = _covered ? 0.0 : -half;

        if (_building) {
            if (_bGen == _gGen && _bScale == _gScale && inSet(_bI, _bJ)) {
                return;
            }
            // The tile being made is no longer valid (the rider moved, the zoom or the corridor changed).
            _building = false;
        }
        startNextTile(corridor);
    }

    //! Starts the missing tile nearest the glass, if any is missing. Called by [planGrid] and
    //! as soon as a tile is ready, so the next does not wait for the next frame.
    private function startNextTile(corridor as CorridorModel) as Void {
        var gx = _gx;
        var gy = _gy;
        var bestI = 0;
        var bestJ = 0;
        var best = -1.0;
        for (var i = _gi0; i < _gi0 + grid; i++) {
            for (var j = _gj0; j < _gj0 + grid; j++) {
                if (slotOf(i, j) >= 0) {
                    continue;
                }
                var dx = (i + 0.5) * _gPitch - gx;
                var dy = (j + 0.5) * _gPitch - gy;
                var d = dx * dx + dy * dy;
                if (best < 0.0 || d < best) {
                    best = d;
                    bestI = i;
                    bestJ = j;
                }
            }
        }
        if (best < 0.0) {
            return;
        }
        _bI = bestI;
        _bJ = bestJ;
        _bGen = _gGen;
        start(corridor, ((bestI + 0.5) * _gPitch).toFloat(), ((bestJ + 0.5) * _gPitch).toFloat(), _gScale,
            _gColors, _gWidths);
    }

    //! How many slots the grid has ([grid]²).
    function tileCount() as Number {
        return _sGen.size();
    }

    //! Slot `k`: `[center x, center y, scale]` of the tile it holds, or null if empty. For the test.
    function tile(k as Number) as Array<Float>? {
        if ((_sGen[k] as Number) < 0 || _sImg[k] == null) {
            return null;
        }
        return [_sX[k] as Float, _sY[k] as Float, _sScale[k] as Float] as Array<Float>;
    }

    //! Is tile (i, j) part of the current set?
    private function inSet(i as Number, j as Number) as Boolean {
        return i >= _gi0 && i < _gi0 + grid && j >= _gj0 && j < _gj0 + grid;
    }

    //! The slot that holds tile (i, j) ready, at the current scale and content; −1 if none.
    private function slotOf(i as Number, j as Number) as Number {
        for (var k = 0; k < _sGen.size(); k++) {
            if (_sGen[k] == _gGen && _sI[k] == i && _sJ[k] == j && _sScale[k] == _gScale && _sImg[k] != null) {
                return k;
            }
        }
        return -1;
    }

    //! The glass edge points that coverage checks: 16 on the ellipse (the circle, flat) and the center.
    const COVER_SAMPLES = 16;

    //! Does the glass centered on the world at (`gx`, `gy`) fit in the ready tiles? Checks the center and
    //! [COVER_SAMPLES] edge points: each must fall inside a tile with an image, of
    //! any scale or generation (the one from before still shows the right streets in the right place).
    private function coverage(gx as Float, gy as Float, sin as Float, cos as Float, scale as Float) as Boolean {
        var a = GLASS_PX * scale;
        var b = a / tiltK;
        for (var n = 0; n <= COVER_SAMPLES; n++) {
            var px = gx;
            var py = gy;
            if (n < COVER_SAMPLES) {
                var t = 2.0 * Math.PI * n / COVER_SAMPLES;
                var across = a * Math.cos(t);
                var along = b * Math.sin(t);
                // Sideways is (cos, −sin) in the world; along the heading, (sin, cos).
                px = (gx + across * cos + along * sin).toFloat();
                py = (gy - across * sin + along * cos).toFloat();
            }
            if (!pointCovered(px, py)) {
                return false;
            }
        }
        return true;
    }

    private function pointCovered(x as Float, y as Float) as Boolean {
        for (var k = 0; k < _sGen.size(); k++) {
            if ((_sGen[k] as Number) < 0 || _sImg[k] == null) {
                continue;
            }
            var reach = (half - OVERLAP_PX) * (_sScale[k] as Float);
            var dx = x - (_sX[k] as Float);
            var dy = y - (_sY[k] as Float);
            if (dx >= -reach && dx <= reach && dy >= -reach && dy <= reach) {
                return true;
            }
        }
        return false;
    }

    //! The ready tile enters a slot: an empty one, otherwise the one of the tile outside the set (or of
    //! old scale or generation) farthest from the glass. The image that leaves becomes the next one's spare.
    private function placeTile() as Void {
        var pick = -1;
        var far = -1.0;
        for (var k = 0; k < _sGen.size(); k++) {
            var gen = _sGen[k] as Number;
            if (gen < 0) {
                pick = k;
                break;
            }
            if (gen == _gGen && _sScale[k] == _gScale && inSet(_sI[k] as Number, _sJ[k] as Number)) {
                continue;
            }
            var dx = (_sX[k] as Float) - _gx;
            var dy = (_sY[k] as Float) - _gy;
            var d = dx * dx + dy * dy;
            if (d > far) {
                far = d;
                pick = k;
            }
        }
        if (pick < 0) {
            // All slots hold tiles of the set: this one was left over, and the image stays as a spare.
            return;
        }
        var oldImage = _sImg[pick];
        var oldRef = _sRef[pick];
        _sImg[pick] = _back;
        _sRef[pick] = _backRef;
        _back = oldImage;
        _backRef = oldRef;
        _sX[pick] = _bx;
        _sY[pick] = _by;
        _sScale[pick] = _bScale;
        _sI[pick] = _bI;
        _sJ[pick] = _bJ;
        _sGen[pick] = _bGen;
    }

    //! Pastes the tiles that touch the glass: the old ones (another scale or generation) first, the current ones
    //! on top, so the overlap shows the new streets.
    private function blitGrid(
        dc as Dc,
        cx as Float,
        cy as Float,
        sin as Float,
        cos as Float,
        scale as Float,
        ax as Float,
        ay as Float
    ) as Boolean {
        var transform = _transform;
        if (transform == null) {
            transform = new AffineTransform();
            _transform = transform;
        }
        // The glass, seen from the world, fits in a square of 227 / K px half-side around the center.
        var glass = GLASS_PX * scale / tiltK;
        tilesPasted = 0;
        for (var pass = 0; pass < 2; pass++) {
            for (var k = 0; k < _sGen.size(); k++) {
                var image = _sImg[k];
                var gen = _sGen[k] as Number;
                if (image == null || gen < 0) {
                    continue;
                }
                var current = gen == _gGen && _sScale[k] == _gScale;
                if (current != (pass == 1)) {
                    continue;
                }
                var tx = _sX[k] as Float;
                var ty = _sY[k] as Float;
                var reach = half * (_sScale[k] as Float) + glass;
                if (tx - _gx > reach || _gx - tx > reach || ty - _gy > reach || _gy - ty > reach) {
                    continue;
                }
                if (image has :isCached) {
                    cachedChecks++;
                    if (!image.isCached()) {
                        cachedMisses++;
                    }
                }
                transform.setMatrix(matrixAt(tx, ty, _sScale[k] as Float, cx, cy, sin, cos, scale, ax, ay));
                dc.drawBitmap2(0, 0, image, {
                    :transform => transform,
                    :filterMode => filterMode
                });
                tilesPasted++;
            }
        }
        return tilesPasted > 0;
    }

    //! The probes' colors, in order: red, green, blue and yellow, one per image.
    static const PROBE_COLORS = [0xFF2020, 0x20FF20, 0x4080FF, 0xFFE020] as Array<Number>;

    //! The probe's extra images ([probeCount] − 1), held and painted with their color's X. Once
    //! per lever: whatever the pool refuses stays out, and the log says how many came.
    private function holdProbes() as Void {
        if (_probeTried) {
            return;
        }
        _probeTried = true;
        var want = probeCount() - 1;
        var why = "";
        for (var n = 0; n < want; n++) {
            try {
                var ref = Graphics.createBufferedBitmap(imageOptions(PROBE_SIDE, sixteenBits));
                var image = ref.get() as BufferedBitmap?;
                if (image == null) {
                    why = " (get nulo)";
                    break;
                }
                var dc = image.getDc();
                dc.setColor(0x202020, 0x202020);
                dc.clear();
                dc.setColor(PROBE_COLORS[n + 1] as Number, Graphics.COLOR_TRANSPARENT);
                dc.setPenWidth(40);
                dc.drawLine(40, 40, PROBE_SIDE - 40, PROBE_SIDE - 40);
                dc.drawLine(PROBE_SIDE - 40, 40, 40, PROBE_SIDE - 40);
                _probes.add(image);
                _probeRefs.add(ref);
            } catch (ex) {
                var message = ex.getErrorMessage();
                why = " (" + (message != null ? message : "pool refused") + ")";
                break;
            }
        }
        probesHeld = _probes.size();
        Diag.add("probe: " + (probesHeld + 1).toString() + " of " + probeCount().toString()
            + " images of 480" + why);
    }

    //! The probe in the middle of the glass, above the rider and below the HUD sign: the first image is the
    //! streets one, and each extra enters in miniature (1/5, 96 px), side by side, with its color's X.
    private function blitProbes(dc as Dc) as Void {
        holdProbes();
        var transform = _transform;
        if (transform == null) {
            transform = new AffineTransform();
            _transform = transform;
        }
        var k = 0.2;
        var count = _probes.size();
        for (var n = 0; n < count; n++) {
            var image = _probes[n];
            if (image has :isCached) {
                cachedChecks++;
                if (!image.isCached()) {
                    cachedMisses++;
                }
            }
            var x = 227.0 - count * 50.0 + n * 100.0 + 2.0;
            transform.setMatrix([k, 0.0, x, 0.0, k, 180.0] as [Float, Float, Float, Float, Float, Float]);
            dc.drawBitmap2(0, 0, image, { :transform => transform });
        }
    }

    //! The slack, in on-screen image px, between the glass centered on the world at (`gx`, `gy`) and its
    //! edge. Negative: the glass already goes past the image. Tilted, the glass seen from the image is an ellipse of
    //! semi-axes 227 (sideways) and 227 / K (along the heading `sin`, `cos`); the slack is that of the rectangle that
    //! encloses it, which for K = 1 is the usual circle.
    function slack(gx as Float, gy as Float, scale as Float, sin as Float, cos as Float) as Float {
        if (_front == null) {
            return -half;
        }
        var ou = (gx - _fx) / _fScale;
        var ov = (gy - _fy) / _fScale;
        if (ou < 0.0) {
            ou = -ou;
        }
        if (ov < 0.0) {
            ov = -ov;
        }
        var a = GLASS_PX * scale / _fScale;
        var b = a / tiltK;
        var extX = Math.sqrt(a * a * cos * cos + b * b * sin * sin);
        var extY = Math.sqrt(a * a * sin * sin + b * b * cos * cos);
        var roomX = half - ou - extX;
        var roomY = half - ov - extY;
        return (roomX < roomY ? roomX : roomY).toFloat();
    }

    //! Pastes the image on the screen: the same `screen = anchor + R(heading) · (p − center) / scale` as
    //! `MapRenderer`, assembled as a single matrix. Returns whether it pasted.
    function blit(
        dc as Dc,
        cx as Float,
        cy as Float,
        sin as Float,
        cos as Float,
        scale as Float,
        ax as Float,
        ay as Float
    ) as Boolean {
        if (grid > 0) {
            return blitGrid(dc, cx, cy, sin, cos, scale, ax, ay);
        }
        var image = _front;
        if (image == null) {
            return false;
        }
        if (image has :isCached) {
            cachedChecks++;
            if (!image.isCached()) {
                cachedMisses++;
            }
        }
        var m = matrix(cx, cy, sin, cos, scale, ax, ay);
        var transform = _transform;
        if (transform == null) {
            transform = new AffineTransform();
            _transform = transform;
        }
        transform.setMatrix(m);
        dc.drawBitmap2(0, 0, image, {
            :transform => transform,
            :filterMode => filterMode
        });
        if (probeCount() > 1) {
            blitProbes(dc);
        }
        return true;
    }

    //! The matrix `[m00, m01, m02, m10, m11, m12]` that takes the image pixel (u, v) on screen to the
    //! screen. With `k` = image scale / frame scale and the image center at (`_fx`, `_fy`):
    //!
    //! ```
    //! world = (fx + k·s·(u − H),  fy − k·s·(v − H))      s = frame scale
    //! screen = anchor + (dx·cos − dy·sin,  −K·(dx·sin + dy·cos))
    //! ```
    //!
    //! K ([tiltK]) flattens the matrix's bottom row around the anchor: it is the tilt, with no vanishing
    //! point. Public so the test can check against the renderer's `screenX`/`screenY`.
    function matrix(
        cx as Float,
        cy as Float,
        sin as Float,
        cos as Float,
        scale as Float,
        ax as Float,
        ay as Float
    ) as [Float, Float, Float, Float, Float, Float] {
        return matrixAt(_fx, _fy, _fScale, cx, cy, sin, cos, scale, ax, ay);
    }

    //! The [matrix] of an image with center (`fx`, `fy`) in the world and scale `fScale`: the single image
    //! or a grid tile. Public so the test can check each tile.
    function matrixAt(
        fx as Float,
        fy as Float,
        fScale as Float,
        cx as Float,
        cy as Float,
        sin as Float,
        cos as Float,
        scale as Float,
        ax as Float,
        ay as Float
    ) as [Float, Float, Float, Float, Float, Float] {
        var k = fScale / scale;
        var dx0 = (fx - cx) / scale;
        var dy0 = (fy - cy) / scale;
        var t = tiltK;
        var m00 = k * cos;
        var m01 = k * sin;
        var m10 = -k * sin * t;
        var m11 = k * cos * t;
        var m02 = ax + dx0 * cos - dy0 * sin - half * (m00 + m01);
        var m12 = ay - (dx0 * sin + dy0 * cos) * t - half * (m10 + m11);
        return [m00.toFloat(), m01.toFloat(), m02.toFloat(), m10.toFloat(), m11.toFloat(),
            m12.toFloat()] as [Float, Float, Float, Float, Float, Float];
    }

    //! Where the world point lands on the image being drawn, in px. For the test.
    function imageX(x as Float) as Float {
        return (half + (x - _bx) * _bInv).toFloat();
    }

    function imageY(y as Float) as Float {
        return (half - (y - _by) * _bInv).toFloat();
    }

    //! One step of drawing the new image, up to [SLICE_WORK] work points. Returns `true`
    //! when it is ready and becomes the on-screen one.
    function step(corridor as CorridorModel) as Boolean {
        return stepUpTo(corridor, SLICE_WORK);
    }

    //! The [step] with another work ceiling.
    function stepUpTo(corridor as CorridorModel, limit as Number) as Boolean {
        if (!_building) {
            return false;
        }
        if (corridor != _bSource || corridor.revision != _bRev) {
            // The stored indices belong to the old corridor: restarts in the same place.
            _bSource = corridor;
            begin(corridor.revision);
        }
        var image = _back;
        if (image == null) {
            image = allocate();
            if (image == null) {
                return false;
            }
            _back = image;
        }
        var started = System.getTimer();
        var dc = image.getDc();
        var spent = 0;
        if (_bLod == LOD_START) {
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.clear();
            _bLod = Protocol.CORRIDOR_LOD_COUNT - 1;
        }
        var span = CorridorModel.WAYS_PER_BLOCK;
        var reach = half * _bScale;
        var minX = _bx - reach;
        var maxX = _bx + reach;
        var minY = _by - reach;
        var maxY = _by + reach;

        // Fine to coarse, like per-frame drawing: the avenue ends up on top of the local street. In
        // each class, the black edge of all ways and then the core: two streets of the same class
        // merge at the crossing, and the bigger one cuts the smaller (sheet 8).
        while (_bLod >= 0) {
            var lod = _bLod;
            if (_bPass == 0 && lod > EDGE_FROM_LOD) {
                _bPass = 1;
            }
            var xs = corridor.xs[lod] as Array<Float>;
            var ys = corridor.ys[lod] as Array<Float>;
            var starts = corridor.wayStart[lod] as Array<Number>;
            var boxes = corridor.wayBox[lod] as Array<Float>;
            var blocks = corridor.blockBox[lod] as Array<Float>;
            var ways = boxes.size() / 4;
            var blockCount = blocks.size() / 4;
            var width = _bWidths[lod] as Number;
            if (_bPass == 0) {
                width += 2 * DesignTokens.ROAD_EDGE_PX;
            }
            // Round cap and bend on every class: the disc a little smaller than the stroke.
            var radius = (width - 2) / 2;
            if (radius < 1) {
                radius = 1;
            }
            var limit2 = (JOIN_PX * JOIN_PX / (radius * radius)).toFloat();
            // The edge goes without antialias: it is black on the ground's black and only shows in the cut of
            // a crossing. On the simulator this did not change the image time (the test city, 3.7 s
            // against 3.6 s), but on the wrist antialias costs: the route with both passes with
            // antialias took 87 ms (bench of 17/10). The wrist's math is for C16.
            dc.setAntiAlias(_bPass == 1);
            dc.setColor(_bPass == 0 ? DesignTokens.ROAD_EDGE : _bColors[lod] as Number,
                Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(width);

            while (_bBlock < blockCount) {
                if (_bWay < 0) {
                    var bb = _bBlock * 4;
                    spent++;
                    if (!inside(blocks, bb, minX, maxX, minY, maxY)) {
                        _bBlock++;
                        continue;
                    }
                    _bWay = _bBlock * span;
                }
                var to = (_bBlock + 1) * span;
                if (to > ways) {
                    to = ways;
                }
                while (_bWay < to) {
                    if (spent >= limit || System.getTimer() - started >= SLICE_MS) {
                        pause(started, spent);
                        return false;
                    }
                    var w = _bWay;
                    _bWay++;
                    spent++;
                    if (w + 1 < starts.size() && inside(boxes, w * 4, minX, maxX, minY, maxY)) {
                        spent += drawWay(dc, xs, ys, starts[w] as Number, starts[w + 1] as Number,
                            radius, limit2);
                        if (_bPass == 1) {
                            // Each way counts once, in the core: the edge is the same way.
                            _bWays++;
                        }
                    }
                }
                _bWay = -1;
                _bBlock++;
            }
            _bBlock = 0;
            _bWay = -1;
            if (_bPass == 0) {
                _bPass = 1;
            } else {
                _bPass = 0;
                _bLod--;
            }
        }
        pause(started, spent);
        finish();
        return true;
    }

    private function pause(started as Number, spent as Number) as Void {
        _bMs += System.getTimer() - started;
        _bWork += spent;
        _bSteps++;
        if (spent > stepWorkMax) {
            stepWorkMax = spent;
        }
    }

    //! The new image becomes the on-screen one, and the old one is kept for the next drawing. On the grid, the tile
    //! enters a slot ([placeTile]).
    private function finish() as Void {
        _building = false;
        builds++;
        lastBuildMs = _bMs;
        lastBuildWork = _bWork;
        lastBuildSteps = _bSteps;
        lastBuildWays = _bWays;
        if (grid > 0) {
            placeTile();
            var source = _bSource;
            if (source != null && _bGen == _gGen) {
                startNextTile(source);
            }
            return;
        }
        var oldImage = _front;
        var oldRef = _frontRef;
        _front = _back;
        _frontRef = _backRef;
        _back = oldImage;
        _backRef = oldRef;
        _fx = _bx;
        _fy = _by;
        _fScale = _bScale;
        _fRev = _bRev;
        _fSource = _bSource;
        _fColors = _bColors;
        _fWidths = _bWidths;
    }

    private function start(
        corridor as CorridorModel,
        x as Float,
        y as Float,
        scale as Float,
        colors as Array<Number>,
        widths as Array<Number>
    ) as Void {
        _building = true;
        _bx = x;
        _by = y;
        _bScale = scale;
        _bInv = (1.0 / scale).toFloat();
        var stepM = MIN_STEP_PX * scale;
        _bStepSq = (stepM * stepM).toFloat();
        _bColors = colors;
        _bWidths = widths;
        _bSource = corridor;
        begin(corridor.revision);
    }

    private function begin(revision as Number) as Void {
        _bRev = revision;
        _bLod = LOD_START;
        _bPass = 0;
        _bBlock = 0;
        _bWay = -1;
        _bMs = 0;
        _bWork = 0;
        _bSteps = 0;
        _bWays = 0;
    }

    //! Options for the image of side `side`: **16 bits per pixel**, no alpha channel. The SDK default is
    //! `ALPHA_BLENDING_FULL`, and on the simulator the default image takes double (32 bits): two of
    //! 816 px did not fit in the 4 MB pool (v1.1.5). The streets image is opaque (black background, pasted
    //! over black), and alpha is of no use in it. With `sixteen` false, the options are
    //! the SDK default ([sixteenBits]): 32 bits on the simulator, and the 816 px tilted one does not fit twice
    //! in the pool, so the map stays flat ([tiltRefused]).
    static function imageOptions(side as Number, sixteen as Boolean) as {
        :width as Number, :height as Number, :colorDepth as Number
    } {
        if (!sixteen) {
            return { :width => side, :height => side };
        }
        return { :width => side, :height => side, :colorDepth => 16 };
    }

    //! An image from the pool. Without a pool, the cache turns off and says why. With no room for the tilted one, the
    //! map stays flat ([tiltRefused]) and the next image is the 640 one.
    private function allocate() as BufferedBitmap? {
        if (!(Graphics has :createBufferedBitmap) || !(Graphics has :AffineTransform)) {
            giveUp("no API"); // lang: log
            return null;
        }
        var why = "pool refused";
        try {
            var ref = Graphics.createBufferedBitmap(imageOptions(side, sixteenBits));
            var image = ref.get() as BufferedBitmap?;
            if (image != null) {
                _backRef = ref;
                return image;
            }
        } catch (ex) {
            var message = ex.getErrorMessage();
            why = "pool full" + (message != null ? " (" + message + ")" : "");
        }
        if (side == SIDE_TILT) {
            tiltRefused = true;
            Diag.add("tilted map off: " + why);
            setTilt(1.0);
            return null;
        }
        giveUp(why);
        return null;
    }

    private function giveUp(why as String) as Void {
        failed = true;
        _building = false;
        Diag.add("street images off: " + why);
    }

    //! The color of each LOD now (brightness comes from the fine tuning, `Config`).
    private function currentColors() as Array<Number> {
        var colors = new [Protocol.CORRIDOR_LOD_COUNT] as Array<Number>;
        for (var lod = 0; lod < colors.size(); lod++) {
            colors[lod] = Config.corridorColor(lod);
        }
        return colors;
    }

    private function same(a as Array<Number>, b as Array<Number>) as Boolean {
        if (a.size() != b.size()) {
            return false;
        }
        for (var i = 0; i < a.size(); i++) {
            if (a[i] != b[i]) {
                return false;
            }
        }
        return true;
    }

    //! The relative difference between two scales.
    private function off(scale as Float, other as Float) as Float {
        if (other <= 0.0) {
            return 1.0;
        }
        var d = (scale - other) / other;
        return (d < 0.0 ? -d : d).toFloat();
    }

    //! Does the rectangle `[minX, maxX, minY, maxY]` in `boxes[at ..]` cross the image's square?
    private function inside(
        boxes as Array<Float>,
        at as Number,
        minX as Float,
        maxX as Float,
        minY as Float,
        maxY as Float
    ) as Boolean {
        return (boxes[at + 1] as Float) > minX && (boxes[at] as Float) < maxX
            && (boxes[at + 3] as Float) > minY && (boxes[at + 2] as Float) < maxY;
    }

    //! A way on the image, north up: `MapRenderer.drawWay` without the rotation and without the cut by
    //! point (the way's box was already tested and `Dc` clips what leaves the image), with a disc of `radius`
    //! at the ends and the bends. Returns the work.
    private function drawWay(
        dc as Dc,
        xs as Array<Float>,
        ys as Array<Float>,
        from as Number,
        to as Number,
        radius as Number,
        limit2 as Float
    ) as Number {
        if (to - from < 2) {
            return to - from;
        }
        var inv = _bInv;
        var ox = _bx;
        var oy = _by;
        var ax = xs[from] as Float;
        var ay = ys[from] as Float;
        var hh = half;
        var apx = hh + (ax - ox) * inv;
        var apy = hh - (ay - oy) * inv;
        var ux = 0.0;
        var uy = 0.0;
        var linked = false;
        var drawn = 0;
        var discs = 0;
        dc.fillCircle(apx, apy, radius);
        discs++;

        for (var i = from; i < to - 1; i++) {
            var bx = xs[i + 1] as Float;
            var by = ys[i + 1] as Float;
            var last = i + 2 >= to;
            if (!last) {
                var sx = bx - ax;
                var sy = by - ay;
                if (sx * sx + sy * sy < _bStepSq) {
                    continue;
                }
            }
            var bpx = hh + (bx - ox) * inv;
            var bpy = hh - (by - oy) * inv;
            var vx = bpx - apx;
            var vy = bpy - apy;
            if (linked) {
                var cross = ux * vy - uy * vx;
                var dot = ux * vx + uy * vy;
                if (dot < 0.0 || cross * cross > limit2 * (ux * ux + uy * uy) * (vx * vx + vy * vy)) {
                    dc.fillCircle(apx, apy, radius);
                    discs++;
                }
            }
            dc.drawLine(apx, apy, bpx, bpy);
            drawn++;
            if (last) {
                dc.fillCircle(bpx, bpy, radius);
                discs++;
            }
            ux = vx;
            uy = vy;
            linked = true;
            apx = bpx;
            apy = bpy;
            ax = bx;
            ay = by;
        }
        return (to - from) + drawn * 3 + discs * 2;
    }
}
