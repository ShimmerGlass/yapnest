#!/usr/bin/env python3
"""Regenerates App/Licences: the licence texts the app shows under
Settings > Open source licences, and the manifest that lists them.

    dev/licences.py [CHECKOUTS_DIR]

CHECKOUTS_DIR holds the Swift packages' checkouts, one folder per package.
It defaults to DerivedData/SourcePackages/checkouts here; to fill it from
scratch:

    xcodebuild -resolvePackageDependencies -scheme Yapnest \
        -derivedDataPath /tmp/yapnest-dd

and pass /tmp/yapnest-dd/SourcePackages/checkouts.

The packages come from the Package.resolved files, so a new dependency is
picked up by running this again. The vendored libraries come from Vendor/,
and Yapnest's own licence from NOTICE, which grants it, and LICENSE.
"""
import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "App" / "Licences"

# Not Swift packages, and so not in any Package.resolved.
VENDORED = [
    # (id, name, directory, licence file, upstream URL)
    ("martin", "Martin", "Martin", "COPYING", "https://github.com/tigase/Martin"),
    ("martinomemo", "MartinOMEMO", "MartinOMEMO", "LICENSE", "https://github.com/tigase/MartinOMEMO"),
]
# Bundled data, with the licence it carries.
BUNDLED = [
    ("gemoji", "gemoji", "Packages/YapnestKit/Sources/YapnestKit/Resources/Emoji/LICENSE-gemoji.txt",
     "https://github.com/github/gemoji", "Emoji shortcode list"),
    ("kenney-interface-sounds", "Interface Sounds", "App/Sounds/LICENSE-CC0.txt",
     "https://kenney.nl/assets/interface-sounds",
     "Notification sounds, by Kenney (kenney.nl), converted to CAF"),
]
LICENCE_FILES = ("LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "COPYING.txt")


def licence_name(text):
    flat = " ".join(text.split())
    # The GPL's own text mentions the AGPL, so only the title counts.
    title = flat[:120].upper()
    if "GNU AFFERO GENERAL PUBLIC LICENSE" in title:
        return "AGPL-3.0"
    if "GNU GENERAL PUBLIC LICENSE" in title:
        return "GPL-3.0" if "VERSION 3" in title else "GPL"
    if "Apache License" in flat and "Version 2.0" in flat:
        return "Apache-2.0"
    if flat.startswith("Creative Commons Legal Code CC0 1.0 Universal"):
        return "CC0-1.0"
    if "Permission is hereby granted, free of charge" in flat:
        return "MIT"
    if "Redistributions in binary form must reproduce" in flat and "Neither the name" in flat:
        return "BSD-3-Clause"
    sys.exit("Unrecognised licence text; teach licence_name() about it.")


def vendored_version(name):
    """The commit or release our copy is based on, from Vendor/README.md."""
    for line in (ROOT / "Vendor" / "README.md").read_text().splitlines():
        cells = [c.strip() for c in line.split("|")]
        if len(cells) > 3 and cells[1] == name:
            sha = re.search(r"`([0-9a-f]{40})`", cells[3])
            release = re.search(r"\((\d+\.\d+(?:\.\d+)?)[,)]", cells[3])
            if release:
                return release.group(1)
            if sha:
                return sha.group(1)[:7]
    sys.exit(f"{name} isn't in Vendor/README.md's table.")


def binary_licence(checkouts, id):
    """A binary target's licence, from the xcframework SwiftPM downloaded.
    The package's own checkout holds only the manifest that points at it, and
    a licence of the wrapper's, not the library's."""
    found = sorted((checkouts.parent / "artifacts" / id).glob("*/*.xcframework/LICENSE*"))
    return found[0] if found else None


def find_licence(directory):
    for name in LICENCE_FILES:
        if (directory / name).is_file():
            return directory / name
    sys.exit(f"No licence file in {directory}")


def main():
    checkouts = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "DerivedData" / "SourcePackages" / "checkouts"
    if not checkouts.is_dir():
        sys.exit(f"{checkouts} doesn't exist; see the top of this script.")
    by_dir = {p.name.lower(): p for p in checkouts.iterdir() if p.is_dir()}

    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    entries = []

    def add(id, name, version, source, url, modified, note=None):
        text = source.read_text()
        file = f"{id}.txt"
        (OUT / file).write_text(text if text.endswith("\n") else text + "\n")
        entry = {"id": id, "name": name, "version": version, "license": licence_name(text),
                 "url": url, "file": file, "modified": modified}
        if note:
            entry["note"] = note
        entries.append(entry)

    seen = set()
    for resolved in sorted(ROOT.glob("Packages/*/Package.resolved")) + sorted(ROOT.glob("Vendor/*/Package.resolved")):
        for pin in json.loads(resolved.read_text())["pins"]:
            id = pin["identity"]
            if id in seen:
                continue
            seen.add(id)
            url = pin["location"].removesuffix(".git")
            directory = by_dir.get(url.rsplit("/", 1)[-1].lower())
            if directory is None:
                sys.exit(f"No checkout of {id} in {checkouts}; resolve the packages first.")
            name = url.rsplit("/", 1)[-1].removesuffix(".swift")
            add(id, name, pin["state"].get("version") or pin["state"]["revision"][:7],
                binary_licence(checkouts, id) or find_licence(directory), url, False)

    for id, name, directory, file, url in VENDORED:
        add(id, name, vendored_version(name), ROOT / "Vendor" / directory / file, url, True)
    for id, name, path, url, note in BUNDLED:
        add(id, name, "", ROOT / path, url, False, note)

    entries.sort(key=lambda e: e["name"].lower())
    notice, licence = (ROOT / "NOTICE").read_text(), (ROOT / "LICENSE").read_text()
    (OUT / "yapnest.txt").write_text(notice + "\n" + licence)
    # NOTICE says which versions; LICENSE is only the text of the first.
    later = "any later version" in " ".join(notice.split())
    manifest = {"yapnest": {"license": licence_name(licence) + ("-or-later" if later else ""), "file": "yapnest.txt"}, "libraries": entries}
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Wrote {len(entries)} libraries to {OUT.relative_to(ROOT)}")


main()
