import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Test;

//! **The streets in one image** (`StreetCache`, 2026-10-17). What these tests prove:
//!
//! - the pasted image lands on **the same pixel** where per-frame drawing would put the street, at any
//!   heading, offset and scale (the matrix against `screenX`/`screenY`);
//! - the image is built in steps that respect the watchdog and draws **all** the ways that cross its
//!   square, not the 15 that the leash used to leave;
//! - the frame with the image ready draws no street at all, and so pays for no street;
//! - it is rebuilt when needed (moved, zoom changed, corridor arrived) and only then.
//!
//! The cost of pasting the image on the wrist is not proven here: the simulator runs on the PC. The
//! [theCacheCostsAreLogged] test leaves the simulator's numbers in the log, to compare with C16's.

(:test)
module CacheAssert {

    //! A ready image, built step by step the way the app's timer would. Returns how many steps.
    function build(map as MapRenderer, corridor as CorridorModel) as Number {
        var steps = 0;
        while (map.streetsBuilding() && steps < 500) {
            map.stepStreets(corridor);
            steps++;
        }
        return steps;
    }

    //! A map frame with the rider at (`x`, `y`) and heading `heading`.
    function frame(
        map as MapRenderer,
        dc as Dc,
        route as RouteModel,
        nav as NavState,
        matcher as MapMatcher,
        corridor as CorridorModel,
        x as Float,
        y as Float,
        heading as Float,
        mpp as Float
    ) as Void {
        nav.metersPerPx = mpp;
        nav.applyFix(x, y, 14.0, heading);
        matcher.update(x, y);
        map.draw(dc, route, nav, matcher, corridor);
    }

    //! Frames stopped at (0, `y`), heading 0.2, until one of them draws street by street; at most 8. Returns
    //! in which frame the first street came out, or 0 if none drew.
    function framesUntilStreets(
        map as MapRenderer,
        dc as Dc,
        route as RouteModel,
        nav as NavState,
        matcher as MapMatcher,
        corridor as CorridorModel,
        y as Float,
        mpp as Float
    ) as Number {
        for (var f = 1; f <= 8; f++) {
            frame(map, dc, route, nav, matcher, corridor, 0.0, y, 0.2, mpp);
            if (map.corridorSegments > 0) {
                return f;
            }
        }
        return 0;
    }

    //! How many images with these `options` the pool accepts at once, held (`get`), up to 6.
    function poolFits(options as {
        :width as Number, :height as Number, :colorDepth as Number
    }) as Number {
        var held = [] as Array<BufferedBitmap>;
        try {
            while (held.size() < 6) {
                var image = Graphics.createBufferedBitmap(options).get() as BufferedBitmap?;
                if (image == null) {
                    break;
                }
                held.add(image);
            }
        } catch (ex) {
        }
        return held.size();
    }

    //! The body of [theImageLandsWhereTheLiveStreetsWould], flat (`tilt` false) or tilted.
    function landing(logger as Logger, dc as Dc, tilt as Boolean) as Void {
        var route = NavAssert.straightRoute(800);
        var corridor = CityAssert.cityCorridor();
        var nav = new NavState();
        var matcher = new MapMatcher(route);
        var map = new MapRenderer();
        map.tilt = tilt;
        map.setStreetCache(true);
        CacheAssert.frame(map, dc, route, nav, matcher, corridor, 0.0, 4000.0, 0.3, 1.2);
        CacheAssert.build(map, corridor);
        var cache = map.streets();
        Test.assertMessage(cache.ready(), "the image was not ready");
        Test.assertEqualMessage(cache.tiltK, tilt ? DesignTokens.TILT_K.toFloat() : 1.0, "the image K");
        Test.assertEqualMessage(map.tiltK(), cache.tiltK, "the frame K and the image K");

        var headings = [0.0, 0.7, 2.5, -1.2, 3.1] as Array<Float>;
        var shifts = [[0.0, 0.0], [40.0, -25.0], [-60.0, 80.0]] as Array<Array<Float> >;
        var scales = [1.2, 1.32, 1.0] as Array<Float>;
        var points = [[0.0, 4000.0], [150.0, 4100.0], [-220.0, 3850.0], [90.0, 4260.0]] as Array<Array<Float> >;
        var transform = new AffineTransform();
        var worst = 0.0;
        for (var h = 0; h < headings.size(); h++) {
            for (var s = 0; s < shifts.size(); s++) {
                for (var k = 0; k < scales.size(); k++) {
                    var heading = headings[h] as Float;
                    var shift = shifts[s] as Array<Float>;
                    var cx = (shift[0] as Float).toFloat();
                    var cy = (4000.0 + (shift[1] as Float)).toFloat();
                    var mpp = scales[k] as Float;
                    map.beginAt(cx, cy, mpp, heading);
                    var sin = Math.sin(heading).toFloat();
                    var cos = Math.cos(heading).toFloat();
                    transform.setMatrix(cache.matrix(cx, cy, sin, cos, mpp,
                        map.ANCHOR_X.toFloat(), map.ANCHOR_Y.toFloat()));
                    for (var p = 0; p < points.size(); p++) {
                        var point = points[p] as Array<Float>;
                        var x = point[0] as Float;
                        var y = point[1] as Float;
                        var got = transform.transformPoint([cache.imageX(x), cache.imageY(y)] as Point2D);
                        var dx = (got[0] as Numeric) - map.screenX(x, y);
                        var dy = (got[1] as Numeric) - map.screenY(x, y);
                        var err = (dx * dx + dy * dy).toFloat();
                        if (err > worst) {
                            worst = err;
                        }
                        Test.assertMessage(err < 0.01,
                            (tilt ? "tilted, " : "") + "heading " + heading.toString() + " offset "
                                + s.toString() + " scale " + mpp.toString() + ": the image lands "
                                + Math.sqrt(err).format("%.2f") + " px off the street");
                    }
                }
            }
        }
        logger.debug("worst difference between the image and the street" + (tilt ? " (tilted)" : "") + ": "
            + Math.sqrt(worst).format("%.4f") + " px");
    }

