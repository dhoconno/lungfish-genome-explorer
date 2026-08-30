# Skills

## GitHub Releases

Any GitHub release that includes a Lungfish app build must attach a signed and
notarized `.dmg` asset. Zip archives are useful for debugging, but they are not
enough for end users because unsigned or unnotarized app bundles are difficult
to run on macOS.

The sole operator front door is exactly:

```text
python3 scripts/release/release.py debug
python3 scripts/release/release.py doctor [--profile PATH]
python3 scripts/release/release.py package preview|stable
python3 scripts/release/release.py publish preview|stable [--profile PATH]
```

Re-run `publish` for receipt-bound recovery without rebuilding. Low-level
builders are internal. The full machine, channel, cache, verification, and
side-by-side caveats live in `.codex/skills/releasing-lungfish/SKILL.md` and
`docs/release/sparkle-updates.md`.

## Dependency Sweep

The coordinator requires the reconciled dependency receipt to match the
manifest dependency set and canonical hash, and gates the exact tagged SHA
before publication. Do not manually dispatch CI. The full Stable release event
board remains defense-in-depth after publication. See
`docs/release/dependency-sweep.md` for the semiannual sweep checklist.

## Debug build

Run only `python3 scripts/release/release.py debug`. It runs the focused
`ReleaseBuildConfigurationTests` static gate, internal Debug assembly, and
relocation/self-containment validation; it does not claim a whole unit-tier run.
The result is the locally ad-hoc-signed, non-notarized
`build/Debug/Lungfish Debug.app`, displaying `Lungfish Genome Explorer Debug`
with bundle name `Lungfish Debug`, identifier `com.lungfish.browser.debug`, and
channel `debug`. It is not Developer ID signed, is not a release, has no updater
or publication path, and is self-contained and relocatable with no checkout or
`.build` dependency.
