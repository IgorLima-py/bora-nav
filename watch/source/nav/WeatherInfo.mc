import Toybox.Lang;
import Toybox.Math;
import Toybox.Weather;

//! The HUD weather (RF-10, C9): temperature and condition from the cache that Garmin
//! keeps on the watch (`Toybox.Weather`, fed by Garmin Connect). Zero
//! keys, zero requests of our own (`06 §APIs`).
//!
//! **Every field can be `null`** (`08 §Pitfalls 4`): phone away, watch without
//! the cache yet, device without the API. In those cases the block **disappears without error** —
//! `hudText` returns `null` and the HUD draws nothing nor reserves space.
//!
//! Reading is cheap (local cache), but does not need to happen every frame: the app
//! asks for it on opening and every [REFRESH_S] (`02 §Weather`, 15 min).
module WeatherInfo {

    //! Seconds between two cache reads (`02-ARCHITECTURE.md`: weather refresh
    //! every 15 min).
    const REFRESH_S = 900;

    //! Accepted temperature range, in °C. Outside it the data is garbage and the
    //! block disappears: -60 and 60 cover the Earth's records (−89 °C in Antarctica and
    //! 57 °C in Death Valley) wherever someone would ride, with margin.
    const MIN_C = -60;
    const MAX_C = 60;

    var temperature as Number? = null;
    var condition as Number? = null;

    //! True when the simulator (the virtual ride) injected a synthetic value:
    //! the real read does not overwrite it. On the watch app it stays `false`.
    var injected as Boolean = false;

    //! Stores what was read. `temp` is `Numeric` (the API returns Float or
    //! Number); without a valid temperature, a condition alone is worthless and disappears
    //! with it.
    function set(temp as Numeric?, cond as Number?) as Void {
        if (temp == null) {
            temperature = null;
            condition = null;
            return;
        }
        var rounded = Math.round(temp.toFloat()).toNumber();
        if (rounded < MIN_C || rounded > MAX_C) {
            temperature = null;
            condition = null;
            return;
        }
        temperature = rounded;
        condition = cond;
    }

    //! The simulator's virtual ride has no weather cache: it injects a value.
    function inject(temp as Number, cond as Number) as Void {
        injected = true;
        set(temp, cond);
    }

    function clear() as Void {
        injected = false;
        temperature = null;
        condition = null;
    }

    //! Reads the system cache. Never throws: a missing API, an empty cache and a
    //! system exception become the same "no weather".
    function readNow() as Void {
        if (injected) {
            return;
        }
        var temp = null;
        var cond = null;
        try {
            if ((Toybox has :Weather) && (Weather has :getCurrentConditions)) {
                var current = Weather.getCurrentConditions();
                if (current != null) {
                    temp = current.temperature;
                    cond = current.condition;
                }
            }
        } catch (ex) {
            Diag.add("weather refused");
        }
        set(temp, cond);
    }

    //! The short name of the condition, in English, for the log; the screen translates it in
    //! [screenLabel], and each language fits in 7 letters on the time line.
    //! The numbers are the `Weather.CONDITION_*` of the SDK 9.2.0 doc (read from
    //! `doc/Toybox/Weather.html`); literals, not the constants, so the
    //! test runs the same on any device. The real icon is C15.
    function conditionLabel(code as Number?) as String {
        if (code == null) {
            return "";
        }
        // CLEAR 0, PARTLY_CLEAR 22, MOSTLY_CLEAR 23, FAIR 40
        if (code == 0 || code == 22 || code == 23 || code == 40) {
            return "sun"; // lang: log
        }
        // PARTLY_CLOUDY 1, MOSTLY_CLOUDY 2, CLOUDY 20, THIN_CLOUDS 52
        if (code == 1 || code == 2 || code == 20 || code == 52) {
            return "cloudy"; // lang: log
        }
        // THUNDERSTORMS 6, SCATTERED_THUNDERSTORMS 12, CHANCE_OF_THUNDERSTORMS 28,
        // TORNADO 32, SQUALL 36, HURRICANE 41, TROPICAL_STORM 42
        if (code == 6 || code == 12 || code == 28 || code == 32 || code == 36
                || code == 41 || code == 42) {
            return "storm"; // lang: log
        }
        // RAIN 3, SCATTERED_SHOWERS 11, UNKNOWN_PRECIPITATION 13, LIGHT_RAIN 14,
        // HEAVY_RAIN 15, LIGHT_SHOWERS 24, SHOWERS 25, HEAVY_SHOWERS 26,
        // CHANCE_OF_SHOWERS 27, DRIZZLE 31, CLOUDY_CHANCE_OF_RAIN 45, FREEZING_RAIN 49
        if (code == 3 || code == 11 || code == 13 || code == 14 || code == 15
                || (code >= 24 && code <= 27) || code == 31 || code == 45 || code == 49) {
            return "rain"; // lang: log
        }
        // SNOW 4, WINTRY_MIX 7, HAIL 10, LIGHT_SNOW 16, HEAVY_SNOW 17,
        // LIGHT_RAIN_SNOW 18, HEAVY_RAIN_SNOW 19, RAIN_SNOW 21, ICE 34,
        // CHANCE_OF_SNOW 43, CHANCE_OF_RAIN_SNOW 44, CLOUDY_CHANCE_OF_SNOW 46,
        // CLOUDY_CHANCE_OF_RAIN_SNOW 47, FLURRIES 48, SLEET 50, ICE_SNOW 51
        if (code == 4 || code == 7 || code == 10 || (code >= 16 && code <= 19) || code == 21
                || code == 34 || (code >= 43 && code <= 44) || (code >= 46 && code <= 48)
                || code == 50 || code == 51) {
            return "snow"; // lang: log
        }
        // FOG 8, HAZY 9, MIST 29, DUST 30, SMOKE 33, SAND 35, SANDSTORM 37,
        // VOLCANIC_ASH 38, HAZE 39
        if (code == 8 || code == 9 || code == 29 || code == 30 || code == 33
                || code == 35 || code == 37 || code == 38 || code == 39) {
            return "fog"; // lang: log
        }
        // WINDY 5
        if (code == 5) {
            return "wind"; // lang: log
        }
        // UNKNOWN 53 and whatever Garmin adds later: no label.
        return "";
    }

    //! The HUD text, `24° nublado`, or `null` when there is no weather.
    function hudText() as String? {
        var temp = temperature;
        if (temp == null) {
            return null;
        }
        var label = screenLabel(conditionLabel(condition));
        return temp.toString() + "°" + (label.length() > 0 ? " " + label : "");
    }

    //! The label of [conditionLabel], which is the log one, in the watch language (C16.8a).
    function screenLabel(logLabel as String) as String {
        var names = ["sun", "cloudy", "storm", "rain", "snow", "fog", "wind"] as Array<String>; // lang: log
        var ids = [Rez.Strings.WxSun, Rez.Strings.WxCloudy, Rez.Strings.WxStorm, Rez.Strings.WxRain,
            Rez.Strings.WxSnow, Rez.Strings.WxFog, Rez.Strings.WxWind] as Array<ResourceId>;
        var i = names.indexOf(logLabel);
        return i < 0 ? "" : Tr.s(ids[i]);
    }

    //! The same, in ASCII, for the log (`hud clima 24C nublado`): `sim.py ride`
    //! looks for it.
    function logText() as String {
        var temp = temperature;
        if (temp == null) {
            return "hidden";
        }
        var label = conditionLabel(condition);
        return temp.toString() + "C" + (label.length() > 0 ? " " + label : "");
    }
}
