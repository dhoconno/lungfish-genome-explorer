# Reproducible Lungfish Release Skill Implementation Plan

> **For Codex:** Use the `superpowers:executing-plans` skill to execute this plan task by task. Keep all remote mutations in the root agent and require independent verification before declaring the release complete.

**Goal:** Create, install, validate, and immediately use a repository-owned Codex skill that reproducibly integrates Lungfish release work, selects the next version, publishes a notarized DMG and Sparkle feeds, writes narrative notes, verifies the release, and removes safely merged worktrees and branches.

**Architecture:** The repository owns `.codex/skills/releasing-lungfish`; `~/.codex/skills/releasing-lungfish` is a symlink to it. The skill delegates authoritative mechanics to the existing release script and documentation, while a small validator detects interface drift and an installer maintains discovery. Release integration happens in a clean worktree so unrelated edits in the primary checkout are preserved until they can be classified safely.

**Tech Stack:** Markdown skill instructions, Python 3 validation/tests, POSIX shell installation, Git/GitHub CLI, Swift/Xcode release scripts, Sparkle tools.

---

### Task 1: Add failing contract tests

**Files:**
- Create: `scripts/tests/test_releasing_lungfish_skill.py`

1. Test that the validator accepts the real repository.
2. Test failures for a missing authoritative file, a missing required release flag, and secret-like material in the skill.
3. Test that installation creates the expected symlink, is idempotent, and refuses to replace an unrelated file or directory.
4. Run the tests and confirm they fail because the skill scripts do not yet exist.

### Task 2: Scaffold and implement the skill

**Files:**
- Create: `.codex/skills/releasing-lungfish/SKILL.md`
- Create: `.codex/skills/releasing-lungfish/agents/openai.yaml`
- Create: `.codex/skills/releasing-lungfish/scripts/install.sh`
- Create: `.codex/skills/releasing-lungfish/scripts/validate.py`

1. Scaffold with the official `skill-creator` initializer.
2. Write concise trigger metadata and instructions that require current repository sources to be read on every invocation.
3. Encode the approved model policy, worktree reconciliation gates, version selection from current published releases/tags, narrative notes, notarized DMG/Sparkle publication, verification, and safe cleanup.
4. Implement an idempotent symlink installer and compatibility validator without embedding credentials.
5. Run contract tests and the official skill validator until they pass.

### Task 3: Install and independently exercise the skill

**Files:**
- Modify only the personal symlink: `~/.codex/skills/releasing-lungfish`

1. Install the repository skill into the personal skills directory.
2. Verify the link resolves to the repository source.
3. Ask an independent high-reasoning reviewer to perform a read-only release dry run from the skill.
4. Correct any omissions, rerun all validation, and commit the finished skill.

### Task 4: Reconcile release work into a clean main

**Files:**
- Merge existing release-related commits; do not rewrite unrelated user files.

1. Fetch remote state and inventory every worktree, local branch, and dirty change.
2. Have an independent high-reasoning reviewer classify each item as release work, already merged, unrelated active work, or unresolved.
3. Create a clean release-integration worktree from current `origin/main` if the primary checkout cannot be used safely.
4. Merge the miSeq and Savont branches in dependency order, resolve conflicts based on tested behavior, and include the release skill.
5. Run focused and full release tests; commit and push the resulting main only if `origin/main` has not changed.

### Task 5: Select and prepare the release version

**Files:**
- Modify version declarations and release-note artifacts identified by current release documentation.

1. Read the live release script help, release agent instructions, Sparkle guide, and release tests.
2. Query versioned GitHub releases and Git tags, excluding Sparkle feed tags.
3. Increment the active release channel from the newest published version unless the user supplied a version; reject collisions and silent channel changes.
4. Write detailed narrative release notes centered on Savont standalone clustering and the other user-visible improvements included since the prior release.
5. Gate: `dependencySet` in the manifest equals the receipt from `scripts/deps/verify.sh`; a green `toolset-conformance` run exists for the manifest hash. See `docs/release/dependency-sweep.md`.
6. Commit version/notes, rerun release tests, push main, and create/push the exact annotated tag after one final collision check.

### Task 6: Build, notarize, and publish

**Files:**
- Outputs: notarized DMG, GitHub prerelease assets, beta and legacy Sparkle appcasts.

1. Resolve signing, notarization, and Sparkle inputs from the configured release machine without printing secrets.
2. Run the repository release script with GitHub publication, beta Sparkle publication, the legacy alpha bridge, and prerelease pruning enabled.
3. Stop immediately on signing, notarization, stapling, upload, or feed-generation failure; never substitute an unsigned artifact.

### Task 7: Verify and clean up

1. Independently verify the tag/commit identity, GitHub release state, DMG checksum/signature/notarization/stapling, app signature, appcast enclosure/signature/version, legacy bridge, and update visibility.
2. Confirm `origin/main` contains the released tag and all intended Savont/miSeq work.
3. Remove only clean worktrees whose branches are fully merged; delete their merged local branches and prune worktree metadata.
4. Preserve and report any dirty, unmerged, or unrelated work rather than deleting it.
5. Report the release URL, version, artifact checksum, Sparkle status, tests, and any deliberately retained workspace state in plain language.
