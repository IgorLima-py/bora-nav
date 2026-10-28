import Toybox.Lang;
import Toybox.Math;

//! Local equirectangular projection (ADR-6 of `02-ARCHITECTURE.md`).
//!
//! Coordinates arrive from the phone in protocol units (degree × 1e-5) and
//! become meters on a local plane anchored at the first point of the route:
//!
//! ```
//! x = (lon − lon0) · k · cos(lat0)     y = (lat − lat0) · k
//! ```
//!
//! The error of an equirectangular projection at the scale of an urban corridor (tens of km)
//! is negligible next to the width of a street, and the cost is one multiplication per
//! vertex — no Mercator and no trigonometry per point. The cosine of `lat0` is
//! computed **once** per route, not per point.
module Projection {

    //! Meters per degree of latitude (2πR/360, R = 6,371,000 m).
    const METRES_PER_DEGREE = 111194.9;

    const E5_TO_DEGREE = 0.00001;

    //! Longitude shrink factor at the route latitude. Store per route.
    function lonScale(lat0E5 as Number) as Float {
        var latRad = lat0E5 * E5_TO_DEGREE * (Math.PI / 180.0);
        return (METRES_PER_DEGREE * Math.cos(latRad)).toFloat();
    }

    //! East positive, in meters from `lon0E5`.
    function toLocalX(lonE5 as Number, lon0E5 as Number, scale as Float) as Float {
        return ((lonE5 - lon0E5) * E5_TO_DEGREE * scale).toFloat();
    }

    //! North positive, in meters from `lat0E5`.
    function toLocalY(latE5 as Number, lat0E5 as Number) as Float {
        return ((latE5 - lat0E5) * E5_TO_DEGREE * METRES_PER_DEGREE).toFloat();
    }

    //! Decimal degrees → protocol units, so the GPS fix enters the same
    //! plane as the route. Rounds like the packer (`08 §Pitfalls`).
    function degreesToE5(degrees as Double) as Number {
        var scaled = degrees * 100000.0;
        return (scaled >= 0 ? scaled + 0.5 : scaled - 0.5).toNumber();
    }

    function distance(x1 as Float, y1 as Float, x2 as Float, y2 as Float) as Float {
        var dx = x2 - x1;
        var dy = y2 - y1;
        return Math.sqrt(dx * dx + dy * dy).toFloat();
    }
}
