import Toybox.Lang;
import Toybox.Test;

//! The HUD weather (C9, RF-10): the block disappears without error when there is no data, and the
//! text comes out with temperature and condition when there is.
//!
//! The `WeatherInfo` state is global (module): each test clears it before and after.

//! Without a temperature, with a temperature out of range or with only the condition, the block
//! disappears: `hudText` is `null` and the HUD adds nothing to the time line.
(:test)
function unavailableWeatherHidesTheBlock(logger as Logger) as Boolean {
    WeatherInfo.clear();
    var hud = new Hud();

    Test.assertMessage(WeatherInfo.hudText() == null, "no reading at all: hidden");
    Test.assertEqualMessage(hud.weatherSuffix(), "", "the HUD reserves no space without weather");

    WeatherInfo.set(null, 3);
    Test.assertMessage(WeatherInfo.hudText() == null, "condition only, no temperature: hidden");

    WeatherInfo.set(250, 0);
    Test.assertMessage(WeatherInfo.hudText() == null, "temperature out of range: hidden");
    WeatherInfo.set(-90, 0);
    Test.assertMessage(WeatherInfo.hudText() == null, "below the range: hidden");

    WeatherInfo.clear();
    return true;
}

//! With data, the text carries the rounded temperature and the short condition name.
(:test)
function availableWeatherShowsTemperatureAndCondition(logger as Logger) as Boolean {
    WeatherInfo.clear();

    WeatherInfo.set(23.6, 2);
    var text = WeatherInfo.hudText();
    Test.assertMessage(text != null, "with data, the block shows");
    Test.assertEqualMessage(text, "24° nublado", "23.6 rounds to 24, condition 2 = cloudy");
    Test.assertEqualMessage(WeatherInfo.logText(), "24C cloudy", "the log is ASCII");
    Test.assertEqualMessage(new Hud().weatherSuffix(), " · 24° nublado", "the time line gets the weather");

    WeatherInfo.set(-3, 53);
    Test.assertEqualMessage(WeatherInfo.hudText(), "-3°", "unknown condition: temperature only");

    WeatherInfo.set(18, 14);
    Test.assertEqualMessage(WeatherInfo.conditionLabel(14), "rain", "LIGHT_RAIN");
    Test.assertEqualMessage(WeatherInfo.conditionLabel(6), "storm", "THUNDERSTORMS");
    Test.assertEqualMessage(WeatherInfo.conditionLabel(null), "", "no condition");

    WeatherInfo.clear();
    return true;
}

//! The system reading never throws, whether or not there is a cache (in the simulator and on a
//! device with no paired phone the cache comes back empty). Whatever comes out is valid: either the block
//! disappears, or it brings a temperature within range.
(:test)
function readingTheSystemCacheNeverThrows(logger as Logger) as Boolean {
    WeatherInfo.clear();
    WeatherInfo.readNow();
    var temp = WeatherInfo.temperature;
    if (temp != null) {
        Test.assertMessage(temp >= WeatherInfo.MIN_C && temp <= WeatherInfo.MAX_C, "temperature within range");
    }
    logger.debug("system cache: " + WeatherInfo.logText());

    // The value injected by the virtual ride is not overwritten by the reading.
    WeatherInfo.inject(24, 1);
    WeatherInfo.readNow();
    Test.assertEqualMessage(WeatherInfo.temperature, 24, "the injected one beats the reading");

    WeatherInfo.clear();
    return true;
}
