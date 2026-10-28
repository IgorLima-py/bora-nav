import Toybox.Lang;
import Toybox.Math;

//! Snaps the GPS fix to the route and measures progress (`03 §Map-matching`).
//!
//! The performance trick is the window: the bike moves at most a few tens of
//! meters between fixes, so the search starts near the last matched index
//! (`[last−10, last+50]`) instead of scanning 2,000 points at 1 Hz. Only when the
//! smallest distance exceeds [GLOBAL_SEARCH_M] — a sign the rider really left, or
//! that the fix jumped — is it worth scanning the whole route.
class MapMatcher {

    const WINDOW_BACK = 10;
    const WINDOW_AHEAD = 50;

    //! Above this the local window lost the rider; the global search is worth it.
    const GLOBAL_SEARCH_M = 100.0;

    //! Index of the point where the matched segment starts.
    var segmentIdx as Number = 0;

    //! Distance traveled along the route, in meters.
    var distAlong as Float = 0.0;

    //! Perpendicular distance to the route — the off-route metric (ADR-4).
    var crossTrack as Float = 0.0;

    //! Projection of the rider onto the route, in local meters.
    var snapX as Float = 0.0;
    var snapY as Float = 0.0;

    var matched as Boolean = false;

    //! How much the last [update] worked: one per segment measured and one per block
    //! box tested. It is the proxy for the per-fix cost, like `work` in
    //! `MapRenderer`: the off-route test requires it not to grow with the
    //! route length (`farFromALongRouteTheMatchCostStaysBounded`).
    var work as Number = 0;

    private var _route as RouteModel;

    function initialize(route as RouteModel) {
        _route = route;
    }

    //! Resets the match; use when the route changes.
    function reset() as Void {
        segmentIdx = 0;
        distAlong = 0.0;
        crossTrack = 0.0;
        matched = false;
    }

    //! Matches the position (local meters) to the route. `false` = route without geometry.
    function update(x as Float, y as Float) as Boolean {
        var count = _route.xs.size();
        work = 0;
        if (count < 2) {
            matched = false;
            return false;
        }

        var from = segmentIdx - WINDOW_BACK;
        var to = segmentIdx + WINDOW_AHEAD;
        var best = search(x, y, from, to, count);

        // The window lost the rider: scan everything once. Rare by construction.
        if ((best[2] as Float) > GLOBAL_SEARCH_M) {
            var global = searchAll(x, y, count);
            if ((global[2] as Float) < (best[2] as Float)) {
                best = global;
            }
        }

        segmentIdx = best[0] as Number;
        var t = best[1] as Float;
        crossTrack = best[2] as Float;

        var ax = _route.xs[segmentIdx] as Float;
        var ay = _route.ys[segmentIdx] as Float;
        var bx = _route.xs[segmentIdx + 1] as Float;
        var by = _route.ys[segmentIdx + 1] as Float;
        snapX = ax + (bx - ax) * t;
        snapY = ay + (by - ay) * t;

        var segStart = _route.cum[segmentIdx] as Float;
        var segEnd = _route.cum[segmentIdx + 1] as Float;
        distAlong = segStart + (segEnd - segStart) * t;
        matched = true;
        return true;
    }

    //! Meters left until the end of the route.
    function remainingM() as Float {
        var total = _route.lengthM();
        var left = total - distAlong;
        return left > 0 ? left : 0.0;
    }

    //! Index of the next maneuver point, or -1 if none are left.
    function nextTurnIndex() as Number {
        var turns = _route.turnPointIdx;
        for (var i = 0; i < turns.size(); i++) {
            var pointIdx = turns[i] as Number;
            // The maneuver still counts while the rider has not passed its point.
            if (pointIdx > segmentIdx && pointIdx < _route.cum.size()) {
                return i;
            }
        }
        return -1;
    }

    //! Meters to the next maneuver, or -1 when there is no next one.
    function distToNextTurnM() as Float {
        var index = nextTurnIndex();
        if (index < 0) {
            return -1.0;
        }
        var pointIdx = _route.turnPointIdx[index] as Number;
        var distance = (_route.cum[pointIdx] as Float) - distAlong;
        return distance > 0 ? distance : 0.0;
    }

