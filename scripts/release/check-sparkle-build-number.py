#!/usr/bin/env python3
"""Require a planned CFBundleVersion to exceed every build in a Sparkle appcast.

The floor is the highest ``sparkle:version`` in the feed, including builds
that ``release.py yank`` withdrew. A yank removes the item but leaves an
``<lge:yanked build="N">`` marker in the channel, so the next publish must
still exceed the yanked build.

Recovery. A publish that fails after the Sparkle feed took the candidate's
build is rerun with the same command, and the feed then already lists the
planned build. The coordinator names the candidate through two environment
variables, ``LUNGFISH_SPARKLE_RECOVERY_VERSION`` and
``LUNGFISH_SPARKLE_RECOVERY_ENCLOSURE_URL``. The builder's own floors read the
same variables, since release.py cannot give them arguments. With both set, a
live build equal to the planned one passes only when every live item at that
build is this candidate's: its ``sparkle:shortVersionString`` and its enclosure
URL equal the named ones and no yank marker holds the build. A lower planned
build, a higher live build and any other item at the planned build still fail.
With neither variable set the floor is the strict one, and with only one set
the gate fails.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


SPARKLE_VERSION = "{http://www.andymatuschak.org/xml-namespaces/sparkle}version"
SPARKLE_SHORT_VERSION = (
    "{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString"
)
# Keep in sync with sparkle_yank.LGE_RELEASE_NS / YANK_MARKER_TAG.
YANK_MARKER = "{urn:lungfish-genome-explorer:release}yanked"
# Keep in sync with release.py SPARKLE_RECOVERY_VERSION_ENV / _ENCLOSURE_ENV.
RECOVERY_VERSION_ENV = "LUNGFISH_SPARKLE_RECOVERY_VERSION"
RECOVERY_ENCLOSURE_ENV = "LUNGFISH_SPARKLE_RECOVERY_ENCLOSURE_URL"


class BuildNumberError(RuntimeError):
    pass


def positive_integer(value: str, *, label: str) -> int:
    if not value.isdigit() or int(value) < 1:
        raise BuildNumberError(f"{label} must be a positive integer: {value}")
    return int(value)


def live_build_number(appcast: bytes) -> int:
    root = ET.fromstring(appcast)
    versions = [
        positive_integer((element.text or "").strip(), label="Sparkle appcast version")
        for element in root.iter(SPARKLE_VERSION)
    ]
    versions.extend(
        positive_integer(element.get("build", "").strip(), label="Sparkle yank marker build")
        for element in root.iter(YANK_MARKER)
    )
    if not versions:
        raise BuildNumberError("Sparkle appcast contains no sparkle:version")
    return max(versions)


def recovery_candidate() -> tuple[str, str] | None:
    """The candidate's version and enclosure URL, or None outside recovery."""
    version = os.environ.get(RECOVERY_VERSION_ENV, "").strip()
    enclosure = os.environ.get(RECOVERY_ENCLOSURE_ENV, "").strip()
    if not version and not enclosure:
        return None
    if not version or not enclosure:
        raise BuildNumberError(
            f"recovery needs both {RECOVERY_VERSION_ENV} and {RECOVERY_ENCLOSURE_ENV}"
        )
    return version, enclosure


def other_than_candidate(
    appcast: bytes, planned: int, candidate: tuple[str, str]
) -> str | None:
    """Why the live feed holds the planned build for another release.

    Returns None when every live item at the planned build is the candidate's.
    """
    root = ET.fromstring(appcast)
    for marker in root.iter(YANK_MARKER):
        yanked = positive_integer(
            marker.get("build", "").strip(), label="Sparkle yank marker build"
        )
        if yanked == planned:
            return f"build {planned} was yanked"
    found = []
    for item in root.iter("item"):
        text = (item.findtext(SPARKLE_VERSION) or "").strip()
        if not text:
            continue
        if positive_integer(text, label="Sparkle appcast version") != planned:
            continue
        enclosure = item.find("enclosure")
        found.append(
            (
                (item.findtext(SPARKLE_SHORT_VERSION) or "").strip(),
                "" if enclosure is None else enclosure.get("url", "").strip(),
            )
        )
    if not found:
        return f"no live item lists build {planned}"
    for version, url in found:
        if (version, url) != candidate:
            return (
                f"the item at build {planned} is version {version or 'unknown'} with "
                f"enclosure {url or 'none'}, and the candidate is version {candidate[0]} "
                f"with enclosure {candidate[1]}"
            )
    return None


def read_appcast(path: Path | None, url: str | None) -> bytes:
    if path is not None:
        return path.read_bytes()
    assert url is not None
    request = urllib.request.Request(url, headers={"User-Agent": "Lungfish release preflight"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--planned", required=True)
    parser.add_argument(
        "--allow-http-not-found",
        action="store_true",
        help="Treat an HTTP 404 as an appcast that has not been initialized yet",
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--appcast", type=Path)
    source.add_argument("--appcast-url")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        planned = positive_integer(args.planned, label="planned Sparkle build")
        candidate = recovery_candidate()
        try:
            appcast = read_appcast(args.appcast, args.appcast_url)
        except urllib.error.HTTPError as exc:
            if args.allow_http_not_found and exc.code == 404:
                print(
                    "Sparkle build-number gate passed: no existing appcast at "
                    f"{args.appcast_url}"
                )
                return 0
            raise
        current = live_build_number(appcast)
        if planned == current and candidate is not None:
            reason = other_than_candidate(appcast, planned, candidate)
            if reason is not None:
                raise BuildNumberError(
                    f"planned Sparkle build {planned} must exceed live Sparkle build "
                    f"{current} (recovery: the live item is not this candidate, {reason})"
                )
            print(
                "Sparkle build-number gate passed in recovery: the live appcast "
                f"already lists build {planned} of version {candidate[0]}"
            )
            return 0
        if planned <= current:
            raise BuildNumberError(
                f"planned Sparkle build {planned} must exceed live Sparkle build {current}"
            )
    except (BuildNumberError, ET.ParseError, OSError) as exc:
        print(f"Sparkle build-number gate failed: {exc}", file=sys.stderr)
        return 64
    print(f"Sparkle build-number gate passed: {planned} > {current}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
