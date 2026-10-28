import Toybox.Lang;

//! The active route as received from the companion.
//!
//! Geometry lives in parallel arrays of primitives, never in objects
//! (docs/08-CODEX-GUIDE.md §Pitfalls 2). Coordinates stay in protocol units
//! (1e-5 degrees) in F1; the projection to local metres lands in F2 with the
//! renderer (ADR-6).
class RouteModel {

    var routeId as Number = 0;
    var lat0 as Number = 0;
    var lon0 as Number = 0;
    var distanceM as Number = 0;
    var durationS as Number = 0;
    var destName as String = "";
    var polyPointCount as Number = 0;
    var turnCount as Number = 0;
    var corridorLodCount as Number = 0;
    var flags as Number = 0;

    var lats as Array<Number> = [] as Array<Number>;
    var lons as Array<Number> = [] as Array<Number>;

    //! Same geometry in local meters (ADR-6), precomputed on reception: the
    //! render and the map-matching run at 1 Hz and cannot project per frame.
    var xs as Array<Float> = [] as Array<Float>;
    var ys as Array<Float> = [] as Array<Float>;

    //! Cumulative distance up to each point, in meters. `cum[i]` = from the start to
    //! point `i`; the last element is the polyline's total length.
    var cum as Array<Float> = [] as Array<Float>;

    //! How many consecutive points fit in an index block. See [blockBox].
    static const BLOCK_POINTS = 16;

    //! Coarse polyline index: one bounding rectangle for every
    //! [BLOCK_POINTS] points, flattened into `[minX, maxX, minY, maxY]` per block.
    //!
    //! **It exists because finding out what shows on the screen cannot cost the
    //! route's length.** The renderer tested the visibility of the ~800 points on
    //! every recalculation, and it was inside that loop that the Venu 4's watchdog killed the
    //! app (`CIQ_LOG.YML` of 2026-08-01: `refreshRouteRanges` → `visible`). Since
    //! neighboring points of a polyline are neighbors on the map, a block's rectangle
    //! is tight and kills 16 points in a single test: an 800-point route
    //! goes from 800 tests to 50 block tests plus the points of the 2–4 blocks
    //! that actually touch the screen.
    //!
    //! Computed once per route, together with the projection: on reception by
    //! `PolyParseJob`, and in [project] by the tests.
    var blockBox as Array<Float> = [] as Array<Float>;

    //! cos(lat0) already applied — also used to convert the GPS fix into the same plane.
    var lonScale as Float = 1.0;

    var turnPointIdx as Array<Number> = [] as Array<Number>;
    var turnType as Array<Number> = [] as Array<Number>;
    var turnExit as Array<Number> = [] as Array<Number>;
    var turnName as Array<String> = [] as Array<String>;

    //! The route's speed cameras (05 §RADARS, C16.6), in `radarDist` order: meters along the POLY
    //! (the phone's computation), the position in local meters, the limit in km/h (0 = unknown) and the
    //! flags. They arrive after the corridor and vanish with the route.
    var radarDist as Array<Number> = [] as Array<Number>;
    var radarX as Array<Float> = [] as Array<Float>;
    var radarY as Array<Float> = [] as Array<Float>;
    var radarLimit as Array<Number> = [] as Array<Number>;
    var radarFlags as Array<Number> = [] as Array<Number>;

    var hasMeta as Boolean = false;
    var hasPoly as Boolean = false;
    var hasTurns as Boolean = false;

    //! Changes every time this instance's geometry is replaced ([beginRoute],
    //! [adopt]). It is the key of the drawer's cache: two routes with the same
    //! number of points are different routes, and the `xs.size()` that the
    //! `MapRenderer` used until C11 did not tell them apart.
    var revision as Number = 0;

    function initialize() {
    }

    //! Starts a new route; the old geometry is dropped only here, so a partial
    //! transfer never leaves the app without a route (05 §Robustness rules 2).
    function beginRoute(newRouteId as Number) as Void {
        revision++;
        routeId = newRouteId;
        lats = [] as Array<Number>;
        lons = [] as Array<Number>;
        xs = [] as Array<Float>;
        ys = [] as Array<Float>;
        cum = [] as Array<Float>;
        blockBox = [] as Array<Float>;
        turnPointIdx = [] as Array<Number>;
        turnType = [] as Array<Number>;
        turnExit = [] as Array<Number>;
        turnName = [] as Array<String>;
        clearRadars();
        hasMeta = false;
        hasPoly = false;
        hasTurns = false;
    }

    function clearRadars() as Void {
        radarDist = [] as Array<Number>;
        radarX = [] as Array<Float>;
        radarY = [] as Array<Float>;
        radarLimit = [] as Array<Number>;
        radarFlags = [] as Array<Number>;
    }

    //! Drops the whole route, counters included. Unlike [beginRoute],
    //! which preserves `polyPointCount`/`turnCount` because they have just arrived
    //! in the META and are the template for what is still to come — here the intent is the opposite:
    //! `isComplete()` has to go back to false and the home screen has to say
    //! "Waiting for route…" again.
    function clear() as Void {
        beginRoute(0);
        distanceM = 0;
        durationS = 0;
        destName = "";
        polyPointCount = 0;
        turnCount = 0;
        corridorLodCount = 0;
        flags = 0;
        lat0 = 0;
        lon0 = 0;
        lonScale = 1.0;
    }