    //! The global search **with the block index** (`RouteModel.blockBox`): the
    //! result is that of the full scan (`search(0, count - 1)`), except that a
    //! block of 16 points whose box is farther than the best found so far
    //! is not even opened. Off the route the watch does this on every fix
    //! (C11), so the cost has to follow what is nearby, not the
    //! route length. Without an index (route assembled by hand) it is the full scan.
    //!
    //! A tie goes to the lowest index, as in the scan, so both name
    //! the same segment.
    private function searchAll(x as Float, y as Float, count as Number) as Array {
        var boxes = _route.blockBox;
        var blocks = boxes.size() / 4;
        var span = RouteModel.BLOCK_POINTS;
        if (blocks == 0 || (blocks - 1) * span >= count - 1) {
            return search(x, y, 0, count - 1, count);
        }

        // 1st pass: the block with the box closest to the point. Opening it gives an
        // upper bound for the distance, and almost all the others fall outside.
        var nearest = 0;
        var nearestSq = 1.0e30;
        for (var b = 0; b < blocks; b++) {
            var lowerSq = boxDistanceSq(boxes, b, x, y);
            if (lowerSq < nearestSq) {
                nearestSq = lowerSq;
                nearest = b;
            }
        }
        work += blocks;

        var best = search(x, y, nearest * span, nearest * span + span - 1, count);
        var bestDist = best[2] as Float;

        // 2nd pass: only the blocks whose box is closer than the best.
        for (var b = 0; b < blocks; b++) {
            if (b == nearest) {
                continue;
            }
            var lowerSq = boxDistanceSq(boxes, b, x, y);
            if (lowerSq > bestDist * bestDist) {
                continue;
            }
            var found = search(x, y, b * span, b * span + span - 1, count);
            var d = found[2] as Float;
            if (d < bestDist || (d == bestDist && (found[0] as Number) < (best[0] as Number))) {
                best = found;
                bestDist = d;
            }
        }
        work += blocks;
        return best;
    }

    //! Squared distance from the point to box `b` of the index (0 if inside).
    private function boxDistanceSq(boxes as Array<Float>, b as Number, x as Float, y as Float) as Float {
        var minX = boxes[b * 4] as Float;
        var maxX = boxes[b * 4 + 1] as Float;
        var minY = boxes[b * 4 + 2] as Float;
        var maxY = boxes[b * 4 + 3] as Float;
        var dx = x < minX ? minX - x : (x > maxX ? x - maxX : 0.0);
        var dy = y < minY ? minY - y : (y > maxY ? y - maxY : 0.0);
        return dx * dx + dy * dy;
    }

    //! Best segment in the range: `[index, t, distance]`.
    //! `t` is the position within the segment, from 0 (start) to 1 (end).
    private function search(x as Float, y as Float, from as Number, to as Number, count as Number) as Array {
        var first = from < 0 ? 0 : from;
        var last = to > count - 2 ? count - 2 : to;
        var bestIdx = first;
        var bestT = 0.0;
        var bestDist = 1.0e30;

        work += last - first + 1;
        for (var i = first; i <= last; i++) {
            var ax = _route.xs[i] as Float;
            var ay = _route.ys[i] as Float;
            var dx = (_route.xs[i + 1] as Float) - ax;
            var dy = (_route.ys[i + 1] as Float) - ay;
            var lengthSq = dx * dx + dy * dy;

            var t = 0.0;
            if (lengthSq > 0.0) {
                t = ((x - ax) * dx + (y - ay) * dy) / lengthSq;
                if (t < 0.0) {
                    t = 0.0;
                } else if (t > 1.0) {
                    t = 1.0;
                }
            }

            var px = ax + dx * t;
            var py = ay + dy * t;
            var distance = Projection.distance(x, y, px, py);
            if (distance < bestDist) {
                bestDist = distance;
                bestIdx = i;
                bestT = t;
            }
        }

        return [bestIdx, bestT.toFloat(), bestDist.toFloat()] as Array;
    }
}
