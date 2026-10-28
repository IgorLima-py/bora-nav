"""The radar × track crossing of ``relatorio.py`` (C16.7), on a synthetic lap.

    python -m unittest tools/test_relatorio.py

The ``tools/fixtures/log_radares.txt`` fixture is a straight route heading east with four radars: one
passed and alerted, one passed without an alert, one far from the track and one with the bike going the wrong way.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import relatorio  # noqa: E402  (same folder)

FIXTURE = ROOT / "tools" / "fixtures" / "log_radares.txt"


def _data() -> dict:
    return relatorio.parse(FIXTURE.read_text(encoding="utf-8"))


class RadarPassesTest(unittest.TestCase):

    # prevents: C16.7's coverage counting as passed a radar far from the track or going the wrong way, or
    # losing the alert the watch gave (the 26/10 lap did not say which radars the bike passed).
    def test_each_radar_is_passed_or_not_and_alerted_or_not(self):
        passes = {p["osm"]: p for p in _data()["radar"]["passes"]}
        self.assertEqual(sorted(passes), [101, 102], "103 is far away and 104 is the wrong way")
        self.assertTrue(passes[101]["alerted"])
        self.assertEqual(passes[101]["cause"], "vibrated")
        self.assertFalse(passes[102]["alerted"])
        self.assertEqual(passes[102]["cause"], "on the list of route 5, no alert")

    # prevents: one route's alert matching another route's radar just because the `d` is the same.
    def test_an_alert_counts_only_on_its_route(self):
        text = FIXTURE.read_text(encoding="utf-8").replace("rota 5 osm 101", "rota 6 osm 101")
        passes = {p["osm"]: p for p in relatorio.parse(text)["radar"]["passes"]}
        self.assertFalse(passes[101]["alerted"])
        self.assertEqual(passes[101]["cause"], "not on the list of route 5")

    # prevents: `--resumo` (what gets pasted into DECISIONS) coming out without the coverage line (the `sai` 1).
    def test_the_summary_has_the_radar_line(self):
        lines = relatorio.render(_data(), summary=True)
        self.assertIn("radars: 2 passed, 1 alerted · 4 on the lists, 1 alerts on the watch", lines)


if __name__ == "__main__":
    unittest.main()


class BothLanguagesTest(unittest.TestCase):

    # prevents: C16.10b's English log losing the report of the laps: the v1.4.0 on the watch writes
    # Portuguese, the next version writes English, and the report must read both the same way.
    def test_the_english_log_gives_the_same_report_as_the_portuguese(self):
        fixtures = ROOT / "tools" / "fixtures"
        pt = relatorio.parse((fixtures / "log_exemplo.txt").read_text(encoding="utf-8"))
        en = relatorio.parse((fixtures / "log_exemplo_en.txt").read_text(encoding="utf-8"))
        self.assertEqual(relatorio.render(pt, summary=False), relatorio.render(en, summary=False))

    # prevents: a legacy rule of logphrases.py rewriting a line the v1.4.1 apps already write in English.
    def test_the_legacy_table_leaves_an_english_log_alone(self):
        from logphrases import to_english
        english = (ROOT / "tools" / "fixtures" / "log_exemplo_en.txt").read_text(encoding="utf-8")
        self.assertEqual(to_english(english), english)
