import Toybox.Lang;

//! A CORRIDOR (0x04) block read **in slices**, not in a single callback.
//!
//! **Why it exists:** the linear `parseCorridor`, the 2026-08-01 fix, still
//! died by watchdog with the real SP corridor. LOD 0 has 1,378 points, and
//! read whole inside `onPhoneMessage` it went past the `venu445mm`'s 240,000
//! instructions (`DECISIONS.md` §2026-09-29 C2b). Linear is not enough: the cost per
//! callback has to have a ceiling, whatever the LOD's size. So the block is
//! kept here and each [step] reads at most a budget of points. The
//! `MessageAssembler` runs the first slice on arrival and the app's timer the
//! following ones, one per tick.
//!
//! The format is that of `05 §CORRIDOR`: `lod uint8`, then `pointCount uint8` and
//! delta-encoded points per way, **each way restarting at (lat0, lon0)**. A
//! way is never split between two slices (it has at most 255 points). The points
//! come out already projected to local meters, for the same reason as
//! `RouteModel.project()`.
class CorridorParseJob {

    var lod as Number;

    //! Message for the assembler's `lastError`, or `null`.
    var error as String? = null;

    private var _payload as ByteArray;
    private var _size as Number;
    private var _offset as Number = 1;
    private var _done as Boolean = false;

    private var _xs as Array<Float>;
    private var _ys as Array<Float>;
    private var _starts as Array<Number>;
    private var _boxes as Array<Float>;
    private var _cap as Number;
    private var _n as Number = 0;
    private var _wayCount as Number = 0;

    private var _lat0 as Number;
    private var _lon0 as Number;
    private var _xk as Float;
    private var _yk as Float;

    function initialize(payload as ByteArray, lat0 as Number, lon0 as Number, lonScale as Float) {
        _payload = payload;
        _size = payload.size();
        lod = Protocol.readU8(payload, 0);
        _lat0 = lat0;
        _lon0 = lon0;
        // `Projection.toLocalX/Y` inlined in the loop: they are two calls per
        // point, and a function call in Monkey C costs (`08 §Pitfalls`).
        _xk = (Projection.E5_TO_DEGREE * lonScale).toFloat();
        _yk = (Projection.E5_TO_DEGREE * Projection.METRES_PER_DEGREE).toFloat();

        // **Arrays with reserved size, not `add` point by point** (the death of
        // 2026-08-01): each point after the first takes at least 4 bytes,
        // so `size / 4 + 2` is a safe upper bound for the points, and
        // half of that for the ways (a way has at least 2 points).
        var cap = _size / 4 + 2;
        if (cap > Protocol.MAX_CORRIDOR_POINTS) {
            cap = Protocol.MAX_CORRIDOR_POINTS;
        }
        _cap = cap;
        _xs = new [cap] as Array<Float>;
        _ys = new [cap] as Array<Float>;
        _starts = new [cap / 2 + 2] as Array<Number>;
        // Each way's box comes out together with the points: redoing it at the end, in a
        // second pass over the whole LOD (`CorridorModel.boxesOf`), is what
        // blew the watchdog with slices of 1,100 points (DECISIONS
        // §2026-09-29 C2b).
        _boxes = new [(cap / 2 + 2) * 4] as Array<Float>;
    }

    function isDone() as Boolean {
        return _done;
    }

    //! Reads whole ways until it goes past `budget` points. `true` when the block
    //! ended (or stopped on an error, which stays in [error]).
    function step(budget as Number) as Boolean {
        var payload = _payload;
        var size = _size;
        var offset = _offset;
        var xs = _xs;
        var ys = _ys;
        var starts = _starts;
        var boxes = _boxes;
        var n = _n;
        var wayCount = _wayCount;
        var lat0 = _lat0;
        var lon0 = _lon0;
        var xk = _xk;
        var yk = _yk;
        var limit = n + budget;

        while (offset < size && n < limit) {
            var pointCount = Protocol.readU8(payload, offset);
            offset += 1;
            if (pointCount < 2) {
                // A 1-point way draws nothing and the rest of the block can no longer be
                // trusted from here on: stopping is better than guessing.
                _done = true;
                break;
            }
            if (n + pointCount > _cap || wayCount + 2 >= starts.size()) {
                error = "CORRIDOR capped at the point ceiling";
                _done = true;
                break;
            }
            if (!Protocol.hasBytes(payload, offset, 8)) {
                _done = true;
                break;
            }

            starts[wayCount] = n;
            wayCount++;
            var lat = lat0;
            var lon = lon0;
            var complete = true;
            var minX = 0.0;
            var maxX = 0.0;
            var minY = 0.0;
            var maxY = 0.0;

            for (var i = 0; i < pointCount; i++) {
                var dLat;
                var dLon;
                if (i == 0) {
                    dLat = Protocol.readS32(payload, offset);
                    dLon = Protocol.readS32(payload, offset + 4);
                    offset += 8;
                } else {
                    if (!Protocol.hasBytes(payload, offset, 4)) {
                        complete = false;
                        break;
                    }
                    dLat = Protocol.readS16(payload, offset);
                    dLon = Protocol.readS16(payload, offset + 2);
                    offset += 4;
                    if (dLat == Protocol.DELTA_ESCAPE && dLon == Protocol.DELTA_ESCAPE) {
                        if (!Protocol.hasBytes(payload, offset, 8)) {
                            complete = false;
                            break;
                        }
                        dLat = Protocol.readS32(payload, offset);
                        dLon = Protocol.readS32(payload, offset + 4);
                        offset += 8;
                    }
                }
                lat += dLat;
                lon += dLon;
                var x = ((lon - lon0) * xk).toFloat();
                var y = ((lat - lat0) * yk).toFloat();
                xs[n] = x;
                ys[n] = y;
                n++;
                if (i == 0) {
                    minX = x;
                    maxX = x;
                    minY = y;
                    maxY = y;
                } else {
                    if (x < minX) { minX = x; } else if (x > maxX) { maxX = x; }
                    if (y < minY) { minY = y; } else if (y > maxY) { maxY = y; }
                }
            }

            if (!complete) {
                // Way truncated in the middle: discard its points instead of
                // drawing a street that ends nowhere. With a cursor, it is
                // just a step back.
                wayCount--;
                n = starts[wayCount] as Number;
                error = "way truncated at LOD " + lod.toString();
                _done = true;
                break;
            }
            var b = (wayCount - 1) * 4;
            boxes[b] = minX;
            boxes[b + 1] = maxX;
            boxes[b + 2] = minY;
            boxes[b + 3] = maxY;
        }

        if (offset >= size) {
            _done = true;
        }
        _offset = offset;
        _n = n;
        _wayCount = wayCount;
        return _done;
    }

    //! Hands the LOD to the model. Returns how many ways went in (0 = nothing).
    function finish(corridor as CorridorModel) as Number {
        if (_wayCount == 0) {
            return 0;
        }
        // Sentinel: the drawing loop reads `starts[w + 1]` with no special case.
        _starts[_wayCount] = _n;
        corridor.setLodWithBoxes(
            lod,
            _xs.slice(0, _n),
            _ys.slice(0, _n),
            _starts.slice(0, _wayCount + 1),
            _boxes.slice(0, _wayCount * 4)
        );
        Diag.add("corridor lod " + lod.toString() + " " + _wayCount.toString()
            + " ways " + _n.toString() + " pts");
        return _wayCount;
    }
}
