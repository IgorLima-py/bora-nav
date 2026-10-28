import Toybox.Lang;

//! What the demo does after everything is loaded: nothing, `DemoFeed` holds the screen
//! for `HOLD_S` and exits. `watch/ride.jungle` excludes `demo_hold` and puts in its place
//! the `demoAfterLoad` of `watch/demo/ride/RideStart.mc`, which sets off walking the route.
(:demo_hold)
function demoAfterLoad() as Boolean {
    return false;
}