    //! How many corridor ways cross the square of the image being (or that was) drawn,
    //! counted one by one by the box, without the block index.
    function waysInImage(cache as StreetCache, corridor as CorridorModel) as Number {
        var count = 0;
        var side = cache.side.toFloat();
        for (var lod = 0; lod < Protocol.CORRIDOR_LOD_COUNT; lod++) {
            var boxes = corridor.wayBox[lod] as Array<Float>;
            for (var w = 0; w < boxes.size() / 4; w++) {
                var b = w * 4;
                if (cache.imageX(boxes[b + 1] as Float) > 0.0 && cache.imageX(boxes[b] as Float) < side
                        && cache.imageY(boxes[b + 2] as Float) > 0.0
                        && cache.imageY(boxes[b + 3] as Float) < side) {
                    count++;
                }
            }
        }
        return count;
    }
}

//! **The image lands where the street would be.** For world points spread across the image, its pixel
//! carried by the [StreetCache.blit] matrix has to match the renderer's `screenX`/`screenY`,
//! with heading, center offset and scale different from the image's, flat and tilted (v1.1.5). A
//! flipped sign here turns the street map to the wrong side of the route, which is the
//! "R(−heading)" error from F2; a forgotten K on one of the two sides detaches the route from the streets.
(:test)
function theImageLandsWhereTheLiveStreetsWould(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null || !(Graphics has :AffineTransform)) {
        return true;
    }
    CacheAssert.landing(logger, dc as Dc, false);
    CacheAssert.landing(logger, dc as Dc, true);
    return true;
}

//! **The streets image is 16-bit.** With the app's options ([StreetCache.imageOptions]) the simulator's
//! 4 MB pool accepts at least the two tilted 816 px images (1.33 MB each at
//! 16 bits). The log records how many fit each way, and how many fit with the SDK default (full
//! alpha), which is what brought down the tilted map on v1.1.5's first lap.
(:test)
function theStreetImageIsSixteenBits(logger as Logger) as Boolean {
    if (!(Graphics has :createBufferedBitmap)) {
        return true;
    }
    var sides = new StreetCache();
    var tilt = CacheAssert.poolFits(StreetCache.imageOptions(sides.SIDE_TILT, true));
    var flat = CacheAssert.poolFits(StreetCache.imageOptions(sides.SIDE_FLAT, true));
    var sdkTilt = CacheAssert.poolFits({ :width => sides.SIDE_TILT, :height => sides.SIDE_TILT });
    var sdkFlat = CacheAssert.poolFits({ :width => sides.SIDE_FLAT, :height => sides.SIDE_FLAT });
    logger.debug("pool: with the app options " + tilt.toString() + " of 816 and " + flat.toString()
        + " of 640 fit; with the SDK default, " + sdkTilt.toString() + " of 816 and " + sdkFlat.toString() + " of 640 fit");
    Test.assertMessage(tilt >= 2, "only " + tilt.toString() + " tilted image fits in the pool");
    Test.assertMessage(flat >= 2, "only " + flat.toString() + " flat image fits in the pool");
    return true;
}

