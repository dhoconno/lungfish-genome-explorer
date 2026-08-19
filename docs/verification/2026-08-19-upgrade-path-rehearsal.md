# Upgrade path rehearsal on a real installed root (2026-08-19)

Status: PASS, with one product fix required and made (Bracken preservation) and one
reporting fix made (gate summary totals).

The fresh-install path was already verified. This exercised the case that had never
been run end to end: an existing, pre-2026.1 install with no receipt, 57 conda
environments including hand-made ones, and a tool built from source.

## Method

The developer's real `~/.lungfish` (46 GB, no receipt, 57 envs) was APFS-cloned to
`/tmp` with `/bin/cp -Rc`, which costs no additional disk. Clone `conda/{bin,envs,cache}`
individually: a wholesale clone of `conda/` fails on the setgid bit under `pkgs/cache`.
Every command below ran against the clone. The real root was confirmed unmodified
afterwards.

## Results

### Plan

23 environment reinstalls, 3 database updates, 1 micromamba bootstrap, 3.62 GB.

`removeEnvironments` was empty. None of the 21 environments that are not manifest ids
(`pbaa-env`, `test-env`, `freyja-env`, `metaphlan`, `picard`, `raxml-ng`, `treetime`,
`trimmomatic`, and others) were proposed for removal. This is the conservative removal
policy demonstrated against a real cluttered root rather than a synthetic fixture.

### Apply

All 24 items completed with no errors. The re-plan afterwards reported Zero KB with
every environment reinstall gone, and `dependency-receipt.json` was written at 2026.2
with 51 environments, all in the `installed` state. The three advisory database rows
remain by design and do not block.

Note for anyone repeating this: the receipt is written incrementally so a resumed apply
can pick up where it stopped, so the presence of the file does not mean the apply
finished. Wait for the process to exit before planning again.

### Tier 1 conformance

189 XCTest tests, 0 failures, 0 skips in require mode, plus 3 swift-testing suites,
run against the upgraded clone.

### GUI

Against the upgraded root the sheet reads "These updates are optional. You can run them
now or later from the Plugin Manager", the dismiss button reads "Later" rather than
"Quit", and the estimate is "about Zero KB". This is the complement of the fresh-root
case recorded in `docs/verification/2026-08-18-update-tools-sheet.md`, so both branches
of the required-work gate are now verified on screen.

## Bracken: a real regression, found and fixed

Applying to the clone replaced a source-built Bracken v3.0.1 with the pinned
`bioconda::bracken=1.0.0=1`. The bin directory went from 294 files to 120 and
`bracken -v` stopped reporting a version, printing `est_abundance.py` usage instead,
because the bioconda arm64 build ships no driver and Lungfish synthesizes a passthrough
launcher for it.

Cause: the environment has no conda-meta record for the `bracken` package, because it
was not installed by conda. `DependencyPlanner.reinstallReason` therefore returns
`.metadataMismatch` and the environment is rebuilt from the pin. This affects any user
with a source-built Bracken, not one machine.

Scope check before fixing: every `tools` and `packTools` entry was scanned against the
real root, and bracken is the only entry with this metadata gap. The planner semantics
were therefore left alone for every other tool, and the fix is an opt-in per-entry
manifest flag, `preserveExistingInstall`, set on bracken alone.

After the fix, planning against a fresh clone of the real root emits a `preserve` line
instead of a reinstall, and applying leaves Bracken v3.0.1 in place with its 294 bin
files. A user who wants the pinned build removes the `bracken` environment and
reinstalls the pack, which the advisory line states.

## The preserve flag collided with a conformance test

Preserving Bracken made `ToolVersionConformanceTests.testEveryInstalledPackToolReportsPinnedVersion`
fail: bracken is on that test's `selfReportedVersionIsUnreliable` list precisely because
it cannot report its own version, so conda-meta was the fallback authority, and a
preserved install has neither.

The first attempt recorded it as drift, which turns the test into a skip. That is also
wrong: tier 1 forbids skipped conformance tests, so the gate would still have failed,
just with a less obvious message. The check now asserts what is actually verifiable for
a preserved install, namely that every declared executable is present and executable.
Verified both ways: the preserved root passes with zero skips, and hiding
`bracken-build` fails the test with the missing executable named.

Sequence worth remembering for the next sweep: a change to reconciliation semantics is
not finished when the planner does the right thing. Tier 1 is what proves the rest of
the system agrees.

## Gate summary reporting

`scripts/full-suite-gate.sh` printed "GATE PASS - Executed 2 tests" for the 189-test
tier 1 run, because it grepped the first `Executed N tests` line, which belongs to an
early sub-suite, rather than XCTest's grand total. A pass therefore looked like a filter
that had matched almost nothing. Fixed to take the last line and to include the
swift-testing total.

## Full suite after the fixes

13457 XCTest executed, 35 skipped, 3 failures, plus 7 swift-testing issues.

All of them are known environmental, not regressions from this work:

- `FileSystemWatcherTests` (7 swift-testing issues): FSEvents callbacks never fire in
  the full swift-testing phase on this machine. Fails the same way on main.
- `AssemblyConformanceTests.testMegahitProducesFinalContigs` (3 assertions, one test):
  MEGAHIT 1.2.9 exited 245 with no contigs. The same test passed in both tier 1 gates
  the same day and passes in isolation in under a second. MEGAHIT 1.2.9 on arm64 is
  already documented as load sensitive in this file's own test comment, which caps the
  invocation at two threads because four segfaults. This run was under heavy load from
  a parallel apply.

None of the commits in this range touch assembly code: the diff is confined to the
dependency planner, the manifest, two test files, the gate script, and docs.
