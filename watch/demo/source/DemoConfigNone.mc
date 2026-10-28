import Toybox.Lang;

//! The messages the demo injects before the SP route: none. `watch/demo_config.jungle`
//! excludes `no_demo_config` and puts in its place
//! `bin/config/ConfigParams.mc`, which `sim.py demo --config` (CONFIG, C5) or
//! `--rota-longa` (META, POLY and TURNS of a synthetic route, C6a) generates on every
//! run with the frames in Base64 (the same String the phone sends).
(:no_demo_config)
function demoPreludeFrames() as Array<String> {
    return [] as Array<String>;
}
