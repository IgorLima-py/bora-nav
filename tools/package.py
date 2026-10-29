#!/usr/bin/env python3
"""Build the files that go into a GitHub Release, in ``dist/``.

- ``Bora-<watch version>-<device>.prg``: the watch app for sideloading over USB (release build), one per
  product of ``watch/manifest.xml``, because a ``.prg`` only installs on the watch it was built for.
- ``Bora-<watch version>.iq``: the same app as a Connect IQ package (``monkeyc -e``).
- ``Bora-<phone version>.apk``: the companion's release APK, zipaligned and signed.

The watch side runs ``monkeyc`` with your Connect IQ developer key (see
``tools/build_watch.py`` for where it is looked up). The phone side does not run
Gradle: build the unsigned APK first, then point this script at your keystore::

    cd companion && ./gradlew assembleRelease
    BORA_KS_PASS=... python tools/package.py --keystore path/to/your.keystore --alias your_alias

Keys and passwords are never copied into ``dist/``. ``--watch-only`` and
``--phone-only`` build one side. ``--scrub-iq FILE.iq`` cleans an ``.iq`` that was already built (see
``scrub_iq``) and fixes its line in the ``SHA256SUMS.txt`` next to it.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_watch  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
GRADLE_APP = ROOT / "companion" / "app" / "build.gradle.kts"
UNSIGNED_APK = ROOT / "companion" / "app" / "build" / "outputs" / "apk" / "release" / "app-release-unsigned.apk"


def phone_version() -> str:
    match = re.search(r'versionName\s*=\s*"([^"]+)"', GRADLE_APP.read_text(encoding="utf-8"))
    if not match:
        sys.exit(f"no versionName in {GRADLE_APP}")
    return match.group(1)


def build_tools() -> Path:
    """The newest Android build-tools folder (it has ``zipalign`` and ``apksigner``)."""
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not sdk and os.name == "nt":
        sdk = str(Path(os.environ["LOCALAPPDATA"]) / "Android" / "Sdk")
    if not sdk:
        sdk = str(Path.home() / "Library" / "Android" / "sdk")
    folders = sorted((Path(sdk) / "build-tools").glob("*"))
    if not folders:
        sys.exit(f"no Android build-tools in {sdk}; set ANDROID_HOME")
    return folders[-1]


def tool(folder: Path, name: str) -> str:
    for candidate in (name + ".bat", name + ".exe", name):
        if (folder / candidate).exists():
            return str(folder / candidate)
    sys.exit(f"{name} not found in {folder}")


def run(command: list[str]) -> None:
    result = subprocess.run(command)
    if result.returncode != 0:
        sys.exit(f"failed ({result.returncode}): {' '.join(command[:2])} ...")


#: Every ``filename="..."`` of the crash-log map inside the ``.iq``.
IQ_FILENAME = re.compile(r'filename="([^"]*)"')
#: What must not be left in the map after the scrub: a ``filename`` that is still absolute, or a user folder anywhere
#: (a URL in a doc comment, ``https://``, is not one: the check looks at the values, not at the whole text).
ABSOLUTE_FILENAME = re.compile(r'[A-Za-z]:[\\/]|[\\/]')
USER_FOLDER = re.compile(r'[A-Za-z]:[\\/]+Users[\\/]|/Users/|/home/|/var/folders/|/private/var/', re.IGNORECASE)


def seven_zip() -> str:
    """A ``bsdtar`` that reads and writes 7z, the ``.iq`` format (Windows 10+ and macOS ship one as ``tar``)."""
    if os.name == "nt":
        system_tar = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "tar.exe"
        if system_tar.is_file():
            return str(system_tar)
    if sys.platform == "darwin":
        return "/usr/bin/tar"
    found = shutil.which("bsdtar")
    if not found:
        sys.exit("no bsdtar to rewrite the .iq (it is a 7z archive); install libarchive-tools")
    return found


def relative_source(path: str) -> str:
    """The source path of the map without the build machine's part: from ``watch/`` on, or from the export's temp
    folder on (``gen/...``, ``manifest.xml``), with the separators the map already used."""
    unified = re.sub(r"[\\/]+", "/", path)
    export = re.search(r"/export\d+/(.*)$", unified)
    if export:
        rest = export.group(1)
    elif "/watch/" in unified:
        rest = unified[unified.rindex("/watch/") + 1:]
    else:
        rest = unified.rsplit("/", 1)[-1]
    separator = "\\\\" if "\\\\" in path else "\\" if "\\" in path else "/"
    return rest.replace("/", separator)


def scrub_iq(iq: Path) -> None:
    """Rewrite the absolute paths in the ``debug.xml`` that ``monkeyc -e`` puts inside the ``.iq``, one per device.

    The map names every source file by its path on the build machine, the user's home folder included,
    and the export's temp folder: the three Releases up to phone-1.4.2-watch-v1.4.2
    carried that (C16.11, 2026-10-28). The map stays, with paths relative to the repository, for the store's crash
    reports. The signed files (the manifest, its signature, the key and each ``.prg``) come out byte for byte the same,
    and that is checked before the ``.iq`` is replaced.
    """
    tar = seven_zip()
    with tempfile.TemporaryDirectory() as scratch:
        unpacked, check = Path(scratch) / "iq", Path(scratch) / "check"
        unpacked.mkdir()
        check.mkdir()
        run([tar, "-xf", str(iq), "-C", str(unpacked)])
        members = sorted(p.relative_to(unpacked).as_posix() for p in unpacked.rglob("*") if p.is_file())
        maps = [m for m in members if m.endswith("debug.xml")]
        for name in maps:
            path = unpacked / name
            text = path.read_bytes().decode("utf-8")
            text = IQ_FILENAME.sub(lambda m: f'filename="{relative_source(m.group(1))}"', text)
            if any(ABSOLUTE_FILENAME.match(v) for v in IQ_FILENAME.findall(text)) or USER_FOLDER.search(text):
                sys.exit(f"{iq.name}: {name} still has an absolute path after the scrub")
            path.write_bytes(text.encode("utf-8"))
        rebuilt = Path(scratch) / iq.name
        run([tar, "--format", "7zip", "--options", "7zip:compression=lzma2", "-cf", str(rebuilt),
             "-C", str(unpacked), *members])
        run([tar, "-xf", str(rebuilt), "-C", str(check)])
        for name in members:
            if name not in maps and (check / name).read_bytes() != (unpacked / name).read_bytes():
                sys.exit(f"{iq.name}: {name} changed in the rewrite")
        shutil.copyfile(rebuilt, iq)
    print(f"{iq.name}: {len(maps)} debug.xml without the build machine's paths")


def fix_sums(iq: Path) -> None:
    """The ``SHA256SUMS.txt`` next to a scrubbed ``.iq`` (a Release's files), with the new hash on its line."""
    sums = iq.with_name("SHA256SUMS.txt")
    if not sums.is_file():
        return
    digest = hashlib.sha256(iq.read_bytes()).hexdigest()
    lines = [f"{digest}  {iq.name}" if line.endswith(f"  {iq.name}") else line
             for line in sums.read_text(encoding="utf-8").splitlines()]
    sums.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def products() -> list[str]:
    """The devices of ``watch/manifest.xml``, in its order."""
    manifest = build_watch.JUNGLE.with_name("manifest.xml").read_text(encoding="utf-8")
    found = re.findall(r'<iq:product id="([^"]+)"\s*/>', manifest)
    if not found:
        sys.exit("no <iq:product> in watch/manifest.xml")
    return found


def watch(out: list[Path]) -> None:
    version = build_watch.app_version()
    common = ["-f", str(build_watch.JUNGLE), "-y", str(build_watch.developer_key()), "-r", "-l", "2"]
    devices = products()
    for i, device in enumerate(devices, 1):
        print(f"[{i}/{len(devices)}] {device}", flush=True)
        prg = DIST / f"Bora-{version}-{device}.prg"
        run([str(build_watch.monkeyc()), *common, "-d", device, "-o", str(prg)])
        out.append(prg)
    iq = DIST / f"Bora-{version}.iq"
    run([str(build_watch.monkeyc()), *common, "-e", "-o", str(iq)])
    # monkeyc leaves its intermediates and the crash-log map next to the output; the map stays in watch/bin
    # builds, not in a release.
    for leftover in ("gen", "mir", "internal-mir"):
        shutil.rmtree(DIST / leftover, ignore_errors=True)
    for debug in DIST.glob("*.debug.xml"):
        debug.unlink()
    scrub_iq(iq)
    out.append(iq)


def phone(out: list[Path], keystore: Path, alias: str) -> None:
    if not UNSIGNED_APK.is_file():
        sys.exit(f"{UNSIGNED_APK} not found: run `./gradlew assembleRelease` in companion/ first")
    if "BORA_KS_PASS" not in os.environ:
        sys.exit("set BORA_KS_PASS to the keystore password")
    folder = build_tools()
    aligned = DIST / "aligned.apk"
    apk = DIST / f"Bora-{phone_version()}.apk"
    run([tool(folder, "zipalign"), "-f", "-p", "4", str(UNSIGNED_APK), str(aligned)])
    run([tool(folder, "apksigner"), "sign", "--ks", str(keystore), "--ks-key-alias", alias,
         "--ks-pass", "env:BORA_KS_PASS", "--out", str(apk), str(aligned)])
    aligned.unlink()
    # The v4 signature file is only for incremental `adb install`; the APK carries v2/v3.
    apk.with_name(apk.name + ".idsig").unlink(missing_ok=True)
    run([tool(folder, "apksigner"), "verify", str(apk)])
    out.append(apk)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keystore", type=Path, help="keystore that signs the APK")
    parser.add_argument("--alias", help="key alias inside the keystore")
    parser.add_argument("--watch-only", action="store_true", help="build only the watch files")
    parser.add_argument("--phone-only", action="store_true", help="sign only the APK")
    parser.add_argument("--scrub-iq", type=Path, nargs="+", metavar="IQ",
                        help="only clean these already built .iq files (and their SHA256SUMS.txt line)")
    args = parser.parse_args()

    if args.scrub_iq:
        for iq in args.scrub_iq:
            scrub_iq(iq)
            fix_sums(iq)
        return 0

    if not args.watch_only and not (args.keystore and args.alias):
        parser.error("--keystore and --alias are needed to sign the APK (or use --watch-only)")

    shutil.rmtree(DIST, ignore_errors=True)
    DIST.mkdir()
    out: list[Path] = []
    if not args.phone_only:
        watch(out)
    if not args.watch_only:
        phone(out, args.keystore, args.alias)

    lines = [f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}" for p in out]
    # newline="\n": on Windows the default turns into CRLF, and `sha256sum -c` on Linux/macOS then fails every line
    # (release phone-1.4.0-watch-v1.4.0, 2026-10-28).
    (DIST / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
