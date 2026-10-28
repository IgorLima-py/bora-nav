import Toybox.Lang;
import Toybox.Test;

//! The track recorder (C3b): records one fix every 5 s, delivers in whole
//! lines and counts what it lost. What the rider cannot have is a ride that
//! looks complete and is not, so the two mandatory tests of the `verificar:`
//! are the ride that loses nothing and the full buffer that says what it lost.

(:test)
module TrackAssert {

    //! How many `trk <t> ...` lines (not the loss one) the text has, and whether the
    //! seconds come in increasing order.
    function points(text as String) as Array<Number> {
        var times = [] as Array<Number>;
        var rest = text;
        while (rest.length() > 0) {
            var end = rest.find("\n");
            var line = end == null ? rest : rest.substring(0, end);
            rest = end == null ? "" : rest.substring(end + 1, rest.length());
            if (line.find("trk lost") != null) {
                continue;
            }
            var from = 4;
            var space = line.substring(from, line.length()).find(" ");
            times.add(line.substring(from, from + (space as Number)).toNumber());
        }
        return times;
    }

    function ordered(times as Array<Number>) as Boolean {
        for (var i = 1; i < times.size(); i++) {
            if (times[i] <= times[i - 1]) {
                return false;
            }
        }
        return true;
    }
}

//! 10 minutes at 1 fix per second, with the send every 30 s as in the app: 120
//! fixes recorded, all 120 delivered, in order, none lost.
(:test)
function tenMinutesOfFixesLoseNothing(logger as Logger) as Boolean {
    var buffer = new TrackBuffer();
    var delivered = [] as Array<Number>;
    for (var second = 0; second < 600; second++) {
        buffer.offer(second * 1000, -2355000 + second, -4665000 - second, 13.9, 1.5707964, false);
        if (second % 30 == 29) {
            delivered.addAll(TrackAssert.points(buffer.take(1000)));
        }
    }
    delivered.addAll(TrackAssert.points(buffer.take(1000)));

    Test.assertEqualMessage(buffer.recorded, 120, "one fix every 5 s over 10 min");
    Test.assertEqualMessage(buffer.lost, 0, "nothing lost with the phone listening");
    Test.assertEqualMessage(delivered.size(), 120, "all 120 reached the log");
    Test.assertMessage(TrackAssert.ordered(delivered), "in time order");
    Test.assertEqualMessage(delivered[0], 0, "the first fix is the departure one");
    Test.assertEqualMessage(delivered[119], 595, "the last one is the 595 s one");
    Test.assertEqualMessage(buffer.unsent(), 0, "nothing pending");
    return true;
}

//! Full buffer, phone mute: the old fixes drop out, and the next send starts
//! by saying how many. A fix already sent that leaves the ring is not a loss.
(:test)
function aFullBufferReportsTheDrops(logger as Logger) as Boolean {
    var buffer = new TrackBuffer();
    var cap = buffer.CAPACITY;
    for (var i = 0; i < cap + 3; i++) {
        buffer.offer(i * 5000, -2355000, -4665000, 0.0, null, false);
    }
    Test.assertEqualMessage(buffer.recorded, cap + 3, "recorded all");
    Test.assertEqualMessage(buffer.lost, 3, "3 overwritten before being sent");

    var text = buffer.take(100000);
    Test.assertMessage(text.find("trk lost 3\ntrk 15 ") == 0, "opens with the loss and goes on from the oldest left: " + text.substring(0, 40));
    var times = TrackAssert.points(text);
    Test.assertEqualMessage(times.size(), cap, "the whole ring");
    Test.assertEqualMessage(buffer.take(100000), "", "the loss is reported only once");

    // Sent and then overwritten: not a loss.
    for (var i = 0; i < 5; i++) {
        buffer.offer((cap + 10 + i) * 5000, -2355000, -4665000, 0.0, null, true);
    }
    Test.assertEqualMessage(buffer.lost, 3, "what was already sent can leave the ring");

    // The character ceiling cuts at a whole line and leaves the rest for later.
    var one = buffer.take(50);
    Test.assertMessage(one.length() <= 50 && one.find("\n") == null, "a single line: " + one);
    Test.assertEqualMessage(buffer.unsent(), 4, "the other 4 wait");
    return true;
}
