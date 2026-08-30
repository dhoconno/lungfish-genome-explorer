# Task 5 Report: One Coordinator and Exact-SHA CI Gate

## Status

Complete. Manual releases use `scripts/release/release.py` directly, and the
nightly preparation flow delegates to that same interface exactly once. No
release, tag, push, credential, signing, notarization, or remote-publication
command was executed while implementing or testing this task.

## Behavioral TDD evidence

Production and workflow edits were preceded by behavioral tests for the new
contract:

- Initial RED: 62 tests ran with 1 failure and 13 errors. The failures proved
  that release gates, the common coordinator, nightly delegation, and the CI
  jobs did not yet exist.
- Refined RED: 20 coordinator/workflow tests ran with 2 failures and 11 errors.
- Nightly delegation RED: both focused delegation tests errored because
  `run_common_coordinator` did not exist.
- Independent-verification RED: the coordinator selected the scratch
  `app_path`, causing the published-app verification test to fail before the
  fix to `release_app_path`.
- Stable dependency-gate RED: the workflow test showed that the dependency
  receipt job was restricted to Preview and absent from Stable dependencies.
- Dependency-receipt semantics RED: the focused receipt test proved that pack
  environments were being required even though the reconciled receipt gate is
  for the manifest's managed `tools`; Stable conformance provisions and checks
  its pack set separately.
- Mutation-target RED: the coordinator initially nested its Xcode archive
  below the release directory; the Doctor-compatible path test failed until
  archive, release, and derived-data targets were made non-overlapping.

## Implemented behavior

### Common release transaction

- Loads focused tests and Preview/Stable source tiers from the strict release
  contract.
- Prepare order is Doctor package preflight, reconciled dependency receipt,
  focused release tests, channel source gates, unsigned package-only build,
  exact candidate-receipt verification, annotated tag creation/atomic push,
  bounded exact tag/SHA GitHub Actions wait, credentialed receipt resume,
  builder-owned immutable-then-mutable publication, and independent local and
  remote verification.
- Preview runs unit plus integration. Stable runs full plus conformance with
  `--require-tools`.
- Resume starts from the supplied receipt and cannot call Doctor, source gates,
  or package-only again. The builder is invoked once for the credentialed
  resume/publication phase and uses its exact-identity recovery mode when the
  immutable release already exists.
- Failed, cancelled, skipped, incomplete, missing, ambiguous, or wrong-SHA CI
  evidence blocks credentialed work and publication.

### Nightly integration

- Nightly retains branch classification, rescue archiving, version selection,
  worktree integration, and release-note/version commit preparation.
- Its duplicate build, tag, publication, pruning, and verification logic was
  removed.
- It now constructs one argument array and calls the common Preview coordinator
  exactly once.

### CI policy

- Main pushes run a read-only, secretless Preview/Stable matrix through the
  repository builder's unsigned `--package-only` phase.
- Uploaded evidence is limited to package metadata and the unsigned candidate
  receipt; apps, archives, DMGs, signed payloads, and private material are not
  uploaded.
- `v*` pushes derive the channel from exactly one committed `Channel: Preview`
  or `Channel: Stable` line in the matching canonical-CalVer release notes.
- Both channels require Fast gate, focused release tests, and the reconciled
  dependency receipt. Preview additionally requires unit/integration; Stable
  requires full/conformance.
- Post-publication `release` jobs remain defense in depth after the binding
  exact-SHA tag-push board.

## Security and idempotency review

- External commands use argument arrays; the coordinator does not invoke a
  shell parser for dynamic values.
- JSON and metadata inputs are size-bounded and shape-checked. Receipt inputs
  must be regular non-symlink files; artifact paths are resolved beneath the
  receipt's release directory; DMG hashing is streamed.
- Candidate identity binds canonical version, channel, commit, scratch path,
  clean source, and exact receipt verification before tag work.
- Annotated local and remote tags must peel to the receipt commit; recovery
  validates an existing tag rather than replacing it.
- GitHub Actions polling has bounded duration and interval, binds both tag and
  SHA, requires one unambiguous completed run, and requires every named job to
  complete successfully.
- Credentials are checked and passed only after the exact-SHA board succeeds.
  Subprocess errors do not echo captured command output or receipt contents.
- Independent verification checks the release-directory app, streamed DMG
  digest, code signature, stapling, Gatekeeper, smoke behavior, immutable
  release identity/state/assets, and mutable feed target/appcast assets.

## Verification

- Focused final suite: 59 tests passed.
- Broader release suite: 227 tests passed in 135.969 seconds.
- Python compilation: passed for the coordinator, contract loader, and nightly
  driver.
- Bash syntax: passed for the nightly wrapper, builder, and suite gate.
- Workflow YAML: parsed successfully with both PyYAML and Ruby YAML; 12 jobs
  present.
- Black format check: passed for all changed Python files.
- `git diff --check`: passed.
- Repository release-skill validator: passed.

## Residual integration boundary

Live GitHub tag/run behavior and Apple/Sparkle credentialed operations were not
exercised, by task requirement. Their command construction, ordering, failure
gates, and recovery paths are covered at subprocess boundaries without remote
mutation.
