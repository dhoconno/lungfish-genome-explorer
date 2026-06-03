# Nightly Alpha Releases

During rapid iteration, Lungfish publishes an incrementing alpha DMG every
morning so testers can pick up the previous day's work through Sparkle.

The nightly job runs only on the local signing Mac because it needs the
Developer ID certificate, `notarytool` keychain profile, Sparkle EdDSA private
key, and GitHub release credentials.

## Schedule

The Codex cron automation runs at 2:00 AM local time and executes:

```bash
scripts/release/run-nightly-alpha-release.sh
```

The wrapper delegates to `scripts/release/nightly_alpha_release.py`, which
coordinates git state, tests, version bumping, the notarized DMG build, GitHub
release publishing, Sparkle appcast publishing, and cleanup.

## Agent Cleanup Scope

The coordinator treats these branches as agent-managed:

- `codex/*`
- `claude/*`
- `worktree-*`

Those patterns cover Codex branches and Claude Code's default worktree branch
format. Worktrees attached to those branches are also managed. A worktree under
Claude Code's documented `.claude/worktrees/*` directory is also managed even
if a custom hook gave it a nonstandard branch name. Nonmatching local branches,
such as `feat/*`, are left alone.

Cleanup happens only after the full release succeeds. A failed merge, test,
push, notarization, Sparkle update, or verification leaves branches and
worktrees in place for debugging.

## Rescue Archives

Before committing dirty agent worktrees or deleting branches, worktrees, or
stashes, the coordinator writes a rescue archive under:

```text
.build/nightly-release-rescue/<release-tag>/
```

The rescue path is under `.build/`, which is ignored by git. The coordinator
fails if the rescue path is not ignored. Each run prunes rescue archives older
than two days to keep disk use bounded.

Rescue contents include:

- branch bundles
- dirty worktree status and diffs
- untracked files from dirty worktrees
- stash patches for dropped agent-branch stashes
- main branch status, branch, worktree, stash, and log snapshots

## Release Flow

1. Acquire `.build/nightly-alpha-release.lock`.
2. Verify the main checkout is clean.
3. Fetch `origin`, tags, and prune stale remote refs.
4. Pull `origin/main` with `--ff-only`.
5. Compute the next alpha version, such as `0.5.0-alpha14`.
6. Discover Codex and Claude branches/worktrees.
7. Create the rescue archive.
8. Commit dirty agent worktrees on their own branches.
9. Merge each agent branch into `main`.
10. Update version constants and write release notes.
11. Commit `release: v<version>`.
12. Run the full test suite with `swift test`.
13. Push `main`, create the annotated release tag, and push the tag.
14. Run `scripts/release/build-notarized-dmg.sh`.
15. Verify checksum, signing, stapling, Gatekeeper, GitHub release, and Sparkle release.
16. Remove merged agent worktrees, local agent branches, remote agent branches, and agent stashes.

## Required Local Credentials

- Developer ID Application certificate in the login Keychain.
- `notarytool` profile named `LungfishNotary`.
- Sparkle private EdDSA key in the login Keychain, or pass
  `--sparkle-ed-key-file`.
- `gh` authenticated with release write permissions.
- Sparkle `generate_appcast` at
  `.build/artifacts/sparkle/Sparkle/bin/generate_appcast`.

## Manual Run

To run the same flow manually:

```bash
scripts/release/run-nightly-alpha-release.sh
```

To override the full test command during a local rehearsal:

```bash
scripts/release/run-nightly-alpha-release.sh --test-command "swift test --filter ReleaseBuildConfigurationTests"
```
