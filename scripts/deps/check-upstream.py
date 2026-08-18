#!/usr/bin/env python3
"""Command-line entry point for the upstream dependency check.

The importable module lives in ``check_upstream.py`` (underscored, so tests can
import it); this hyphenated wrapper is the name humans and the sweep checklist
invoke.
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from check_upstream import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
