import Toybox.Lang;

//! The streets around the route, by level of detail (`05 §CORRIDOR`, `04 §3`).
//!
//! **The geometry lives in parallel arrays of primitives**, never in objects per
//! point or per way (`08-CODEX-GUIDE.md §Pitfalls 2`). An urban corridor
//! reaches thousands of points; one object per way would already cost more memory than the
//! whole route, and one per point would not fit.
//!
//! The layout is this: each LOD has `xs`/`ys` with **all** the points of **all**
//! the ways concatenated, plus a `wayStart` with the index where each way starts.
//! Way `w` of LOD `l` goes from `wayStart[l][w]` (inclusive) to
//! `wayStart[l][w + 1]` (exclusive), with the last one bounded by the size of
//! `xs[l]` — hence `wayStart` keeping a sentinel at the end, so the drawing loop
//! needs no special case for the last way.
class CorridorModel {

    //! `xs[lod]` / `ys[lod]`: local meters, in the same plane as the route.
    var xs as Array<Array<Float> > = emptyFloatLods();
    var ys as Array<Array<Float> > = emptyFloatLods();

    //! `wayStart[lod]`: start indices of each way, with a sentinel at the end.
    var wayStart as Array<Array<Number> > = emptyNumberLods();

    //! Bounding rectangle of each way, flattened into four floats per way:
    //! `[minX, maxX, minY, maxY]` of way `w` in `wayBox[lod][4w .. 4w+3]`.
    //!
    //! **It is what makes the corridor drawable.** Without it, culling tests vertex
    //! by vertex: an urban mesh of ~1,200 segments costs thousands of
    //! comparisons per frame to find out that almost everything is off the screen.
    //! With the rectangle, a whole way that does not touch the view dies in **four
    //! comparisons** — and, within a view radius of ~460 m over a 15 km route,
    //! that is the case for more than 90% of them. It costs 16 bytes per way, paid once
    //! on reception.
    var wayBox as Array<Array<Float> > = emptyFloatLods();

    //! How many consecutive ways fit in an index block. See [blockBox].
    static const WAYS_PER_BLOCK = 32;

    //! Bounding rectangle of each **block** of [WAYS_PER_BLOCK] ways, in the same
    //! flattened format as [wayBox].
    //!
    //! **It is the index's second floor, and without it the corridor sabotages itself.** With the
    //! per-way rectangle, finding what shows up costs one test per way — and a
    //! São Paulo corridor has ~2,300. Measured in `tools/preview_map.py` with the
    //! 22 km test route to Copan: the sweep alone spent **1,561** of the budget's 1,800
    //! work points, leaving 240 for drawing. Sending more
    //! streets to the watch left fewer streets on the screen.
    //!
    //! What makes this cheap is the order in which the ways arrive: the companion
    //! sends them **sorted by distance along the route** (`04 §3.6`), so 32
    //! consecutive ways are neighbors on the map and the block's rectangle is tight.
    //! A whole block dies in four comparisons, and only the 2–3 blocks that
    //! touch the screen are opened way by way: ~73 block tests plus ~96 way
    //! tests, against 2,300.
    var blockBox as Array<Array<Float> > = emptyFloatLods();

    //! LODs that have already arrived. The META announces how many will come; until it matches, the corridor
    //! is incomplete and the map draws what it already has.
    var lodsReceived as Number = 0;

    //! Goes up on every geometry change. The renderer keeps a list of visible
    //! ways between frames and needs to know when it went stale — comparing
    //! a counter is the cheap way to ask "did it change?".
    var revision as Number = 0;

    function initialize() {
    }

    static function emptyFloatLods() as Array<Array<Float> > {
        return [
            [] as Array<Float>, [] as Array<Float>, [] as Array<Float>, [] as Array<Float>
        ] as Array<Array<Float> >;
    }

    static function emptyNumberLods() as Array<Array<Number> > {
        return [
            [] as Array<Number>, [] as Array<Number>, [] as Array<Number>, [] as Array<Number>
        ] as Array<Array<Number> >;
    }

    //! Drops the whole corridor. Called when the route changes: the old corridor
    //! is in the old route's local plane and drawing it on the new one puts
    //! random streets on the screen (`05 §Robustness rules 2`).
    function clear() as Void {
        xs = emptyFloatLods();
        ys = emptyFloatLods();
        wayStart = emptyNumberLods();
        wayBox = emptyFloatLods();
        blockBox = emptyFloatLods();
        lodsReceived = 0;
        revision++;
    }

    function isEmpty() as Boolean {
        return pointCount() == 0;
    }