//! **The tilted image fits in the pool and is born with slack.** The two 816 px images (1.33 MB each)
//! fit in the simulator's pool without the map falling back to flat, and a new image has at least the
//! rebuild slack ([StreetCache.REBUILD_SLACK_PX]) measured by the glass ellipse, at the worst heading (the
//! axes) and on the diagonal. Without this, an image too small would be born asking for another.
(:test)
function theTiltedImageFitsThePoolAndStartsWithRoom(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null || !(Graphics has :AffineTransform)) {
        return true;
    }
    var route = NavAssert.straightRoute(800);
    var corridor = CityAssert.cityCorridor();
    var headings = [0.0, 0.785, 1.571, 3.1416] as Array<Float>;
    for (var h = 0; h < headings.size(); h++) {
        var heading = headings[h] as Float;
        var nav = new NavState();
        var matcher = new MapMatcher(route);
        var map = new MapRenderer();
        map.tilt = true;
        map.setStreetCache(true);
        CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4000.0, heading, 1.2);
        CacheAssert.build(map, corridor);
        // The second image: 260 m ahead is past the slack at any heading and asks for the other, which goes
        // to the other buffer.
        var y = 4000.0 + 260.0 * Math.cos(heading);
        var x = 260.0 * Math.sin(heading);
        CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, x.toFloat(), y.toFloat(), heading, 1.2);
        CacheAssert.build(map, corridor);
        var cache = map.streets();
        Test.assertMessage(cache.ready() && !cache.failed, "the tilted image was not ready");
        Test.assertMessage(!cache.tiltRefused, "the pool refused both tilted images");
        Test.assertEqualMessage(cache.side, cache.SIDE_TILT, "the tilted image has its own side");
        Test.assertEqualMessage(cache.builds, 2, "both images");
        cache.resetStats();
        CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, x.toFloat(), y.toFloat(), heading, 1.2);
        var room = cache.slackMin;
        Test.assertMessage(room != null && (room as Number) >= cache.REBUILD_SLACK_PX.toNumber(),
            "heading " + heading.toString() + ": the new image is born with slack "
                + (room == null ? "none" : (room as Number).toString()));
        Test.assertMessage(!map.streetsBuilding(), "heading " + heading.toString() + ": the new image already asks for another");
        logger.debug("heading " + heading.toString() + ": slack of the new tilted image " + (room as Number).toString() + " px");
        // Drops both before the next heading: the test screen also lives in the pool (454 px at 32 bits,
        // 824 KB), and with it and the two tilted ones here a third does not fit.
        map.setStreetCache(false);
    }
    return true;
}

//! **All the streets, in steps the watchdog accepts.** The `WatchdogTest` dense city becomes an
//! image in several steps, none goes over the quota ([StreetCache.SLICE_WORK] plus one way), and the
//! image has **all** the ways that cross its square, counted one by one.
(:test)
function theImageHasEveryStreetAndIsBuiltInSafeSteps(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null || !(Graphics has :AffineTransform)) {
        return true;
    }
    var route = NavAssert.straightRoute(800);
    var corridor = CityAssert.cityCorridor();
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    map.setStreetCache(true);
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4000.0, 0.0, 1.2);
    Test.assertMessage(map.streetsBuilding(), "the first frame must ask for the image");
    Test.assertMessage(map.wantsCatchUp(), "an image yet to build must ask for the catch-up timer");
    var steps = CacheAssert.build(map, corridor);
    var cache = map.streets();
    Test.assertMessage(cache.ready(), "the image was not ready in " + steps.toString() + " steps");
    Test.assertMessage(!map.wantsCatchUp(), "with the image ready, no timer");

    var expected = CacheAssert.waysInImage(cache, corridor);
    Test.assertEqualMessage(cache.lastBuildWays, expected,
        "the image drew " + cache.lastBuildWays.toString() + " ways, the square crosses "
            + expected.toString());
    Test.assertMessage(cache.lastBuildSteps > 1, "the whole city fit in a single step: the quota did not cut");
    var cap = cache.SLICE_WORK + 64;
    Test.assertMessage(cache.stepWorkMax <= cap,
        "a step spent " + cache.stepWorkMax.toString() + " points, ceiling " + cap.toString());
    Test.assertMessage(cache.stepWorkMax < map.WORK_FATAL / 3, "the step gets close to the watchdog");
    logger.debug("image: " + expected.toString() + " ways in " + cache.lastBuildSteps.toString()
        + " steps, " + cache.lastBuildWork.toString() + " points, " + cache.lastBuildMs.toString()
        + " ms in the simulator; costliest step " + cache.stepWorkMax.toString());
    return true;
}

