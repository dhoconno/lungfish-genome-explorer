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
