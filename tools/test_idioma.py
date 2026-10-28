"""The watch's check in both languages (``idioma.py``, C16.8a), with fake catalogs and fonts.

    python -m unittest tools/test_idioma.py
"""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import idioma  # noqa: E402  (same folder)

HEAD = '<strings xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'


def catalogs(en: str, pt: str) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        a, b = Path(tmp) / "en.xml", Path(tmp) / "pt.xml"
        a.write_text(f"{HEAD}{en}</strings>", encoding="utf-8")
        b.write_text(f"{HEAD}{pt}</strings>", encoding="utf-8")
        return idioma.check_catalogs(a, b)


class CatalogTest(unittest.TestCase):

    def test_matching_catalogs_pass(self):
        self.assertEqual(catalogs('<string id="A">exit $1$</string>', '<string id="A">$1$ª saída</string>'), [])

    # prevents: a new id only in the English strings.xml, and the Portuguese watch showing English (C16.8a)
    def test_id_missing_in_portuguese(self):
        problems = catalogs('<string id="A">a</string><string id="B">b</string>', '<string id="A">a</string>')
        self.assertEqual(problems, ["id only in English: B"])

    # prevents: the "$1$" forgotten in a translation, and the number vanishing from the screen ("faltam" without the distance)
    def test_placeholder_lost(self):
        problems = catalogs('<string id="L">$1$ to go</string>', '<string id="L">faltam</string>')
        self.assertEqual(len(problems), 1)
        self.assertIn("L:", problems[0])


class SourceTest(unittest.TestCase):

    # prevents: a screen text written straight in the .mc, like Hud.mc's "Você chegou" before C16.8a
    def test_screen_literal_is_flagged(self):
        problems = idioma.check_source('        mainText = "Você chegou";\n', "Hud.mc")
        self.assertEqual(problems, ['Hud.mc:1: "Você chegou"'])

    # prevents: failing the log, which the tools (sim.py, relatorio.py) read
    def test_log_statement_passes(self):
        source = '        Diag.add("rota " + id.toString()\n            + " parou de chegar");\n'
        self.assertEqual(idioma.check_source(source, "X.mc"), [])

    # prevents: failing what the line marks as log or data (the "favoritos" key of Storage)
    def test_marked_line_passes(self):
        source = '        store(KEY, parsed, "favoritos"); // lang: log\n'
        self.assertEqual(idioma.check_source(source, "X.mc"), [])

    # prevents: the old markers (// idioma: log, // idioma: dado, //! idioma: arquivo de log) stopping to work
    def test_old_markers_still_pass(self):
        for source in ('        store(KEY, parsed, "favoritos"); // idioma: log\n',
                       '        store(KEY, parsed, "favoritos"); // idioma: dado\n',
                       '        store(KEY, parsed, "favoritos"); // lang: data\n',
                       '//! idioma: arquivo de log\nvar x = "favoritos";\n',
                       '//! lang: log file\nvar x = "favoritos";\n'):
            self.assertEqual(idioma.check_source(source, "X.mc"), [], source)


if __name__ == "__main__":
    unittest.main()