//! **The frame with an image pays for no street.** With the image ready, the frame draws zero street
//! segments and costs the same work as the frame with no corridor at all: the streets' cost left
//! `onUpdate`. Without the cache, the same city costs the whole leash.
(:test)
function aCachedFrameDrawsNoStreetByStreet(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null || !(Graphics has :AffineTransform)) {
        return true;
    }
    var route = NavAssert.straightRoute(800);
    var corridor = CityAssert.cityCorridor();
    var empty = new CorridorModel();
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    map.setStreetCache(true);
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4000.0, 0.4, 1.2);
    CacheAssert.build(map, corridor);
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4005.0, 0.4, 1.2);
    Test.assertEqualMessage(map.corridorSegments, 0, "the frame with an image drew street by street");
    var cached = map.work;

    // The same two frames, so the route cache is the same in both renderers.
    var bare = new MapRenderer();
    CacheAssert.frame(bare, dc as Dc, route, nav, matcher, empty, 0.0, 4000.0, 0.4, 1.2);
    CacheAssert.frame(bare, dc as Dc, route, nav, matcher, empty, 0.0, 4005.0, 0.4, 1.2);
    Test.assertEqualMessage(cached, bare.work, "the frame with an image costs more than the one without streets");

    var live = new MapRenderer();
    for (var f = 0; f < 6; f++) {
        CacheAssert.frame(live, dc as Dc, route, nav, matcher, corridor, 0.0, 4005.0, 0.4, 1.2);
        live.noteFrame(10);
    }
    logger.debug("frame work: " + cached.toString() + " with the image, " + live.work.toString()
        + " drawing the streets (" + live.corridorSegments.toString() + " segments)");
    Test.assertMessage(live.work > cached, "without the image the frame had to pay for the streets");
    return true;
}

//! **With no image covering the glass, the streets do not vanish.** Before the first image, and when a large
//! zoom leaves the image on screen too small for the glass, the frame draws street by street (with the
//! leash, as without the cache) and counts the frame in `fallbacks`. With the image ready, it goes back to pasting.
//! It was the empty glass in the "far" scene of `sim.py shots`, which jumps the rider from one place to another.
(:test)
function withoutAnImageTheStreetsStillShow(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null || !(Graphics has :AffineTransform)) {
        return true;
    }
    var route = NavAssert.straightRoute(800);
    var corridor = CityAssert.cityCorridor();
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    map.setStreetCache(true);
    var cache = map.streets();

    // The street-by-street sweep takes a few frames before the first street, as without the cache. The
    // frames come without an image step: it does not move.
    var frames = CacheAssert.framesUntilStreets(map, dc as Dc, route, nav, matcher, corridor, 4000.0, 1.2);
    Test.assertMessage(!cache.ready(), "the image cannot be ready without a step");
    Test.assertMessage(frames > 0, "without an image, the glass had no street for 8 frames");
    Test.assertEqualMessage(cache.fallbacks, frames, "the street-by-street frames were not counted");

    CacheAssert.build(map, corridor);
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4005.0, 0.2, 1.2);
    Test.assertEqualMessage(map.corridorSegments, 0, "with the image ready, it went back to drawing street by street");
    Test.assertMessage(!map.wantsCatchUp(), "with the image on the glass, the idle scan still asks for frames");

    // From 1.2 to 3.0 m/px: the old image shrinks to less than half the glass.
    var zoomed = CacheAssert.framesUntilStreets(map, dc as Dc, route, nav, matcher, corridor, 4005.0, 3.0);
    Test.assertMessage(!cache.covers(), "the shrunken image does not cover the glass");
    Test.assertMessage(zoomed > 0, "at the big zoom, the glass had no street until the new image");
    CacheAssert.build(map, corridor);
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4005.0, 0.2, 3.0);
    Test.assertEqualMessage(map.corridorSegments, 0, "the new image did not return to the glass");
    logger.debug("street-by-street frames until the first street: " + frames.toString() + " without an image, "
        + zoomed.toString() + " at zoom");
    return true;
}

