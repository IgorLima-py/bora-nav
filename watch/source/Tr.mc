import Toybox.Lang;
import Toybox.WatchUi;

//! The on-screen texts in the watch's language (C16.8a). Connect IQ picks the `strings.xml`: the one in
//! `resources-por/` on a Portuguese watch, the one in `resources/` (English) on any other.
//!
//! Each text is loaded once and kept: the HUD asks for its own every frame, and a
//! `loadResource` per frame is a pointless read of the app's memory.
module Tr {

    var _cache as Dictionary<ResourceId, String> = {} as Dictionary<ResourceId, String>;

    //! The id's text, such as `Rez.Strings.Arrived`.
    function s(id as ResourceId) as String {
        var text = _cache[id];
        if (text == null) {
            text = WatchUi.loadResource(id) as String;
            _cache[id] = text;
        }
        return text;
    }

    //! The id's text with the `$1$`, `$2$` replaced by `args`.
    function f(id as ResourceId, args as Array) as String {
        return Lang.format(s(id), args);
    }
}
