import Toybox.Lang;

//! Numbers as the rider reads them (sheet 4, 2026-10-17): "11,5 km" in Portuguese and "11.5 km" in English
//! (the `DecimalSep` in `strings.xml`, C16.8a). Until now each
//! screen did its own `format("%.1f")`, which comes out with a dot and rounds the 32-bit Float
//! down at the midpoint (0.95 becomes "0.9").
module Fmt {

    //! `value` (non-negative) with one decimal place and the language's separator, rounding the midpoint up:
    //! 11.46 gives "11,5" and 0.95 gives "1,0". The ten-thousandth absorbs the Float's error.
    function km(value as Numeric) as String {
        var tenths = (value * 10.0 + 0.5 + 0.0001).toNumber();
        return (tenths / 10).toString() + Tr.s(Rez.Strings.DecimalSep) + (tenths % 10).toString();
    }

    //! The words the plate abbreviates at the start of the name, and how it writes each one.
    const PLATE_LONG = ["Avenida ", "Rua "] as Array<String>;
    const PLATE_SHORT = ["Av. ", "R. "] as Array<String>;

    //! The name as the street plate writes it (v1.1.5, sheet 6): "Avenida" becomes "Av." and "Rua" becomes
    //! "R." (Igor, 2026-10-18). The protocol still carries the full name, and Details shows
    //! it that way; only the plate abbreviates.
    function plate(name as String) as String {
        for (var i = 0; i < PLATE_LONG.size(); i++) {
            var long = PLATE_LONG[i];
            var n = long.length();
            if (name.length() > n && name.substring(0, n).equals(long)) {
                return PLATE_SHORT[i] + name.substring(n, name.length());
            }
        }
        return name;
    }
}
