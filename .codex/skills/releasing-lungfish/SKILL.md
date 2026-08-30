---
name: releasing-lungfish
description: Use when asked to prepare, publish, recover, promote, or validate a Lungfish macOS release, DMG, GitHub release, or Sparkle preview/stable update.
---

# Releasing Lungfish

Produce a reproducible release from current `main`. Treat a missing provenance, signature, notarization, or verification result as a blocking defect.

## Channels and Release History

Use one suffix-free `YYYY.M.PATCH` version line across preview and stable builds. Select the channel explicitly when invoking the builder:

- `--channel preview` publishes a GitHub prerelease whose app polls `appcast-beta.xml` at `sparkle-beta`. Its signed bundle must use `CFBundleDisplayName` `Lungfish Genome Explorer Preview`, `CFBundleName` `Lungfish Preview`, and `LungfishReleaseChannel` `preview`. It may also update the `sparkle-alpha` legacy bridge and prune old preview release records. Preview is publicly downloadable and must carry this exact caveat in release notes and the About window: “Preview builds are under rapid iterative development. Features may be incomplete, change quickly, or require additional feedback.”
- `--channel stable` publishes a full GitHub release whose app polls `appcast-stable.xml` at `sparkle-stable`. Its signed bundle must use `CFBundleDisplayName` `Lungfish Genome Explorer`, `CFBundleName` `Lungfish`, and `LungfishReleaseChannel` `stable`. It does not relabel or reuse a preview DMG; the feed URL and identity are baked into the signed app.

Explicit appcast flags override channel defaults and are for deliberate recovery or migration only. Channel state belongs to the baked Sparkle feed, the GitHub prerelease flag, and visible bundle metadata, never the version or tag. Both channels use the literal `Lungfish.app` wrapper and bundle identifier, so manually installing one channel's DMG replaces the other; there is no side-by-side installation or in-app channel toggle.

Every `docs/release-notes/<version>.md` starts with these audit fields:

- `Channel:` Preview or Stable.
- `Previous versioned release:` the latest immutable versioned release of either channel.
- `Stable baseline:` the latest full versioned GitHub release, or `None` before the first stable release.
- `Dependency set:` the bundled manifest set.

Preview notes describe the delta from the previous versioned release. Stable notes are aggregate notes: compare the latest full versioned GitHub release tag to `HEAD`, read every intervening committed versioned note, and reconcile both against the Git diff. Before the first stable release, use the explicitly recorded bootstrap aggregation baseline (currently `v0.5.0-beta29`), never the repository root. Include `## Included preview releases` listing the intervening preview versions. Aggregate and deduplicate user-visible workflows, correctness/stability, scientific provenance, storage/migrations, dependency and database pins, platform/toolchain compatibility, updater/release infrastructure, and known issues. Git tags, GitHub release state, and committed per-version notes are the ledger; do not create a second mutable channel/version registry.

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

This local test profile is NOT a release and must never receive a tag, upload, Sparkle publication, or GitHub release attachment. Produce one whenever the user asks to "try", "test", or "smoke" a fix before release, and do it from the feature branch, not `main`.

1. Run the unit tier first: `bash scripts/full-suite-gate.sh --tier unit` must print PASS (serialize it with any other `swift` invocation; SwiftPM holds one `.build/.lock` per checkout).
2. Build the wrapper with the following command (add `--skip-build` only when the exact commit is already compiled):
   `bash scripts/build-app.sh --debug`
3. The result uses the exact identity in the facts block and registers separately from the installed release copy. Computer Use, screen-capture, and Accessibility grants for the release app do not cover it; request them for the local test bundle identifier explicitly.
4. Launch it for the user:
   `open "build/Debug/Lungfish Debug.app"`
   Run the executable directly when `LUNGFISH_*` environment overrides are needed:
   `build/Debug/Lungfish\ Debug.app/Contents/MacOS/Lungfish`
   Never point `LUNGFISH_STORAGE_ROOT` at the real `~/.lungfish` in a throwaway smoke run.
5. Report the commit hash, branch, absolute `.app` path, unit-tier PASS line, and the exact signature/distribution facts above.
6. Prove relocation, packaged resources, signature identity, and checkout independence:
   `bash scripts/smoke-test-debug-app.sh "build/Debug/Lungfish Debug.app" --compiling-build-dir "$PWD/.build"`

Do not reuse `build/Release/` or `build-notarized-dmg.sh` for this profile, and do not delete its wrapper when cleaning up a release run unless the user asks.

## Load Current Authority

Before acting, read all of:

- `bash scripts/release/build-notarized-dmg.sh --help`
- `docs/release/sparkle-updates.md`
- `.codex/agents/release-agent.md`
- `SKILLS.md`
- relevant files under `scripts/tests/`

Run `<skill-root>/scripts/validate.py --repo-root "$PWD"`. If repository interfaces drifted, update the skill or stop; never guess obsolete flags.

## Choose Reasoning Strength

- Use a balanced model for read-only inventory and mechanical checks.
- Use the strongest available coding/reasoning model at high effort for branch classification, merge conflict resolution, release-delta analysis, narrative notes, publication recovery, cleanup decisions, and the final audit.
- Keep pushes, tags, releases, feed mutations, and deletion of branches/worktrees under the root agent.
- If model switching is unavailable, use the strongest active model and add an independent verification pass.

## Release Gates

