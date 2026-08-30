# Skills

## GitHub Releases

Any GitHub release that includes a Lungfish app build must attach a signed and
notarized `.dmg` asset. Zip archives are useful for debugging, but they are not
enough for end users because unsigned or unnotarized app bundles are difficult
to run on macOS.

Use `scripts/release/build-notarized-dmg.sh` with the release machine's
Developer ID Application identity and `notarytool` Keychain profile, verify the
result with `stapler validate`, and attach the notarized DMG to the GitHub
release before considering the release complete.

## Dependency Sweep

Before every release, run `scripts/deps/verify.sh` against an isolated storage
root and require its reconciled receipt to match the manifest dependency set
and canonical hash. Preview releases rely on that local evidence plus the
normal push Fast gate; do not manually dispatch CI as part of release. A full
stable GitHub release triggers Build/smoke and Toolset conformance through the
`released` event, and both must pass before the stable release is complete. See
`docs/release/dependency-sweep.md` for the full semiannual sweep checklist.

## Debug Test Builds

A build handed to the user for local testing is produced with
`bash scripts/build-app.sh --debug` after the unit tier passes, yielding
`build/Debug/Lungfish Debug.app` (bundle id `com.lungfish.browser.debug`, display
name "Lungfish Genome Explorer Debug"). It is locally ad-hoc signed, not
Developer ID signed or notarized, never tagged or uploaded, and is built from
the feature branch. It is self-contained after relocation; verify that with
`scripts/smoke-test-debug-app.sh` and the compiling `.build` directory. The full
rules live in the shared
`.codex/skills/releasing-lungfish/SKILL.md` under "Debug Test Builds".
