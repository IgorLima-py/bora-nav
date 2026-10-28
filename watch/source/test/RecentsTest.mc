import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Test;
import Toybox.WatchUi;

//! **Recents and Settings of the home screen** (C16.5, `05 §RECENTS` and `§NAV_START_REQ`).
//!
//! The `TestVectors` `RECENTS` is `tools/fixtures/recents_00.bin` itself, against which the Kotlin
//! `recentsMatchFixture` compares the packer, and `NAV_START_REQ_RECENT` is
//! `nav_start_req_01.bin`. Public places only. Nothing goes to `Storage`, as in `FavoritesTest`.
(:test)
module RecentsTest {

    // prevents: RECENTS falling into the favorites list (Igor's favorites would vanish at the end of
    // every trip) or being read from the wrong offset and listing garbage in "Recentes".
    (:test)
    function recentsGoToTheirOwnList(logger as Logger) as Boolean {
        var link = new FakeLink();
        var assembler = FavoritesAssert.assembler(link);
        Recents.reset(false);
        assembler.onData(TestVectors.FAVORITES);

        assembler.onData(TestVectors.RECENTS);

        Test.assertMessage(assembler.lastWasFavorites, "not a route: the app does not switch screens");
        Test.assertEqualMessage(link.lastAckType, Protocol.MSG_RECENTS, "ACK of 0x0B");
        Test.assertEqualMessage(Recents.count(), TestVectors.RECENT_COUNT, "how many recents");
        for (var i = 0; i < TestVectors.RECENT_COUNT; i++) {
            Test.assertEqualMessage(Recents.ids[i], TestVectors.RECENT_IDS[i], "id " + i.toString());
            Test.assertEqualMessage(Recents.names[i], TestVectors.RECENT_NAMES[i], "name " + i.toString());
        }
        FavoritesAssert.assertIsTheFixture();
        Test.assertEqualMessage(assembler.chunksReceived, 0, "does not count as a route chunk");

        assembler.onData(TestVectors.RECENTS_TOO_MANY);
        Test.assertEqualMessage(Recents.count(), TestVectors.RECENT_COUNT, "six refuse and the list stays");
        Test.assertMessage(FavoritesAssert.logged("recents refused: more than 5"), "the reason in the log");

        Recents.reset(false);
        FavoritesAssert.done();
        return true;
    }

    // prevents: the phone receiving a request for a recent without the `kind` and routing to the favorite with
    // the same number.
    (:test)
    function recentStartReqMatchesTheFixture(logger as Logger) as Boolean {
        var frame = new PhoneLink().recentStartReqFrame(TestVectors.NAV_START_RECENT_ID);
        var expected = TestVectors.NAV_START_REQ_RECENT;

        Test.assertEqualMessage(frame.size(), expected.size(), "frame size");
        for (var i = 0; i < expected.size(); i++) {
            Test.assertEqualMessage(frame[i], expected[i], "byte " + i.toString());
        }
        return true;
    }

    // prevents: at the 2026-10-17 bench, on the Venu 4, "recentes abre o favoritos, ajustes também" (recents opens favorites, settings too): the
    // `onSelect` (which the touch also fires, and before `onTap`) returned `true` and opened Favoritos.
    // And the new `onKey` must not eat ESC, which leaves the app via the system since C12.
    (:test)
    function homeSelectLeavesTheTapToTheButtons(logger as Logger) as Boolean {
        var delegate = new HomeDelegate(new HomeView());
        Test.assertMessage(!delegate.onSelect(), "onSelect consumed the touch before onTap");
        Test.assertMessage(!delegate.onKey(new FakeKey(WatchUi.KEY_ESC) as WatchUi.KeyEvent),
            "onKey ate the ESC");
        return true;
    }

    // prevents: at the 2026-10-17 bench, "o texto pedindo rota fica cortado" (the route-request text is cut off): "Pedindo rota: " plus the
    // favorite's name went past the glass edge on the home screen's status line. Sheet 1 put the
    // line at y 150, inside the usable circle of radius 200, with the brand dot in front.
    (:test)
    function homeStateLineFitsTheGlass(logger as Logger) as Boolean {
        if (!(Graphics has :createBufferedBitmap)) {
            return true;
        }
        var dc = Graphics.createBufferedBitmap({ :width => 454, :height => 454 }).get().getDc();
        var fonts = [Graphics.FONT_TINY, Graphics.FONT_XTINY] as Array<Graphics.FontType>;
        if (Graphics has :getVectorFont) {
            try {
                fonts = [
                    Graphics.getVectorFont({ :face => "RobotoCondensedRegular", :size => 24 }),
                    Graphics.getVectorFont({ :face => "RobotoCondensedRegular", :size => 23 }),
                ] as Array<Graphics.FontType>;
            } catch (ex) {
                fonts = [Graphics.FONT_TINY, Graphics.FONT_XTINY] as Array<Graphics.FontType>;
            }
        }
        var maxWidth = HomeList.chordAt(150, 200) - 40;
        var texts = ["Tudo pronto", "Cadê o celular?", "Pedindo rota · Casa",
            "Pedindo rota · Mercado Municipal da Cantareira", "O celular não respondeu"] as Array<String>;
        for (var i = 0; i < texts.size(); i++) {
            var line = HomeList.fitState(dc, texts[i] as String, fonts, maxWidth);
            var width = dc.getTextWidthInPixels(line[1] as String, line[0] as Graphics.FontType);
            Test.assertMessage(width <= maxWidth, "\"" + line[1] + "\" has " + width + " px of " + maxWidth);
        }
        var short = HomeList.fitState(dc, "Pedindo rota · Casa", fonts, maxWidth);
        Test.assertEqualMessage(short[1], "Pedindo rota · Casa", "the short name must not be cut");
        return true;
    }

    // prevents: the "Números" (Numbers) step changing only the distance and leaving the arrival big (Igor found the
    // numbers big, 2026-10-17), or "Voltar ao padrão" (Reset to default) touching a setting that is not its own.
    (:test)
    function quickSettingsMoveTheirKeysTogether(logger as Logger) as Boolean {
        Config.reset(false);
        var lead = Config.values[Config.KEY_LEAD_S - 1] as Number;

        Test.assertMessage(QuickSettings.apply(1, 80, false), "80% fits in the band");
        Test.assertEqualMessage(Config.values[Config.KEY_DIST_PCT - 1], 80, "the distance");
        Test.assertEqualMessage(Config.values[Config.KEY_ETA_PCT - 1], 80, "the arrival, together");
        Test.assertMessage(QuickSettings.apply(0, 70, false), "HUD at 70%");
        Test.assertMessage(QuickSettings.apply(2, 160, false), "streets at the ceiling");

        Test.assertMessage(QuickSettings.reset(false), "default");
        for (var row = 0; row < QuickSettings.ROWS; row++) {
            Test.assertEqualMessage(QuickSettings.current(row), 100, "row " + row.toString() + " at the default");
        }
        Test.assertEqualMessage(Config.values[Config.KEY_LEAD_S - 1], lead, "the rest does not move");

        Config.reset(false);
        return true;
    }
}

//! A key for the [HomeDelegate]: the SDK `KeyEvent` cannot be created in a test with the key you want.
(:test)
class FakeKey {
    private var _key as Number;

    function initialize(key as Number) {
        _key = key;
    }

    function getKey() as Number {
        return _key;
    }
}
