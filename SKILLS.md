# Skills

## GitHub Releases

Any GitHub release that includes a Lungfish app build must attach a signed and
notarized `.dmg` asset. Zip archives are useful for debugging, but they are not
enough for end users because unsigned or unnotarized app bundles are difficult
to run on macOS.

The sole release front door is `python3 scripts/release/release.py`: run
`doctor`, then `package preview|stable`, then `publish preview|stable`. Re-run
`publish` for receipt-bound recovery without rebuilding. Low-level builders are
internal. The full machine, channel, cache, verification, and side-by-side
caveats live in `.codex/skills/releasing-lungfish/SKILL.md` and
`docs/release/sparkle-updates.md`.

## Dependency Sweep

The coordinator requires the reconciled dependency receipt to match the
manifest dependency set and canonical hash, and gates the exact tagged SHA
before publication. Do not manually dispatch CI. The full Stable release event
board remains defense-in-depth after publication. See
`docs/release/dependency-sweep.md` for the semiannual sweep checklist.

## Debug build

<!-- BEGIN LUNGFISH DEBUG FACTS -->
- Wrapper: `build/Debug/Lungfish Debug.app`
- Display name: `Lungfish Genome Explorer Debug`
- Short name: `Lungfish Debug`
- Bundle identifier: `com.lungfish.browser.debug`
- Signature: locally ad-hoc signed
- Distribution: not Developer ID signed; not notarized
- Portability: self-contained and relocatable; no checkout or `.build` dependency
<!-- END LUNGFISH DEBUG FACTS -->

After the unit tier passes, produce the local test wrapper from the feature branch:
`bash scripts/build-app.sh --debug`

Verify it with the compiling `.build` directory:
`scripts/smoke-test-debug-app.sh`

The full operational rules live in the shared skill file.
