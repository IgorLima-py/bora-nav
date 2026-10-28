"""The watch in both languages (C16.8a): checks what the compiler does not.

1. **The catalogs match.** ``watch/resources/strings/strings.xml`` (English, the default) and
   ``watch/resources-por/strings/strings.xml`` (Portuguese) have the same ids, and each text has
   the same ``$1$``, ``$2$`` in both. An id that only exists in the default shows up in English on
   a Portuguese watch; one ``$1$`` fewer drops the number from the screen.
2. **No Portuguese screen text in the code.** Every literal in a ``.mc`` outside
   ``source/test/`` that has an accented letter, "ª", or a word from the list below, is text the
   person sees that does not go through ``strings.xml`` — unless it goes to the log
   (the statement has ``Diag.add``), or the line says ``// lang: log`` or ``// lang: data``,
   or the file says ``//! lang: log file`` in the first 10 lines. The old markers
   ``// idioma: log``, ``// idioma: dado`` and ``//! idioma: arquivo de log`` are still accepted.
   The watch log is now English (it was Portuguese up to v1.4.0); the tools (``sim.py``,
   ``relatorio.py``, ``e2e.py``) read both languages through ``tools/logphrases.py``.

Exits 0 when all is well, 1 with the list of what is missing.

    python tools/idioma.py
"""
from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WATCH = ROOT / "watch"
DEFAULT = WATCH / "resources" / "strings" / "strings.xml"
PORTUGUESE = WATCH / "resources-por" / "strings" / "strings.xml"

#: Screen words that used to be written directly in the ``.mc`` files (survey of 2026-10-28)
#: and have no accent. The accented ones ``ACCENT`` catches on its own.
WORDS = (
    "agora aguardando aparecem ajustes bateria borda brilho cadastre celular chegou chuva curvas "
    "deitado depois desligada desligado destino destinos direita esperando esquerda eventos "
    "favorito favoritos ligada ligado lugar lugares mapa neve nublado pedindo procurando pronto "
    "recebendo recentes resto rota ruas sem siga sol tamanho temporal teste toque tudo vento "
    "faltam nenhum"
).split()
WORD = re.compile(r"\b(" + "|".join(WORDS) + r")\b", re.IGNORECASE)
ACCENT = re.compile(r"[À-ÖØ-öø-ÿª]")
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
PLACEHOLDER = re.compile(r"\$\d+\$")
MARK = re.compile(r"//\s*(?:lang|idioma):\s*(log|data|dado)")
#: A file that only builds log text says so in the first 10 lines (``Telemetry.mc``).
FILE_MARK = re.compile(r"//!?\s*(?:lang:\s*log file|idioma:\s*arquivo de log)")


def catalog(path: Path) -> dict[str, str]:
    """The texts of a ``strings.xml``, by id."""
    root = ET.parse(path).getroot()
    return {s.get("id"): (s.text or "") for s in root.iter("string")}


def check_catalogs(default: Path = DEFAULT, portuguese: Path = PORTUGUESE) -> list[str]:
    if not portuguese.exists():
        return [f"missing the Portuguese catalog: {portuguese.relative_to(ROOT)}"]
    en, pt = catalog(default), catalog(portuguese)
    problems = [f"id only in English: {i}" for i in sorted(en.keys() - pt.keys())]
    problems += [f"id only in Portuguese: {i}" for i in sorted(pt.keys() - en.keys())]
    for i in sorted(en.keys() & pt.keys()):
        a, b = sorted(PLACEHOLDER.findall(en[i])), sorted(PLACEHOLDER.findall(pt[i]))
        if a != b:
            problems.append(f"{i}: English has {a} and Portuguese {b}")
    return problems


def statement(lines: list[str], index: int) -> str:
    """The statement that contains line ``index``: from the lines after the last ``;``, ``{`` or
    ``}`` up to the ``;`` that closes it."""
    start = index
    while start > 0 and not lines[start - 1].split("//")[0].rstrip().endswith((";", "{", "}")):
        start -= 1
    end = index
    while end < len(lines) - 1 and not lines[end].split("//")[0].rstrip().endswith((";", "{", "}")):
        end += 1
    return "\n".join(lines[start:end + 1])


def check_source(text: str, name: str) -> list[str]:
    problems = []
    lines = text.splitlines()
    if any(FILE_MARK.search(line) for line in lines[:10]):
        return problems
    for i, line in enumerate(lines):
        if line.lstrip().startswith(("//", "*")) or MARK.search(line):
            continue
        for match in LITERAL.finditer(line):
            body = match.group(1)
            if not (ACCENT.search(body) or WORD.search(body)):
                continue
            if "Diag.add" in statement(lines, i):
                continue
            problems.append(f"{name}:{i + 1}: \"{body}\"")
    return problems


def sources() -> list[Path]:
    return sorted(p for p in (WATCH / "source").rglob("*.mc") if "test" not in p.relative_to(WATCH).parts)


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    problems = check_catalogs()
    for path in sources():
        problems += check_source(path.read_text(encoding="utf-8"), str(path.relative_to(ROOT)))
    for problem in problems:
        print(f"  {problem}")
    print(f"\n{'ok' if not problems else 'FAILED'} · {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
