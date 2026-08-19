# Continuous Preview Releases

This filename is retained for older links. Lungfish no longer uses alpha or
beta suffixes in app versions. New releases use canonical CalVer
`YYYY.M.PATCH`, while preview status is represented by the Sparkle feed and the
GitHub release state.

The local signing Mac runs the compatibility-named coordinator:

```bash
scripts/release/run-nightly-prerelease.sh
```

It delegates to `scripts/release/nightly_prerelease_release.py`, which captures
the local release date once and chooses the next collision-free patch after
checking both remote Git tags and GitHub releases. For example, after
`v2026.8.2` the next August release is `v2026.8.3`; September begins at
`v2026.9.1`. Release notes live at
`docs/release-notes/<version>.md` without the tag's leading `v`.
The detailed note must be written before the coordinator runs and must identify
the previous release plus a `## Dependency versions` section naming the pinned
dependency set; automation refuses to substitute a generic commit dump.

The coordinator integrates only agent branches explicitly repeated with
`--approved-agent-branch <name>`; discovered but unapproved branches and
worktrees are preserved untouched. It creates rescue archives under
`.build/nightly-release-rescue/<release-tag>/`, runs tests, builds and notarizes
the Apple Silicon DMG, publishes the versioned GitHub preview release, updates
the `sparkle-beta` preview feed and `sparkle-alpha` legacy bridge, verifies the
published artifacts, and only then cleans merged agent worktrees and branches.

The signing machine must provide a Developer ID Application certificate, a
working `notarytool` Keychain profile, the Sparkle private EdDSA key, authenticated
GitHub CLI access, and Sparkle's `generate_appcast` executable. Secrets remain
local and must never be committed or printed in reports.

See `docs/release/sparkle-updates.md` and
`.codex/skills/releasing-lungfish/SKILL.md` for the authoritative release and
version-selection policy.
