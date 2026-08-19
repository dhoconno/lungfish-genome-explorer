---
name: releasing-lungfish
description: Prepare, integrate, build, notarize, publish, verify, and clean up a CalVer Lungfish macOS release with a GitHub DMG, Sparkle preview and legacy bridge feeds, and detailed narrative release notes. Use when asked to make, publish, or validate a Lungfish release, release DMG, prerelease, or Sparkle update.
---

# Releasing Lungfish

Produce a reproducible release from current `main`. Treat a missing provenance, signature, notarization, or verification result as a blocking defect.

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
3. Name every new release with canonical CalVer `YYYY.M.PATCH`, such as `2026.8.1`; never add alpha, beta, preview, stable, or other channel suffixes. Capture the release machine's local calendar date once for the run. Set `YYYY` and `M` from that date without leading zeroes. Set `PATCH` to one more than the highest positive patch for that year and month across both remote Git tags and GitHub releases; start at `1` when the month has none. Ignore mutable `sparkle-beta`/`sparkle-alpha` feed tags and all legacy-version tags when computing the counter. Fail if an existing CalVer release is future-dated relative to the captured month. A user-supplied version must be canonical, match the captured year/month, and be collision-free. Use tag `v<version>` and release notes `docs/release-notes/<version>.md`. Recheck Git tags and GitHub releases immediately before tagging and publication. Recompute after a concurrent collision; never overwrite a tag or versioned release.
4. Compare the previous versioned tag to `HEAD`. Harmonize every visible app/CLI/version declaration. Write `docs/release-notes/<version>.md` as a detailed narrative of user-visible changes, stability work, pinned dependency versions, and release maintenance. Verify every claim against commits and changed files.
5. Run the current focused release tests, full relevant tests, `git diff --check`, and old-version scans. Before tagging, preflight `gh auth`, Developer ID identity and Team ID agreement, the notarytool Keychain profile, the Sparkle `generate_appcast` executable and signing-key access. Parse the live preview appcast on `sparkle-beta` and require the planned `CFBundleVersion` (`LUNGFISH_BUILD_NUMBER` or `git rev-list --count HEAD`) to exceed its `sparkle:version`. Sparkle orders these builds by monotonic `CFBundleVersion`; CalVer is the user-visible short version and does not replace that gate.
6. Run the dependency verification procedure in `docs/release/dependency-sweep.md` against an isolated root. Require its receipt to identify the current manifest's `dependencySet` and require a green `toolset-conformance` run for the current manifest hash. Missing provenance or a receipt/hash/set mismatch blocks release.
7. Commit release prep and push `main`. Immediately before tagging and again before publication, require both `git ls-remote --tags origin v<version>` and `gh release view v<version>` to show no collision. Then create/push the annotated tag and prove tag/commit identity. Existing versioned releases may only be edited when explicitly recovering that same known partial release.
8. Resolve signing, notarization, and Sparkle values only from local release-machine configuration. Never print or commit private keys, Apple credentials, Keychain secrets, or tokens. Invoke the repository release script with the versioned GitHub preview release, the compatibility-named `sparkle-beta` preview feed, the `sparkle-alpha` legacy bridge, and the documented retention policy. Channel status belongs to feeds and GitHub release state, never the version string. Never substitute an unsigned artifact.
9. Independently verify the GitHub release, narrative notes, DMG checksum, code signature, notarization and stapling, embedded app/CLI versions, Sparkle enclosure/signature/version, legacy bridge, and updater visibility.
10. Before deleting the worktree that supplied this skill, run the merged primary checkout's installer with `--replace-managed-link` and prove `~/.codex/skills/releasing-lungfish` resolves inside the primary checkout. Only after verification, remove clean worktrees whose branches are fully merged, delete those merged local branches, and prune worktree metadata. Preserve unresolved, dirty, or unrelated active work and report it plainly.

## Evidence Report

Report the release URL, version/tag/commit, DMG absolute path and SHA-256, archive/app paths, notarization and signature results, Sparkle preview/bridge status, tests run, cleanup performed, and anything retained or unresolved. State only what commands verified.

## Install and Maintain

Run `scripts/install.sh` to link this repository-owned skill into `~/.codex/skills`. The symlink keeps the installed skill current with the repository. Re-run `scripts/validate.py` whenever release tooling changes.