    //! Becomes route `other`, whole and all at once (C11, `05 §Robustness\1 rules 2`): the recalculation is assembled in a staging instance by the
    //! `MessageAssembler` and only enters here when complete, so the rider
    //! never ends up without a route in the middle of the transfer.
    //!
    //! **Copies into this instance instead of swapping instances** because the
    //! `MapMatcher`, the `NavView`, the `NavDelegate` and the `DetailsView` keep the
    //! reference they received in the constructor. The arrays are not copied, they just
    //! change owner: the staging instance is dropped right after.
    function adopt(other as RouteModel) as Void {
        routeId = other.routeId;
        lat0 = other.lat0;
        lon0 = other.lon0;
        distanceM = other.distanceM;
        durationS = other.durationS;
        destName = other.destName;
        polyPointCount = other.polyPointCount;
        turnCount = other.turnCount;
        corridorLodCount = other.corridorLodCount;
        flags = other.flags;
        lats = other.lats;
        lons = other.lons;
        xs = other.xs;
        ys = other.ys;
        cum = other.cum;
        blockBox = other.blockBox;
        lonScale = other.lonScale;
        turnPointIdx = other.turnPointIdx;
        turnType = other.turnType;
        turnExit = other.turnExit;
        turnName = other.turnName;
        radarDist = other.radarDist;
        radarX = other.radarX;
        radarY = other.radarY;
        radarLimit = other.radarLimit;
        radarFlags = other.radarFlags;
        hasMeta = other.hasMeta;
        hasPoly = other.hasPoly;
        hasTurns = other.hasTurns;
        revision++;
    }

    //! Projects the polyline to local meters and precomputes the cumulative distances.
    //!
    //! **No longer runs on reception** since C6a: in a single pass, over a 16 km
    //! route, it blew the watch's watchdog (`DECISIONS.md` §C6a: the
    //! pre-flight), and whoever projects now is `PolyParseJob`, in slices. It stays as a
    //! template: `aLongPolyIsReadInSlicesAndEndsTheSame` demands that the job give
    //! exactly what it gives.
    function project() as Void {
        var count = lats.size();
        lonScale = Projection.lonScale(lat0);

        var newXs = new [count] as Array<Float>;
        var newYs = new [count] as Array<Float>;
        var newCum = new [count] as Array<Float>;
        var total = 0.0;

        for (var i = 0; i < count; i++) {
            var x = Projection.toLocalX(lons[i] as Number, lon0, lonScale);
            var y = Projection.toLocalY(lats[i] as Number, lat0);
            newXs[i] = x;
            newYs[i] = y;
            if (i > 0) {
                total += Projection.distance(newXs[i - 1] as Float, newYs[i - 1] as Float, x, y);
            }
            newCum[i] = total.toFloat();
        }

        xs = newXs;
        ys = newYs;
        cum = newCum;
        blockBox = boxesOf(newXs, newYs);
    }

    //! One bounding rectangle for every [BLOCK_POINTS] points.
    //!
    //! The last block usually comes out incomplete and that is not a special case: it
    //! wraps whatever points there are. Blocks **overlap by one point** on
    //! purpose — block `b` goes up to the first point of block `b + 1` —, otherwise
    //! the segment crossing the boundary between the two would belong to no rectangle
    //! and would vanish from the screen on crossing the edge.
    static function boxesOf(pointXs as Array<Float>, pointYs as Array<Float>) as Array<Float> {
        var count = pointXs.size();
        if (count == 0) {
            return [] as Array<Float>;
        }
        var blocks = (count + BLOCK_POINTS - 1) / BLOCK_POINTS;
        var boxes = new [blocks * 4] as Array<Float>;

        for (var b = 0; b < blocks; b++) {
            var from = b * BLOCK_POINTS;
            var to = from + BLOCK_POINTS;
            if (to > count - 1) {
                to = count - 1;
            }
            var minX = pointXs[from] as Float;
            var maxX = minX;
            var minY = pointYs[from] as Float;
            var maxY = minY;

            for (var i = from + 1; i <= to; i++) {
                var x = pointXs[i] as Float;
                var y = pointYs[i] as Float;
                if (x < minX) { minX = x; } else if (x > maxX) { maxX = x; }
                if (y < minY) { minY = y; } else if (y > maxY) { maxY = y; }
            }

            boxes[b * 4] = minX;
            boxes[b * 4 + 1] = maxX;
            boxes[b * 4 + 2] = minY;
            boxes[b * 4 + 3] = maxY;
        }
        return boxes;
    }

    //! Length of the polyline in meters (0 if not yet projected).
    function lengthM() as Float {
        return cum.size() > 0 ? cum[cum.size() - 1] as Float : 0.0;
    }

    //! A route is usable once META, POLY and TURNS agree on the counts.
    function isComplete() as Boolean {
        return hasMeta && hasPoly && hasTurns
            && lats.size() == polyPointCount
            && turnPointIdx.size() == turnCount;
    }
}