//! **The image is rebuilt when needed, and only then.** Moving within the slack does not ask for another; moving
//! close to the edge does; changing the zoom does; and a corridor that arrives in the middle of an image still
//! being built restarts without reading a stale index.
(:test)
function theImageIsRebuiltOnlyWhenItMustBe(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null || !(Graphics has :AffineTransform)) {
        return true;
    }
    var route = NavAssert.straightRoute(800);
    var corridor = CityAssert.cityCorridor();
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    map.setStreetCache(true);
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4000.0, 0.0, 1.2);
    CacheAssert.build(map, corridor);
    var cache = map.streets();

    // 40 m forward (33 px), within the slack: the same image.
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4040.0, 0.0, 1.2);
    Test.assertMessage(!map.streetsBuilding(), "40 m ahead asked for another image");
    // Turning a little in place does not either: the image is north-up.
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4040.0, 0.5, 1.2);
    Test.assertMessage(!map.streetsBuilding(), "turning in place asked for another image");
    // 160 m (133 px): past the slack.
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4160.0, 0.0, 1.2);
    Test.assertMessage(map.streetsBuilding(), "160 m ahead and the old image stayed");
    CacheAssert.build(map, corridor);

    // Zoom from 1.2 to 2.5 m/px: another image, at the new scale.
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4160.0, 0.0, 2.5);
    Test.assertMessage(map.streetsBuilding(), "the zoom changed and the image did not");

    // In the middle of it, a smaller corridor arrives: it restarts and finishes without an index outside the array.
    map.stepStreets(corridor);
    var small = new CorridorModel();
    small.setLod(0, [-100.0, 100.0] as Array<Float>, [4160.0, 4160.0] as Array<Float>,
        [0, 2] as Array<Number>);
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, small, 0.0, 4160.0, 0.0, 2.5);
    CacheAssert.build(map, small);
    Test.assertMessage(cache.ready(), "the image of the new corridor was not ready");
    Test.assertEqualMessage(cache.lastBuildWays, 1, "the new image must have only the way of the new corridor");

    // Turning it off drops the images and goes back to per-frame drawing.
    map.setStreetCache(false);
    Test.assertMessage(!cache.ready(), "switched off, the image stayed");
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, small, 0.0, 4160.0, 0.0, 2.5);
    Test.assertMessage(!map.streetsBuilding(), "switched off and asking for an image");
    return true;
}

//! **Changing the depth rebuilds the image** (C16, `CONFIG` 19). The on-screen image goes out, the next
//! is born in the new format and gets ready, and going back to 16 bits does the same.
// prevents: the 16-bit switch sent from the phone to compare on the wrist only taking effect after
// reopening the app (2026-10-19: the streets did not show on the first lap with the image).
(:test)
function theDepthSwitchRebuildsTheImage(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null || !(Graphics has :AffineTransform)) {
        return true;
    }
    var route = NavAssert.straightRoute(800);
    // A single street: the format switch does not depend on how many streets there are, and the whole city three times
    // cost the simulator more than the rest of the file.
    var corridor = new CorridorModel();
    corridor.setLod(0, [-100.0, 100.0] as Array<Float>, [4000.0, 4000.0] as Array<Float>,
        [0, 2] as Array<Number>);
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    map.setStreetCache(true);
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4000.0, 0.0, 1.2);
    CacheAssert.build(map, corridor);
    var cache = map.streets();
    Test.assertMessage(cache.ready(), "the 16-bit image was not ready");

    map.setStreet16Bit(false);
    Test.assertMessage(!cache.ready(), "switched to the SDK default and the 16-bit image stayed");
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4000.0, 0.0, 1.2);
    CacheAssert.build(map, corridor);
    Test.assertMessage(cache.ready() && !cache.failed, "the image at the SDK default was not ready");

    map.setStreet16Bit(true);
    Test.assertMessage(!cache.ready(), "went back to 16 bits and the SDK image stayed");
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4000.0, 0.0, 1.2);
    CacheAssert.build(map, corridor);
    Test.assertMessage(cache.ready(), "the 16-bit image did not come back");
    return true;
}

//! **The simulator's numbers, in the log** (not an assertion: the simulator runs on the PC and the wrist is different).
//! How much it costs to paste the image rotated with bilinear filter, how much it costs to draw the same city
//! street by street with the leash at the ceiling, and whether the two images weigh on the app's heap or only on the pool.
(:test)
function theCacheCostsAreLogged(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null || !(Graphics has :AffineTransform)) {
        return true;
    }
    var route = NavAssert.straightRoute(800);
    var corridor = CityAssert.cityCorridor();
    var nav = new NavState();
    var matcher = new MapMatcher(route);

    var before = System.getSystemStats().usedMemory;
    var map = new MapRenderer();
    map.setStreetCache(true);
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4000.0, 0.5, 1.2);
    CacheAssert.build(map, corridor);
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4200.0, 0.5, 1.2);
    CacheAssert.build(map, corridor);
    var after = System.getSystemStats().usedMemory;

    var started = System.getTimer();
    for (var f = 0; f < 20; f++) {
        CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4200.0 + f, 0.5 + f * 0.05, 1.2);
    }
    var cachedMs = (System.getTimer() - started) / 20;
    var blitMs = map.msCorridor;
    map.streets().filterMode = Graphics.FILTER_MODE_POINT;
    started = System.getTimer();
    for (var f = 0; f < 20; f++) {
        CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4200.0 + f, 0.5 + f * 0.05, 1.2);
    }
    var pointMs = (System.getTimer() - started) / 20;

    var live = new MapRenderer();
    live.corridorBudget = live.WORK_MAX;
    for (var f = 0; f < 6; f++) {
        CacheAssert.frame(live, dc as Dc, route, nav, matcher, corridor, 0.0, 4200.0, 0.5, 1.2);
        live.noteFrame(10);
    }
    started = System.getTimer();
    for (var f = 0; f < 20; f++) {
        CacheAssert.frame(live, dc as Dc, route, nav, matcher, corridor, 0.0, 4200.0 + f, 0.5 + f * 0.05, 1.2);
    }
    var liveMs = (System.getTimer() - started) / 20;

    logger.debug("simulator: frame with the image " + cachedMs.toString() + " ms (blit "
        + blitMs.toString() + " ms), with point filter " + pointMs.toString()
        + " ms, street by street at the leash ceiling " + liveMs.toString()
        + " ms (" + live.corridorSegments.toString() + " segments); heap with both images +"
        + (after - before).toString() + " B; image " + map.streets().lastBuildMs.toString() + " ms in "
        + map.streets().lastBuildSteps.toString() + " steps");
    return true;
}

