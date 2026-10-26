"""One shared helper for the ratchets under scripts/ratchets/ whose count has a baseline file.

A ratchet whose count falls below its baseline writes the lower number into its own baseline file when it
runs directly (docs/contracts/SCOPE-AND-DELIVERY.md, Generated files), so no lane commits a baseline only to
lower it. A gate and the pre-push hook must never get that write, because a changed source file ends a gate
with "source changed during gate". Two things keep their runs read-only. scripts/full-suite-gate.sh exports
LUNGFISH_RATCHET_READ_ONLY=1 to every test it runs, and git sets GIT_DIR for a hook. A baseline is never raised.

Each ratchet ends with `sys.exit(ratchet_baseline.run(main, sys.argv[1:], BASELINE_FILE))`. After a passing
check, run asks the ratchet's own `--update` for the current numbers, into a scratch file, and copies them into
the baseline only when at least one fell and none rose. A run that finds nothing lower changes no byte.
"""
from __future__ import annotations

import contextlib
import io
import os
import tempfile
from pathlib import Path

READ_ONLY_VARIABLE = "LUNGFISH_RATCHET_READ_ONLY"
SKIPPED_FLAGS = ("--update", "--print")


def read_only(environ=None):
    """True in a gate (the variable) and in a git hook (GIT_DIR), where no baseline may be written."""
    environ = os.environ if environ is None else environ
    return environ.get(READ_ONLY_VARIABLE) == "1" or "GIT_DIR" in environ


def numbers(text):
    """The recorded numbers of a baseline text by name. A line that holds only a number is named ''."""
    found = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, _, number = line.rpartition(" ")
        try:
            found[name] = int(number)
        except ValueError:
            continue
    return found


def lowered(before, after):
    """The names whose number fell from `before` to `after`, as {name: (old, new)}. A name that is gone
    counts as fallen to 0. None when `after` would raise a number or add one above 0, which never lands."""
    old, new = numbers(before), numbers(after)
    if any(number > old.get(name, 0) for name, number in new.items()):
        return None
    return {name: (number, new.get(name, 0)) for name, number in old.items() if new.get(name, 0) < number}


def run(main, argv, baseline_file):
    """Run the ratchet's main and return its status. After a pass from a direct run, write the lower
    numbers into baseline_file when a count fell."""
    status = main(argv)
    if status != 0 or read_only() or any(flag in argv for flag in SKIPPED_FLAGS):
        return status
    baseline_file = Path(baseline_file)
    try:
        before = baseline_file.read_text(encoding="utf-8")
    except OSError:
        return status
    scope = main.__globals__
    with tempfile.TemporaryDirectory(prefix="ratchet-baseline-") as scratch:
        target = Path(scratch) / baseline_file.name
        scope["BASELINE_FILE"] = target
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                refreshed = main(["--update"])
        finally:
            scope["BASELINE_FILE"] = baseline_file
        after = target.read_text(encoding="utf-8") if refreshed == 0 and target.exists() else None
    fell = lowered(before, after) if after is not None else None
    if fell:
        baseline_file.write_text(after, encoding="utf-8")
        for name, (old, new) in sorted(fell.items()):
            print(f"{baseline_file.name}: {name or 'the count'} fell from {old} to {new}, so the baseline is lowered. Commit it.")
    return status
