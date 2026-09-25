#!/usr/bin/env python3
"""Add ebuilds for new package versions in the UHH qpilot APT repository.

Reads the repository's Packages index and, for each tracked package whose
version has no ebuild yet, copies the newest ebuild to the new version and
adds the .deb to the package's Manifest. For example, ta-utax-dialog 9.5-0 in
the index yields net-print/ta-utax-dialog/ta-utax-dialog-9.5.ebuild.

Prints one line per added ebuild ("net-print/qpilot-client 5.3.0.1") and
exits non-zero when a version cannot be added (checksum or file name mismatch).
"""

import argparse
import hashlib
import re
import shutil
import sys
import urllib.request
from pathlib import Path

MIRROR = "https://apt-mirror.rrz.uni-hamburg.de/uhh-qpilot/ubuntu"
INDEX = MIRROR + "/dists/noble/multiverse/binary-amd64/Packages"

# Debian package name -> (overlay package, .deb name the ebuild's SRC_URI
# builds for Debian version {v})
TRACKED = {
    "qpilot-client": ("net-print/qpilot-client", "qpilot-{v}-amd64.deb"),
    "ta-utax-dialog": ("net-print/ta-utax-dialog", "ta-utax-dialog-{v}-amd64.deb"),
}

REPO = Path(__file__).resolve().parent.parent


def parse_index(text):
    """Packages index text -> list of stanza dicts."""
    stanzas = []
    for block in text.strip().split("\n\n"):
        fields = {}
        for line in block.splitlines():
            if ":" in line and not line.startswith(" "):
                key, value = line.split(":", 1)
                fields[key] = value.strip()
        stanzas.append(fields)
    return stanzas


def deb_to_pv(version):
    """Debian version -> ebuild PV: '9.4-0' -> '9.4', '9.4-1' -> '9.4_p1'."""
    upstream, _, revision = version.partition("-")
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)*", upstream):
        raise ValueError(f"cannot map Debian version {version!r} to a PV")
    if revision in ("", "0"):
        return upstream
    if not revision.isdigit():
        raise ValueError(f"cannot map Debian revision {revision!r} to a PV")
    return f"{upstream}_p{revision}"


def version_key(pvr):
    """'9.4_p1-r2' -> ((9, 4), 1, 2) for picking the newest ebuild."""
    pv, _, rev = pvr.partition("-r")
    upstream, _, patch = pv.partition("_p")
    return tuple(int(x) for x in upstream.split(".")), int(patch or 0), int(rev or 0)


def fetch(url, dest=None):
    with urllib.request.urlopen(url, timeout=120) as resp:
        if dest is None:
            return resp.read()
        with open(dest, "wb") as out:
            shutil.copyfileobj(resp, out)
    return None


def manifest_line(path):
    """DIST line for a Gentoo Manifest, with BLAKE2B and SHA512."""
    blake, sha512 = hashlib.blake2b(), hashlib.sha512()
    size = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            blake.update(chunk)
            sha512.update(chunk)
            size += len(chunk)
    return (f"DIST {path.name} {size} BLAKE2B {blake.hexdigest()} "
            f"SHA512 {sha512.hexdigest()}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--index", help="read this Packages file instead of the mirror")
    ap.add_argument("--distdir", default="/tmp/uhh-qpilot-distfiles",
                    help="where to download .debs (default: %(default)s)")
    args = ap.parse_args()

    text = Path(args.index).read_text() if args.index else fetch(INDEX).decode()
    distdir = Path(args.distdir)
    distdir.mkdir(parents=True, exist_ok=True)

    failed = False
    seen = set()
    for st in parse_index(text):
        name = st.get("Package")
        if name not in TRACKED or st.get("Architecture") != "amd64":
            continue
        pv = deb_to_pv(st["Version"])
        if (name, pv) in seen:
            continue
        seen.add((name, pv))

        atom, deb_name = TRACKED[name]
        pkgdir = REPO / atom
        pn = pkgdir.name
        target = pkgdir / f"{pn}-{pv}.ebuild"
        if target.exists() or any(pkgdir.glob(f"{pn}-{pv}-r*.ebuild")):
            continue
        ebuilds = sorted(pkgdir.glob(f"{pn}-*.ebuild"),
                         key=lambda p: version_key(p.stem[len(pn) + 1:]))
        if not ebuilds:
            print(f"error: no ebuild to copy in {pkgdir}", file=sys.stderr)
            failed = True
            continue

        deb = distdir / Path(st["Filename"]).name
        if deb.name != deb_name.format(v=st["Version"]):
            print(f"error: {deb.name} does not match the ebuild's SRC_URI pattern "
                  f"{deb_name}", file=sys.stderr)
            failed = True
            continue
        try:
            fetch(f"{MIRROR}/{st['Filename']}", deb)
        except OSError as e:
            print(f"error: downloading {deb.name}: {e}", file=sys.stderr)
            failed = True
            continue
        if hashlib.sha256(deb.read_bytes()).hexdigest() != st["SHA256"]:
            print(f"error: SHA256 mismatch for {deb.name}", file=sys.stderr)
            failed = True
            continue

        shutil.copy(ebuilds[-1], target)
        manifest = pkgdir / "Manifest"
        lines = manifest.read_text().splitlines() if manifest.exists() else []
        lines = sorted({*lines, manifest_line(deb)})
        manifest.write_text("\n".join(lines) + "\n")
        print(f"{atom} {pv}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
