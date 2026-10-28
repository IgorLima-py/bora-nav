import Toybox.Lang;
import Toybox.Math;

//! A ROUTE_POLY (0x02) block read **in slices**, not in a single callback.
//!
//! **Why it exists:** in the 2026-10-02 pre-flight the watch died by watchdog when
//! receiving a 16 km route (3,136 B of POLY): `parsePoly` decoded the
//! deltas, `RouteModel.project` projected and `boxesOf` built the index, all
//! inside `onPhoneMessage` (`DECISIONS.md` §C6a: the pre-flight). In the simulator, with the
//! 240,000-instruction watchdog in force, SP (722 points) passes and 790 points
//! die in `boxesOf`; 4,000 (the protocol's ceiling) die still in decoding.
//! It is the same disease as the corridor in C2b, and the same remedy: the cost per callback
//! has to have a ceiling, whatever the route's size. Each [step] reads at most a
//! budget of points, and the `MessageAssembler` runs the first slice on arrival and
//! the app's timer the following ones.
//!
//! **One pass does what used to be three.** Each point comes out decoded, projected,
//! with the accumulated distance and inside its block's box, with the same math as
//! `Projection.toLocalX/Y`, `Projection.distance` and `RouteModel.boxesOf` — the
//! test `aLongPolyIsReadInSlicesAndEndsTheSame` demands the same result, number
//! by number. The `Protocol` and `Projection` functions are inlined in the loop:
//! a function call in Monkey C costs (`08 §Pitfalls`), and there were seven per point.
class PolyParseJob {

    var routeId as Number;

    //! Message for the assembler's `lastError`, or `null`.
    var error as String? = null;

    private var _payload as ByteArray;
    private var _size as Number;
    private var _offset as Number = 0;
    private var _done as Boolean = false;

    private var _lats as Array<Number>;
    private var _lons as Array<Number>;
    private var _xs as Array<Float>;
    private var _ys as Array<Float>;
    private var _cum as Array<Float>;
    private var _boxes as Array<Float>;
    private var _cap as Number;
    private var _n as Number = 0;

    private var _lat0 as Number;
    private var _lon0 as Number;
    private var _lonScale as Float;
    private var _lat as Number;
    private var _lon as Number;
    private var _total as Float = 0.0;

    function initialize(payload as ByteArray, route as RouteModel) {
        _payload = payload;
        _size = payload.size();
        routeId = route.routeId;
        _lat0 = route.lat0;
        _lon0 = route.lon0;
        _lonScale = route.lonScale;
        _lat = _lat0;
        _lon = _lon0;

        // **Arrays with reserved size, not `add` point by point** (the death of
        // 2026-08-01): each point after the first takes at least 4 bytes,
        // so `size / 4 + 2` is a safe upper bound.
        var cap = _size / 4 + 2;
        if (cap > Protocol.MAX_POLY_POINTS) {
            cap = Protocol.MAX_POLY_POINTS;
        }
        _cap = cap;
        _lats = new [cap] as Array<Number>;
        _lons = new [cap] as Array<Number>;
        _xs = new [cap] as Array<Float>;
        _ys = new [cap] as Array<Float>;
        _cum = new [cap] as Array<Float>;
        _boxes = new [((cap + RouteModel.BLOCK_POINTS - 1) / RouteModel.BLOCK_POINTS) * 4] as Array<Float>;
    }

    function isDone() as Boolean {
        return _done;
    }

    //! Points read so far.
    function count() as Number {
        return _n;
    }

