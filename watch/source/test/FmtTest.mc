import Toybox.Lang;
import Toybox.Test;

//! **Numbers with a comma** (sheet 4, `Fmt`) and **the name as the sign writes it** (v1.1.5).

// prevents: "11.5 km" with a dot on the bottom card, in the route detail and on the debug screen,
// and the 0.95 that the 32-bit Float `format("%.1f")` rounded to "0.9".
(:test)
function kilometresUseACommaAndRoundHalfUp(logger as Logger) as Boolean {
    Test.assertEqualMessage(Fmt.km(11.46), "11,5", "one decimal, with a comma");
    Test.assertEqualMessage(Fmt.km(0.95), "1,0", "the half rounds up");
    Test.assertEqualMessage(Fmt.km(1.05), "1,1", "the half rounds up on Float too");
    Test.assertEqualMessage(Fmt.km(1.04), "1,0", "below the half rounds down");
    Test.assertEqualMessage(Fmt.km(9.96), "10,0", "carries into the tens");
    Test.assertEqualMessage(Fmt.km(0.0), "0,0", "zero");
    Test.assertEqualMessage(Fmt.km(123), "123,0", "whole number");
    Test.assertEqualMessage(NavEngine.formatDistance(11460.0), "11,5 km", "the maneuver distance");
    var parts = NavEngine.distanceParts(11460.0);
    Test.assertEqualMessage(parts[0], "11,5", "the number without the unit");
    Test.assertEqualMessage(parts[1], "km", "the unit");
    return true;
}

// prevents: the v1.1.5 sign (sheet 6) spending the glass width on "Avenida" or "Rua" spelled
// out, and the abbreviation biting what is neither avenue nor street ("Avenidas Unidas", "Ruas").
(:test)
function thePlateAbbreviatesAvenueAndStreet(logger as Logger) as Boolean {
    Test.assertEqualMessage(Fmt.plate("Avenida Paulista"), "Av. Paulista", "Avenida vira Av.");
    Test.assertEqualMessage(Fmt.plate("Rua Augusta"), "R. Augusta", "Rua vira R.");
    Test.assertEqualMessage(Fmt.plate("Avenidas Unidas"), "Avenidas Unidas", "whole word only");
    Test.assertEqualMessage(Fmt.plate("Ruas do Centro"), "Ruas do Centro", "whole word only");
    Test.assertEqualMessage(Fmt.plate("Rua da Avenida"), "R. da Avenida", "only at the start");
    Test.assertEqualMessage(Fmt.plate("Avenida da Rua"), "Av. da Rua", "only once");
    Test.assertEqualMessage(Fmt.plate("Avenida"), "Avenida", "no name after it, stays");
    Test.assertEqualMessage(Fmt.plate("Rua"), "Rua", "no name after it, stays");
    Test.assertEqualMessage(Fmt.plate(""), "", "vazio");
    return true;
}
