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

Before any release, confirm a green `toolset-conformance` CI run exists for
the manifest hash. The companion check that the manifest's `dependencySet`
matches the receipt from `scripts/deps/verify.sh` is pending Plan C: that
script does not exist yet, so a release today is not blocked on it. See
`docs/release/dependency-sweep.md` for the full semiannual sweep checklist.
