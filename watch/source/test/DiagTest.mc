import Toybox.Lang;
import Toybox.Test;

//! The watch log does not cut a line in half nor silently lose a line (C3b): the
//! send carries whole lines up to the cap and leaves the rest for the next one, and the
//! ring that overflows before being sent says how many lines it lost.
(:test)
function theLogSendsWholeLinesAndCountsWhatItLost(logger as Logger) as Boolean {
    Diag.clear();
    for (var i = 0; i < 30; i++) {
        Diag.add("line " + i.toString());
    }
    Test.assertEqualMessage(Diag.lost, 6, "30 lines in a ring of 24 with no send");

    var first = Diag.take(60);
    Test.assertMessage(first.length() <= 60, "respects the cap: " + first.length().toString());
    Test.assertMessage(first.find("log lost 6 lines\n") == 0, "opens with the loss: " + first);
    Test.assertMessage(first.substring(first.length() - 1, first.length()).find("\n") == null, "ends on a whole line");

    var rest = "";
    var guard = 0;
    while (guard < 20) {
        var part = Diag.take(60);
        if (part.equals("")) {
            break;
        }
        rest += part + "\n";
        guard++;
    }
    var all = first + "\n" + rest;
    Test.assertMessage(all.find("line 29") != null, "the last line arrived");
    Test.assertMessage(all.find("line 5\n") == null && all.find("line 6\n") != null, "the 6 oldest left, the others stayed");
    Test.assertEqualMessage(Diag.take(60), "", "nothing pending");

    Diag.clear();
    return true;
}
