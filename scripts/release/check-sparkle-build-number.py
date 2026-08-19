#!/usr/bin/env python3
"""Require a planned CFBundleVersion to exceed every build in a Sparkle appcast."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
import urllib.request
import xml.etree.ElementTree as ET


SPARKLE_VERSION = "{http://www.andymatuschak.org/xml-namespaces/sparkle}version"


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
    if not versions:
        raise BuildNumberError("Sparkle appcast contains no sparkle:version")
    return max(versions)


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
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--appcast", type=Path)
    source.add_argument("--appcast-url")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        planned = positive_integer(args.planned, label="planned Sparkle build")
        current = live_build_number(read_appcast(args.appcast, args.appcast_url))
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