//! **The v1.2.9 levers**: each single image and each probe builds and pastes the image with its side,
//! the probe holds its extra images, and each grid builds the tiles around the glass and pastes
//! without drawing street by street, even with "Streets in image" off; the street-by-street control one
//! turns the image off; and going back to 0 returns the map to the switch. What shows on the glass is not proven
//! here: the simulator shows the streets with any of them, and it is on the wrist that they say anything.
(:test)
function everyStreetLeverBuildsAndPastes(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null || !(Graphics has :AffineTransform)) {
        return true;
    }
    var route = NavAssert.straightRoute(800);
    var corridor = new CorridorModel();
    corridor.setLod(0, [-100.0, 100.0] as Array<Float>, [4000.0, 4000.0] as Array<Float>,
        [0, 2] as Array<Number>);
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    map.setStreetCache(false);
    var cache = map.streets();

    map.setStreetDiag(StreetCache.DIAG_LIVE);
    Test.assertMessage(!map.imageOn(), "the street-by-street control turned the image on");
    map.setStreetCache(true);
    Test.assertMessage(!map.imageOn(), "the street-by-street control yielded to the switch");
    map.setStreetCache(false);

    for (var lever = 2; lever <= Config.STREET_DIAG_MAX; lever++) {
        var name = lever.toString() + " (" + (StreetCache.DIAG_NAMES[lever] as String) + ")";
        map.setStreetDiag(lever);
        Test.assertMessage(map.imageOn(), "lever " + name + " did not turn the image on");
        Test.assertMessage(!cache.ready(), "lever " + name + " did not rebuild the image");
        var gridded = lever >= StreetCache.DIAG_GRID_FIRST;
        var frames = 0;
        while ((gridded ? !cache.gridComplete() : !cache.ready()) && frames < 80) {
            CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4000.0, 0.3, 1.2);
            CacheAssert.build(map, corridor);
            frames++;
        }
        Test.assertMessage(cache.ready() && !cache.failed, "lever " + name + " did not build the image");
        if (gridded) {
            var g = lever - StreetCache.DIAG_GRID_FIRST;
            Test.assertEqualMessage(cache.grid, StreetCache.GRID_COUNTS[g], "the grid of lever " + name);
            Test.assertEqualMessage(cache.side, StreetCache.GRID_SIDES[g], "the tile side at lever " + name);
            Test.assertMessage(cache.gridComplete(), "lever " + name + " did not complete the grid");
        } else if (lever >= StreetCache.DIAG_PROBE_FIRST) {
            Test.assertEqualMessage(cache.side, StreetCache.PROBE_SIDE, "the image side at probe " + name);
        } else {
            Test.assertEqualMessage(cache.side, StreetCache.DIAG_SIDES[lever - StreetCache.DIAG_SIZE_FIRST],
                "the image side at lever " + name);
        }
        CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4000.0, 0.3, 1.2);
        Test.assertEqualMessage(map.corridorWork, 0, "lever " + name + " drew street by street");
        if (lever >= StreetCache.DIAG_PROBE_FIRST && !gridded) {
            // The simulator has a 4 MB pool: the test screen (824 KB), the two streets images and the
            // probe's extras (460 800 B each) fit. On the wrist it is the probe's question.
            Test.assertEqualMessage(cache.probesHeld, cache.probeCount() - 1, "the probe extra images " + name);
        }
        if (gridded) {
            Test.assertMessage(cache.tilesPasted > 0, "the grid " + name + " did not paste a tile");
            logger.debug("lever " + name + ": " + cache.tilesPasted.toString() + " tiles pasted");
        }
    }
    map.setStreetDiag(StreetCache.DIAG_OFF);
    Test.assertMessage(!map.imageOn(), "lever 0 left the image on with the switch off");
    Test.assertEqualMessage(map.streets().side, map.streets().SIDE_FLAT, "lever 0 did not go back to the flat side");
    map.useStreetGrid();
    Test.assertEqualMessage(cache.grid, StreetCache.GRID_COUNTS[StreetCache.GRID_DEFAULT],
        "lever 0 with the app grid");
    return true;
}

