#!/usr/bin/env python3
"""Validate one captured codesign identity report for a local Debug artifact."""

from __future__ import annotations

import argparse
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", help="display label for the signed code object")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    lines = sys.stdin.read().splitlines()
    signatures = [line for line in lines if line.startswith("Signature=")]
    team_identifiers = [line for line in lines if line.startswith("TeamIdentifier=")]

    if signatures != ["Signature=adhoc"] or team_identifiers != ["TeamIdentifier=not set"]:
        print(
            "Debug artifact must have an exact ad-hoc signature with no "
            f"TeamIdentifier: {args.path}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
