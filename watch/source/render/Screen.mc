import Toybox.Lang;
import Toybox.System;

//! The screen this build draws on, and the conversion from the reference screen to it.
//!
//! **Every layout number in the app is in px of the Venu 4 45 mm**, the 454 px glass the app was
//! drawn and ridden on: `DesignTokens`, the circle math around 227, the margins, the font sizes. The
//! other round AMOLED watches of the manifest (390, 416 and 466 px) get the same picture, scaled:
//! [px] turns a reference px into a px of this screen. At 454 it is the **identity**, integer for
//! integer, so the Venu 4 45 mm draws exactly what it drew before, and the tests and the preview
//! mirrors (`tools/preview_map.py`, the companion's settings preview), written for 454, still hold.
//!
//! The tests do not call [init]: they run at the reference size whatever the device.
module Screen {

    //! The reference glass: the Venu 4 45 mm.
    const REF = 454;

    //! Width (= height: the glass is round) of this screen, and its center.
    var size as Number = REF;
    var half as Number = REF / 2;

    //! Reads the screen once, when the app starts.
    function init() as Void {
        var w = System.getDeviceSettings().screenWidth;
        size = w;
        half = w / 2;
    }

    //! A reference px in px of this screen, rounded to the nearest; the identity at 454.
    function px(n as Number) as Number {
        if (n < 0) {
            return -px(-n);
        }
        return (n * size + REF / 2) / REF;
    }

    //! The same for a fractional value (map distances, radii), without rounding.
    function pxf(n as Numeric) as Float {
        return size == REF ? n.toFloat() : n.toFloat() * size / REF;
    }
}
