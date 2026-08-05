---
name: releasing-lungfish
description: Prepare, integrate, build, notarize, publish, verify, and clean up a Lungfish macOS release with a GitHub DMG, Sparkle beta and legacy bridge feeds, and detailed narrative release notes. Use when asked to make, publish, or validate a Lungfish release, release DMG, prerelease, or Sparkle update.
---

# Releasing Lungfish

Produce a reproducible release from current `main`. Treat a missing provenance, signature, notarization, or verification result as a blocking defect.

## Load Current Authority

Before acting, read all of:

- `scripts/release/build-notarized-dmg.sh --help`
- `docs/release/sparkle-updates.md`
- `.codex/agents/release-agent.md`
- `SKILLS.md`
- relevant files under `scripts/tests/`

Run `scripts/validate.py` from this skill. If repository interfaces drifted, update the skill or stop; never guess obsolete flags.

## Choose Reasoning Strength

- Use a balanced model for read-only inventory and mechanical checks.
- Use the strongest available coding/reasoning model at high effort for branch classification, merge conflict resolution, release-delta analysis, narrative notes, publication recovery, cleanup decisions, and the final audit.
- Keep pushes, tags, releases, feed mutations, and deletion of branches/worktrees under the root agent.
- If model switching is unavailable, use the strongest active model and add an independent verification pass.

## Release Gates

1. Fetch `origin` and tags. Inventory every worktree, branch, and dirty path. Classify each as release work, already merged, unrelated active work, or unresolved. Preserve unrelated work. Any dirty or ambiguous item blocks deletion.
2. Integrate approved release work into a clean checkout of current `origin/main`. Test, commit, and push `main`; do not publish from a feature branch or silently discard changes.
3. Determine the version from current versioned GitHub releases and Git tags, excluding mutable `sparkle-beta` and `sparkle-alpha` tags. If the user supplied a version, require it to be collision-free. Otherwise:
   - for the newest alpha/beta prerelease, increment its final prerelease number;
   - for the newest stable release, increment patch;
   - never change channel, downgrade, or infer a major/minor bump silently.
   Recheck the remote immediately before tagging. Recompute after a concurrent collision; never overwrite a tag or release.
4. Compare the previous versioned tag to `HEAD`. Harmonize every visible app/CLI/version declaration. Write `docs/release-notes/v<version>.md` as a detailed narrative of user-visible changes, stability work, and release maintenance. Verify every claim against commits and changed files.
5. Run the current focused release tests, full relevant tests, `git diff --check`, and old-version scans. Commit release prep, push `main`, create an annotated version tag, and prove tag/commit identity.
6. Resolve signing, notarization, and Sparkle values only from local release-machine configuration. Never print or commit private keys, Apple credentials, Keychain secrets, or tokens.
7. Invoke the repository release script with the versioned GitHub prerelease, `sparkle-beta`, the `sparkle-alpha` bridge, and the documented retention policy. Never substitute an unsigned artifact.
8. Independently verify the GitHub release, narrative notes, DMG checksum, code signature, notarization and stapling, embedded app/CLI versions, Sparkle enclosure/signature/version, legacy bridge, and updater visibility.
9. Only after verification, remove clean worktrees whose branches are fully merged, delete those merged local branches, and prune worktree metadata. Preserve unresolved, dirty, or unrelated active work and report it plainly.

## Evidence Report

Report the release URL, version/tag/commit, DMG absolute path and SHA-256, archive/app paths, notarization and signature results, Sparkle beta/bridge status, tests run, cleanup performed, and anything retained or unresolved. State only what commands verified.

## Install and Maintain

Run `scripts/install.sh` to link this repository-owned skill into `~/.codex/skills`. The symlink keeps the installed skill current with the repository. Re-run `scripts/validate.py` whenever release tooling changes.