1. Fetch `origin` and tags. Inventory every worktree, branch, and dirty path. Classify each as release work, already merged, unrelated active work, or unresolved. Preserve unrelated work. Any dirty or ambiguous item blocks deletion. When using the coordinator, pass `--approved-agent-branch` once for each branch explicitly classified as release work; unlisted agent branches are not integrated or cleaned.
2. Integrate approved release work into a clean checkout of current `origin/main`. Test, commit, and push `main`; do not publish from a feature branch or silently discard changes.
3. Name every new release with canonical CalVer `YYYY.M.PATCH`, such as `2026.8.1`; never add alpha, beta, preview, stable, or other channel suffixes. Capture the release machine's local calendar date once for the run. Set `YYYY` and `M` from that date without leading zeroes. Set `PATCH` to one more than the highest positive patch for that year and month across both remote Git tags and GitHub releases; start at `1` when the month has none. Ignore mutable `sparkle-beta`, `sparkle-alpha`, and `sparkle-stable` feed tags and all legacy-version tags when computing the counter. When resuming preparation, exclude the planned/current version itself from baseline selection. Fail if an existing CalVer release is future-dated relative to the captured month. A user-supplied version must be canonical, match the captured year/month, and be collision-free. Use tag `v<version>` and release notes `docs/release-notes/<version>.md`. Recheck Git tags and GitHub releases immediately before tagging and publication. Recompute after a concurrent collision; never overwrite a tag or versioned release.
4. Determine both baselines before writing notes. The previous versioned release is the latest immutable versioned tag/release of either channel. The stable baseline is the latest full versioned GitHub release; exclude drafts and mutable `sparkle-*` feed containers. Harmonize every visible app/CLI/version declaration. Write the channel-appropriate notes and audit fields above, with a detailed narrative and complete pinned dependency versions. Verify every claim against commits and changed files.
5. Run the channel's test tiers with `scripts/full-suite-gate.sh` (tier definitions live in that script; the opt-in pre-push hook covers only the unit tier, so releases must run their tiers explicitly). For a preview release, run the focused release tests plus `bash scripts/full-suite-gate.sh --tier unit` and `bash scripts/full-suite-gate.sh --tier integration`; a preview may ship without the conformance and full tiers. For a stable release, run the focused release tests plus `bash scripts/full-suite-gate.sh --tier full` and `bash scripts/full-suite-gate.sh --tier conformance --require-tools`. The XCUI suite (`bash scripts/testing/run-macos-xcui.sh`) is an attended diagnostic, not a release gate: macOS binds its automation permission to each rebuilt runner binary and may re-prompt, so it can block unattended runs indefinitely; run it on demand when investigating UI problems, with an operator present to answer the prompt. Read each verdict from the gate's PASS/FAIL line, never from the console tail alone. For both channels, also run `git diff --check`, old-version scans, and the skill validator. Before tagging, preflight `gh auth`, Developer ID identity and Team ID agreement, the notarytool profile, the Sparkle generator, and signing-key access. Parse the selected channel's live appcast and require the planned `CFBundleVersion` (`LUNGFISH_BUILD_NUMBER` or `git rev-list --count HEAD`) to exceed its `sparkle:version`.
6. Run the dependency verification procedure in `docs/release/dependency-sweep.md` against an isolated root and verify its receipt identifies the current manifest's dependency set and canonical hash. Missing provenance or a receipt/hash/set mismatch blocks every channel. Do not manually dispatch CI. Preview releases use the normal push fast gate plus the local release gates. A stable GitHub release automatically triggers the heavy build-smoke and toolset-conformance jobs through the release event (`types: [released]`); wait for both and require success before declaring the stable release complete.
7. Commit release prep. Immediately before tagging, require both `git ls-remote --tags origin v<version>` and `gh release view v<version>` to show no collision. Create the annotated tag, atomically push `main` plus the tag, prove tag/commit identity, and require the resulting push fast gate to pass. Existing versioned releases may only be edited when explicitly recovering that same known partial release.
8. Resolve signing, notarization, and Sparkle values only from local release-machine configuration. Never print or commit private keys, Apple credentials, Keychain secrets, or tokens. Invoke `build-notarized-dmg.sh` with `--channel preview` or `--channel stable`; rely on its channel defaults unless an audited override is required. For preview, also publish the documented legacy bridge and retention policy. Never substitute an unsigned artifact.
9. Independently verify the GitHub release target and prerelease state, narrative notes, DMG checksum, code signature, notarization and stapling, embedded app/CLI versions, selected Sparkle enclosure/signature/build number/feed URL, updater visibility, and the preview legacy bridge when applicable. Independently inspect `CFBundleDisplayName`, `CFBundleName`, and `LungfishReleaseChannel` in the archived app, copied release app, and mounted DMG app; all must match the selected channel before declaring a release. For stable, also verify the automatic `release` event board on the released tag.
10. Before deleting the worktree that supplied this skill, run the merged primary checkout's installer with `--replace-managed-link` and prove `~/.codex/skills/releasing-lungfish` resolves inside the primary checkout. Only after verification, remove clean worktrees whose branches are fully merged, delete those merged local branches, and prune worktree metadata. Preserve unresolved, dirty, or unrelated active work and report it plainly.

## Evidence Report

Report the channel, release URL, version/tag/commit, DMG absolute path and SHA-256, archive/app paths, notarization and signature results, selected Sparkle feed (plus preview bridge when applicable), local tests per tier (naming each gate tier run and its PASS/FAIL line; XCUI only if an attended diagnostic run was performed), automatic CI appropriate to the channel, cleanup performed, and anything retained or unresolved. State only what commands verified.

## Install and Maintain

Run `scripts/install.sh` to link this repository-owned skill into `~/.codex/skills`. The symlink keeps the installed skill current with the repository. Re-run `scripts/validate.py` whenever release tooling changes.