    function pointCount() as Number {
        var total = 0;
        for (var lod = 0; lod < Protocol.CORRIDOR_LOD_COUNT; lod++) {
            total += (xs[lod] as Array<Float>).size();
        }
        return total;
    }

    function wayCount(lod as Number) as Number {
        var starts = wayStart[lod] as Array<Number>;
        return starts.size() > 0 ? starts.size() - 1 : 0;
    }

    //! Stores an already projected LOD. Replaces whatever is at that level: a resent
    //! LOD is a correction, not a continuation.
    function setLod(
        lod as Number,
        pointXs as Array<Float>,
        pointYs as Array<Float>,
        starts as Array<Number>
    ) as Void {
        if (lod < 0 || lod >= Protocol.CORRIDOR_LOD_COUNT) {
            return;
        }
        setLodWithBoxes(lod, pointXs, pointYs, starts, boxesOf(pointXs, pointYs, starts));
    }

    //! Same as [setLod], with the ways' boxes already computed by whoever read
    //! the points (`CorridorParseJob`): saves a second pass over the whole
    //! LOD in the same callback, which is what blew the watchdog with the
    //! SP corridor (DECISIONS §2026-09-29 C2b).
    function setLodWithBoxes(
        lod as Number,
        pointXs as Array<Float>,
        pointYs as Array<Float>,
        starts as Array<Number>,
        boxes as Array<Float>
    ) as Void {
        if (lod < 0 || lod >= Protocol.CORRIDOR_LOD_COUNT) {
            return;
        }
        var isNew = (xs[lod] as Array<Float>).size() == 0;
        xs[lod] = pointXs;
        ys[lod] = pointYs;
        wayStart[lod] = starts;
        wayBox[lod] = boxes;
        blockBox[lod] = blocksOf(boxes);
        revision++;
        if (isNew && pointXs.size() > 0) {
            lodsReceived++;
        }
    }

    //! One bounding rectangle per way, in way order. Runs once per LOD,
    //! on reception — the same place where the projection is already paid for.
    static function boxesOf(
        pointXs as Array<Float>,
        pointYs as Array<Float>,
        starts as Array<Number>
    ) as Array<Float> {
        var ways = starts.size() > 0 ? starts.size() - 1 : 0;
        var boxes = new [ways * 4] as Array<Float>;

        for (var w = 0; w < ways; w++) {
            var from = starts[w] as Number;
            var to = starts[w + 1] as Number;
            var minX = pointXs[from] as Float;
            var maxX = minX;
            var minY = pointYs[from] as Float;
            var maxY = minY;

            for (var i = from + 1; i < to; i++) {
                var x = pointXs[i] as Float;
                var y = pointYs[i] as Float;
                if (x < minX) { minX = x; } else if (x > maxX) { maxX = x; }
                if (y < minY) { minY = y; } else if (y > maxY) { maxY = y; }
            }

            boxes[w * 4] = minX;
            boxes[w * 4 + 1] = maxX;
            boxes[w * 4 + 2] = minY;
            boxes[w * 4 + 3] = maxY;
        }
        return boxes;
    }

    //! One rectangle per block of [WAYS_PER_BLOCK] ways, from [wayBox].
    //! Runs once per LOD, on reception — see [blockBox]'s documentation.
    static function blocksOf(boxes as Array<Float>) as Array<Float> {
        var ways = boxes.size() / 4;
        if (ways == 0) {
            return [] as Array<Float>;
        }
        var blocks = (ways + WAYS_PER_BLOCK - 1) / WAYS_PER_BLOCK;
        var out = new [blocks * 4] as Array<Float>;

        for (var b = 0; b < blocks; b++) {
            var from = b * WAYS_PER_BLOCK;
            var to = from + WAYS_PER_BLOCK;
            if (to > ways) {
                to = ways;
            }
            var minX = boxes[from * 4] as Float;
            var maxX = boxes[from * 4 + 1] as Float;
            var minY = boxes[from * 4 + 2] as Float;
            var maxY = boxes[from * 4 + 3] as Float;

            for (var w = from + 1; w < to; w++) {
                var base = w * 4;
                if ((boxes[base] as Float) < minX) { minX = boxes[base] as Float; }
                if ((boxes[base + 1] as Float) > maxX) { maxX = boxes[base + 1] as Float; }
                if ((boxes[base + 2] as Float) < minY) { minY = boxes[base + 2] as Float; }
                if ((boxes[base + 3] as Float) > maxY) { maxY = boxes[base + 3] as Float; }
            }

            out[b * 4] = minX;
            out[b * 4 + 1] = maxX;
            out[b * 4 + 2] = minY;
            out[b * 4 + 3] = maxY;
        }
        return out;
    }
}