//! **Each tile lands where the street would be.** The grid's [theImageLandsWhereTheLiveStreetsWould]:
//! for points inside each ready tile, the pixel carried by its matrix matches the
//! renderer's `screenX`/`screenY`, at several headings and scales, flat and tilted. A swapped tile
//! center or a wrong half-side would open a seam of mismatched streets.
(:test)
function everyTileLandsWhereTheLiveStreetsWould(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null || !(Graphics has :AffineTransform)) {
        return true;
    }
    var route = NavAssert.straightRoute(800);
    var corridor = CityAssert.cityCorridor();
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    map.useStreetGrid();
    map.setStreetCache(true);
    var cache = map.streets();
    for (var f = 0; f < 40 && !cache.gridComplete(); f++) {
        CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4000.0, 0.3, 1.2);
        CacheAssert.build(map, corridor);
    }
    Test.assertMessage(cache.gridComplete(), "the grid was not ready");
    var transform = new AffineTransform();
    var headings = [0.0, 0.7, 2.5, -1.2] as Array<Float>;
    var scales = [1.2, 1.25] as Array<Float>;
    var worst = 0.0;
    for (var tilted = 0; tilted < 2; tilted++) {
        map.tilt = tilted == 1;
        for (var h = 0; h < headings.size(); h++) {
            for (var m = 0; m < scales.size(); m++) {
                var heading = headings[h] as Float;
                var mpp = scales[m] as Float;
                map.beginAt(10.0, 4010.0, mpp, heading);
                cache.setTilt(map.tiltK());
                var sin = Math.sin(heading).toFloat();
                var cos = Math.cos(heading).toFloat();
                for (var k = 0; k < cache.tileCount(); k++) {
                    var t = cache.tile(k);
                    if (t == null) {
                        continue;
                    }
                    var tx = t[0] as Float;
                    var ty = t[1] as Float;
                    var ts = t[2] as Float;
                    transform.setMatrix(cache.matrixAt(tx, ty, ts, 10.0, 4010.0, sin, cos, mpp,
                        map.ANCHOR_X.toFloat(), map.ANCHOR_Y.toFloat()));
                    // Three points of the tile: the center and two inner corners.
                    var offsets = [[0.0, 0.0], [-100.0, 80.0], [90.0, -110.0]] as Array<Array<Float> >;
                    for (var p = 0; p < offsets.size(); p++) {
                        var o = offsets[p] as Array<Float>;
                        var x = tx + (o[0] as Float) * ts;
                        var y = ty + (o[1] as Float) * ts;
                        var u = cache.half + (x - tx) / ts;
                        var v = cache.half - (y - ty) / ts;
                        var got = transform.transformPoint([u, v] as Point2D);
                        var dx = (got[0] as Numeric) - map.screenX(x, y);
                        var dy = (got[1] as Numeric) - map.screenY(x, y);
                        var err = (dx * dx + dy * dy).toFloat();
                        if (err > worst) {
                            worst = err;
                        }
                        Test.assertMessage(err < 0.01, "tile " + k.toString() + " heading " + heading.toString()
                            + (tilted == 1 ? " tilted" : "") + ": lands " + Math.sqrt(err).format("%.2f") + " px off the street");
                    }
                }
            }
        }
    }
    logger.debug("worst difference between the tile and the street: " + Math.sqrt(worst).format("%.4f") + " px");
    return true;
}