    //! Reads up to `budget` points. `true` when the block ended (or hit the ceiling,
    //! which stays in [error]).
    function step(budget as Number) as Boolean {
        var payload = _payload;
        var size = _size;
        var offset = _offset;
        var lats = _lats;
        var lons = _lons;
        var xs = _xs;
        var ys = _ys;
        var cum = _cum;
        var boxes = _boxes;
        var cap = _cap;
        var n = _n;
        var lat = _lat;
        var lon = _lon;
        var lat0 = _lat0;
        var lon0 = _lon0;
        var scale = _lonScale;
        var e5 = Projection.E5_TO_DEGREE;
        var mpd = Projection.METRES_PER_DEGREE;
        var total = _total;
        var blockPoints = RouteModel.BLOCK_POINTS;
        var limit = n + budget;

        while (offset < size && n < cap && n < limit) {
            var dLat;
            var dLon;
            if (n == 0) {
                if (offset + 8 > size) {
                    break;
                }
                dLat = readS32(payload, offset);
                dLon = readS32(payload, offset + 4);
                offset += 8;
            } else {
                if (offset + 4 > size) {
                    break;
                }
                dLat = ((payload[offset] as Number) << 8) | (payload[offset + 1] as Number);
                if (dLat >= 0x8000) {
                    dLat -= 0x10000;
                }
                dLon = ((payload[offset + 2] as Number) << 8) | (payload[offset + 3] as Number);
                if (dLon >= 0x8000) {
                    dLon -= 0x10000;
                }
                offset += 4;
                if (dLat == Protocol.DELTA_ESCAPE && dLon == Protocol.DELTA_ESCAPE) {
                    if (offset + 8 > size) {
                        break;
                    }
                    dLat = readS32(payload, offset);
                    dLon = readS32(payload, offset + 4);
                    offset += 8;
                }
            }
            lat += dLat;
            lon += dLon;
            lats[n] = lat;
            lons[n] = lon;

            // `Projection.toLocalX/Y`, the same expression in the same order.
            var x = (lon - lon0) * e5 * scale;
            var y = (lat - lat0) * e5 * mpd;
            xs[n] = x;
            ys[n] = y;
            if (n > 0) {
                // `Projection.distance`.
                var dx = x - (xs[n - 1] as Float);
                var dy = y - (ys[n - 1] as Float);
                total += Math.sqrt(dx * dx + dy * dy).toFloat();
            }
            cum[n] = total;

            // `RouteModel.boxesOf`: the point opens or widens its block's box,
            // and a block's first point also closes the previous one's — the
            // blocks overlap by one point on purpose.
            var b = (n / blockPoints) * 4;
            if (n % blockPoints == 0) {
                boxes[b] = x;
                boxes[b + 1] = x;
                boxes[b + 2] = y;
                boxes[b + 3] = y;
                if (n > 0) {
                    widen(boxes, b - 4, x, y);
                }
            } else {
                if (x < (boxes[b] as Float)) { boxes[b] = x; } else if (x > (boxes[b + 1] as Float)) { boxes[b + 1] = x; }
                if (y < (boxes[b + 2] as Float)) { boxes[b + 2] = y; } else if (y > (boxes[b + 3] as Float)) { boxes[b + 3] = y; }
            }
            n++;
        }

        if (offset >= size || n >= cap) {
            if (offset < size) {
                error = "POLY capped at the point ceiling";
            }
            _done = true;
        } else if (n < limit) {
            // Stopped before the budget without reaching the end: the rest of the block
            // has no bytes for a whole point. What was already read stays.
            error = "POLY truncated at point " + n.toString();
            _done = true;
        }
        _offset = offset;
        _n = n;
        _lat = lat;
        _lon = lon;
        _total = total;
        return _done;
    }

    //! Hands the route to the model. Returns how many points went in.
    function finish(route as RouteModel) as Number {
        var n = _n;
        var blocks = (n + RouteModel.BLOCK_POINTS - 1) / RouteModel.BLOCK_POINTS;
        route.lats = _lats.slice(0, n);
        route.lons = _lons.slice(0, n);
        route.xs = _xs.slice(0, n);
        route.ys = _ys.slice(0, n);
        route.cum = _cum.slice(0, n);
        route.blockBox = _boxes.slice(0, blocks * 4);
        route.hasPoly = true;
        route.revision++;
        return n;
    }

    private function widen(boxes as Array<Float>, b as Number, x as Float, y as Float) as Void {
        if (x < (boxes[b] as Float)) { boxes[b] = x; } else if (x > (boxes[b + 1] as Float)) { boxes[b + 1] = x; }
        if (y < (boxes[b + 2] as Float)) { boxes[b + 2] = y; } else if (y > (boxes[b + 3] as Float)) { boxes[b + 3] = y; }
    }

    private function readS32(data as ByteArray, offset as Number) as Number {
        return ((data[offset] as Number) << 24)
            | ((data[offset + 1] as Number) << 16)
            | ((data[offset + 2] as Number) << 8)
            | (data[offset + 3] as Number);
    }
}
