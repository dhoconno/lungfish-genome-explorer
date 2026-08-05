# Reproducible Lungfish Release Skill Design

**Date:** 2026-08-05  
**Scope:** A version-controlled Codex skill for preparing and publishing Lungfish macOS releases

## Goal

Create a reusable `releasing-lungfish` skill that can prepare a versioned release,
write detailed narrative release notes, build and notarize the Apple Silicon DMG,
publish the GitHub prerelease, update the Sparkle beta and legacy bridge feeds,
and independently verify the published result.

The skill coordinates the repository's existing release machinery. It does not
reimplement signing, notarization, DMG construction, Sparkle signing, or GitHub
asset publication.

## Location and discovery

The authoritative skill lives at:

`<repository>/.codex/skills/releasing-lungfish/`

The local Codex installation discovers it through a symlink at:

`~/.codex/skills/releasing-lungfish`

The symlink targets the skill in the maintainer's primary checkout. Updating
`main` therefore updates the installed skill without copying files or maintaining
two versions. The skill includes an idempotent installer that creates or repairs
this link and refuses to overwrite an unrelated real directory.

## Authoritative sources

The skill remains intentionally thin. At the start of every release it reads the
current versions of:

- `scripts/release/build-notarized-dmg.sh --help`
- `docs/release/sparkle-updates.md`
- `.codex/agents/release-agent.md`
- `SKILLS.md`
- the relevant tests under `scripts/tests/` and
  `Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift`

This avoids duplicating command-line options or release implementation details
that would drift as the repository changes.

## Skill contents

The skill contains only files needed for execution:

- `SKILL.md`: release gates, orchestration, narrative-note standards, model
  policy, verification requirements, and failure behavior.
- `agents/openai.yaml`: discoverable title, short description, and default
  invocation prompt.
- `scripts/install.sh`: safely create or refresh the personal discovery symlink.
- `scripts/validate.py`: verify that the skill is installed from the expected
  repository, required authoritative files exist, essential release-script
  interfaces remain available, and no committed skill file contains release
  secrets.

No signing identity, Team ID, notary profile name, Sparkle private key, Apple
credentials, or GitHub token is stored in the skill.

## Release workflow

The skill follows these gates in order:

1. **Establish scope.** Inspect Git state, GitHub releases, tags, the previous
   release, and all commits and changed files in the release delta. Confirm the
   requested source branch and intended version. Default normal beta progression
   to the next unused beta number, but verify it remotely before editing.
2. **Protect user work.** Require a clean, current `main` before publication.
   Never overwrite unrelated changes. Merge or cherry-pick approved feature work
   only when the user has authorized integration.
3. **Prepare the version.** Update every authoritative app, CLI, help, test, and
   managed-tool version reference. Scan for stale active references to the prior
   version.
4. **Write release notes.** Create
   `docs/release-notes/v<version>.md` from the actual tag-to-HEAD delta. Use
   cohesive prose organized by user outcome, scientific/workflow behavior,
   reliability, and maintenance. Explain important changes and their effect;
   do not paste a commit list, inflate internal refactors, or claim unverified
   behavior. Keep the file suitable for both GitHub and Sparkle.
5. **Verify the source.** Run whitespace checks, version/release tests, feature
   tests relevant to the delta, and any broader suite required by risk. Stop on
   failure.
6. **Commit and publish the source identity.** Commit release preparation, push
   `main`, create and push the annotated version tag, and prove that the tag,
   local HEAD, and remote release target identify the same commit.
7. **Run the repository release script.** Use
   `scripts/release/build-notarized-dmg.sh` with credentials resolved only from
   the local Keychain or environment. Supply the versioned GitHub tag, Sparkle
   beta feed, and legacy alpha bridge flags. Let the script own archive creation,
   CLI embedding, signing, notarization, DMG creation, GitHub asset upload, and
   appcast generation.
8. **Verify independently.** Check app and CLI versions, code signatures,
   notarization acceptance, staples, Gatekeeper assessment, smoke tests, SHA-256,
   release metadata, GitHub assets and release body, appcast version/build/URL/
   length/signature/notes, and remote `main`/tag consistency.
9. **Report evidence.** Provide the GitHub URL, exact tag and commit, artifact
   paths, SHA-256, notarization status, Sparkle publication status, tests run,
   repository cleanliness, and any unresolved warnings.

Remote publication is a terminal stage. If any earlier source, test, signing, or
notarization gate fails, the skill stops before creating or changing GitHub and
Sparkle releases. If publication partially succeeds, it inspects the remote
state and resumes idempotently rather than blindly recreating releases.

## Model-selection policy

Choose model capability according to consequence and reasoning complexity:

- Use a balanced model for bounded mechanical work such as inventorying files,
  collecting command output, or checking a fixed list of metadata.
- Use the strongest available coding/reasoning model with high reasoning for
  release-delta interpretation, version authority decisions, narrative release
  notes, merge conflict resolution, publication orchestration, failure recovery,
  and the final audit.
- Keep all external mutations—pushes, tags, GitHub releases, asset replacement,
  and Sparkle publication—under the primary release owner's control. A delegated
  task may advise or verify but must not publish independently.
- If the active environment cannot change models, continue with the strongest
  available active model and increase verification rather than pretending a
  model switch occurred.

## Keeping the skill current

Three mechanisms prevent drift:

1. The installed skill is a symlink to the tracked repository copy.
2. The skill reads current repository documentation and script help on every
   invocation instead of copying their detailed interfaces.
3. `scripts/validate.py` is run before every release and in skill validation. It
   fails clearly when required source files or essential release options are
   missing, prompting a skill review alongside release-tool changes.

The validator is intentionally a compatibility check, not a hash lock. Internal
release-script edits that preserve the public contract do not force meaningless
skill changes.

## Validation

Before deploying the skill:

- Run a baseline release-planning scenario without the skill and record missing
  gates or unsafe assumptions.
- Initialize the skill with the official skill scaffold.
- Run `quick_validate.py` on the finished skill.
- Test `scripts/install.sh` against an isolated temporary personal-skills root,
  including idempotent reinstall and refusal to overwrite unrelated content.
- Test `scripts/validate.py` against the real repository and fixtures with a
  missing required file, missing essential release flag, and a secret-like
  committed value.
- Forward-test a dry-run release-planning request with the skill while forbidding
  remote mutations. Confirm that the resulting plan uses current repository
  commands, derives notes from the release delta, selects an appropriate model,
  protects credentials, and includes independent post-publication verification.

## Acceptance criteria

1. Codex discovers `$releasing-lungfish` through the personal symlink.
2. The authoritative skill and all helper files are committed in the repository.
3. Pulling updates to the primary checkout updates the installed skill.
4. The skill uses the committed release script and current Sparkle documentation.
5. Narrative release notes reflect the actual release delta and are suitable for
   GitHub and Sparkle.
6. The skill cannot consider a release complete without signed, notarized,
   stapled, independently verified DMG and verified GitHub/Sparkle publication.
7. The skill stores no private credentials or signing secrets.
8. The skill explicitly scales model capability to task complexity while keeping
   publication authority with the primary release owner.

## First use

After the skill passes validation and is installed, use it to integrate the
approved standalone Savont clustering and shared FASTA viewport changes, prepare
the next unused beta release after `v0.5.0-beta20`, write its narrative release
notes, and publish the notarized DMG and Sparkle feeds.