//! **The grid follows the rider.** A 1.5 km lap in the dense city at 60 km/h, flat and tilted,
//! with one frame and 6 image steps per second (the 100 ms `CATCHUP_MS` plus the step of up to
//! 60 ms): the glass is covered by tiles almost always, only the new tiles get built, and each
//! row change costs at most one row ([grid] tiles). The fraction of street-by-street frames
//! goes to the log; the ceiling comes from the first measurement (C16.6).
(:test)
function theGridFollowsTheRider(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null || !(Graphics has :AffineTransform)) {
        return true;
    }
    var route = NavAssert.straightRoute(2000);
    var corridor = CityAssert.cityCorridor();
    for (var tilted = 0; tilted < 2; tilted++) {
        var nav = new NavState();
        var matcher = new MapMatcher(route);
        var map = new MapRenderer();
        map.tilt = tilted == 1;
        map.useStreetGrid();
        map.setStreetCache(true);
        var cache = map.streets();
        // Stopped until the grid is ready, as at departure.
        for (var f = 0; f < 40 && !cache.gridComplete(); f++) {
            CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 3500.0, 0.0, 1.2);
            CacheAssert.build(map, corridor);
        }
        Test.assertMessage(cache.gridComplete(), "the exit grid was not ready");
        cache.resetStats();
        var seconds = 90;
        var uncovered = 0;
        for (var t = 1; t <= seconds; t++) {
            var y = 3500.0 + t * 16.7;
            CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, y.toFloat(), 0.0, 1.2);
            if (map.corridorWork > 0) {
                uncovered++;
            }
            for (var s = 0; s < 6 && map.streetsBuilding(); s++) {
                map.stepStreets(corridor);
            }
        }
        // 90 s at 16.7 m/s is 1,503 m; with tiles of 236 px x 1.2 m/px = 283 m, about 5 rows.
        var rows = (seconds * 16.7 / (cache.half * 2 - 2 * cache.OVERLAP_PX) / 1.2).toNumber() + 1;
        var most = rows * cache.grid;
        logger.debug((tilted == 1 ? "tilted" : "flat") + ": " + uncovered.toString() + " of "
            + seconds.toString() + " street-by-street frames, " + cache.builds.toString() + " tiles built (ceiling "
            + most.toString() + "), costliest step " + cache.stepWorkMax.toString());
        Test.assertMessage(cache.builds <= most, "the grid rebuilt " + cache.builds.toString()
            + " tiles while moving, ceiling " + most.toString());
        Test.assertMessage(uncovered * 10 <= seconds, (tilted == 1 ? "tilted" : "flat") + ": "
            + uncovered.toString() + " of " + seconds.toString() + " frames without a tile on the glass");
        Test.assertMessage(cache.stepWorkMax <= cache.SLICE_WORK + 64, "a tile step went past the quota");
        map.setStreetCache(false);
    }
    return true;
}

//! **The grids fit in the pool.** Each grid of levers 8 to 10 holds [grid]² + 1 tiles (the
//! reserve). The simulator's 4 MB pool, with the test screen (824 KB), has to accept all of them.
(:test)
function everyGridFitsThePool(logger as Logger) as Boolean {
    if (!(Graphics has :createBufferedBitmap)) {
        return true;
    }
    var screen = CityAssert.screenDc();
    for (var g = 0; g < StreetCache.GRID_COUNTS.size(); g++) {
        var count = StreetCache.GRID_COUNTS[g] as Number;
        var side = StreetCache.GRID_SIDES[g] as Number;
        var want = count * count + 1;
        var held = [] as Array<BufferedBitmap>;
        try {
            while (held.size() < want) {
                var image = Graphics.createBufferedBitmap(StreetCache.imageOptions(side, true)).get() as BufferedBitmap?;
                if (image == null) {
                    break;
                }
                held.add(image);
            }
        } catch (ex) {
        }
        logger.debug("grid " + count.toString() + "x" + count.toString() + " of " + side.toString() + ": "
            + held.size().toString() + " of " + want.toString() + " tiles in the pool ("
            + (want * side * side * 2).toString() + " B)");
        Test.assertEqualMessage(held.size(), want, "the grid " + count.toString() + "x" + count.toString()
            + " did not fit in the pool");
    }
    return screen != null || true;
}

//! **`isCached` in the log** (v1.2.6): every paste checks whether the pool still holds the image, and the
//! frame summary says how many found it (`cache 3/3`). In the simulator the pool does not recycle, so it is 3/3.
(:test)
function theImageCacheCheckIsLogged(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null || !(Graphics has :AffineTransform)) {
        return true;
    }
    var route = NavAssert.straightRoute(800);
    var corridor = new CorridorModel();
    corridor.setLod(0, [-100.0, 100.0] as Array<Float>, [4000.0, 4000.0] as Array<Float>,
        [0, 2] as Array<Number>);
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    map.setStreetCache(true);
    CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4000.0, 0.0, 1.2);
    CacheAssert.build(map, corridor);
    map.streets().resetStats();
    for (var f = 0; f < 3; f++) {
        CacheAssert.frame(map, dc as Dc, route, nav, matcher, corridor, 0.0, 4000.0, 0.0, 1.2);
    }
    var cache = map.streets();
    if (!(Graphics.BufferedBitmap has :isCached)) {
        Test.assertEqualMessage(cache.cachedChecks, 0, "without isCached and it counted a check");
        return true;
    }
    Test.assertEqualMessage(cache.cachedChecks, 3, "three blits, three checks");
    // The simulator (SDK 9.3.0) answers `isCached` false and shows the image anyway: the test checks the
    // count, not the value. On the wrist, the number only says something compared with the simulator's `0/N`.
    var summary = map.streetsSummary();
    var ok = 3 - cache.cachedMisses;
    Test.assertMessage(summary.find(" cache " + ok.toString() + "/3") != null, "the summary does not carry the cache: " + summary);
    return true;
}
