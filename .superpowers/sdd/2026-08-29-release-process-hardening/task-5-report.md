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
- The original independent-verification fixture encoded the builder metadata
  keys backward. Independent review replaced it with real builder output and
  proved `app_path` is the signed/notarized app while `release_app_path` is the
  preserved unsigned candidate; the verifier now uses `app_path`.
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
- Independent verification checks the signed/notarized app, streamed DMG
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

## Independent-review correction

The first independent review found two Critical and four Important gaps. Each
was reproduced with behavioral RED tests before production or workflow edits:

- Real builder metadata proved independent verification selected the preserved
  unsigned `release_app_path` instead of the signed/notarized `app_path`.
- A stateful GitHub test double and nondeterministic DMG-signing fixture proved
  recovery deleted and recreated a timestamp-sensitive immutable artifact, then
  could not match the already-published digest.
- Required GitHub Actions jobs with duplicate display names proved the name map
  accepted one duplicate depending on order.
- Missing immutable/feed digests and sizes, wrong mutable state, and a wrong
  Preview bridge digest all passed the original independent verifier.
- A real annotated remote tag plus real package receipt proved nightly advanced
  CalVer instead of resuming; moved, lightweight, stale, and wrong-channel
  variants were also incorrectly ignored.
- An absent private-key path proved CLI construction touched credential paths
  before package/tag/exact-SHA CI work.
- CI workflow evidence proved package logs were absent and missing evidence was
  configured as an error instead of an always-uploaded best-effort artifact.

The corrected transaction now treats the published immutable release as the
source of truth. Recovery validates exact tag/HEAD/channel/non-draft identity,
requires one remote DMG asset with exact SHA-256 and integer size, preserves a
matching local DMG or downloads that exact asset to a private temporary
directory and atomically places it, and verifies an existing signed app or
extracts it from a read-only mount of the verified DMG. The recovery branch
cannot archive, build Swift, sign, notarize, create a DMG, or upload the
versioned asset. Mutable feed and bridge releases are reconciled afterward and
exact matching assets are not uploaded twice.

Independent verification now uses the builder's signed `app_path`; requires
exact local/remote hash and size for the immutable DMG, primary appcast, and
legacy bridge appcast; and binds every remote release to target SHA,
non-draft state, and expected channel state. Every required CI job name must
occur exactly once. Credential paths remain expanded lexical absolute paths
until credentialed resume after the exact-SHA gate.

Nightly now checks the current prepared CalVer before selecting a new version.
One exact annotated remote tag peeling to HEAD plus a bounded regular receipt
whose commit/version/Preview channel and full canonical verification match
causes exactly one common-coordinator `--resume`; invalid recovery evidence
fails closed without version preparation. The builder's repeated Doctor is
documented as defense at the destructive boundary, while the coordinator owns
the earlier request-level gate.

CI's secretless unsigned package matrix now captures stdout/stderr in a channel
log outside the destructively prepared Release directory and uploads that log,
metadata, and receipt under `always()` with missing evidence ignored. Apps,
archives, DMGs, signed outputs, and private material remain excluded.

Correction verification:

- Builder phase suite: 25 tests passed.
- Nightly/coordinator suite: 35 tests passed.
- CI workflow suite: 21 tests passed.
- Contract-defined broader release suite: 192 tests passed in 171.793 seconds
  after updating one stale static assertion for the new idempotent
  mutable-upload helper.
- Bash syntax, Python compilation, PyYAML/Ruby YAML parsing (12 jobs), and
  `git diff --check`: passed.
- No live tag/push, GitHub mutation, credential lookup, signing, notarization,
  or remote publication was performed.

## Independent-review correction round 2

The second review found four Important security/idempotency gaps and one Minor
cleanup hazard. Strict behavioral REDs were captured before implementation:

- A complete immutable/feed/bridge publication still returned its receipt and
  the nightly driver replayed resume forever instead of integrating later agent
  work and selecting the next CalVer. Wrong targets, drafts, duplicate assets,
  and empty digests were incorrectly treated as resumable state.
- Recovery accepted a symlinked or case-aliased `signed` ancestor and could move
  the extracted app outside the marked release directory before mutable-feed
  publication.
- A hostile PATH `shasum` accepted same-size corrupt local and downloaded DMGs.
- Builder/coordinator identity remained partly hard-coded to `origin`, while
  `gh` could use a hostile default repository even when `upstream` was selected.
- A failed recovery mount detach was suppressed and the mounted private recovery
  workspace was recursively removed.

The correction adds one shared, read-only tagged-publication classifier in the
coordinator. It binds one selected GitHub remote, requires an exact annotated
tag peeling to the candidate SHA, validates target SHA/draft/channel state, and
requires one uniquely named asset with a canonical nonempty SHA-256 digest and
positive integer size for the immutable DMG and every required mutable appcast.
Complete state advances normally; incomplete consistent state resumes the exact
receipt once; conflicting or ambiguous state fails closed.

One strict repository-identity helper now derives the GitHub owner/repository
and scratch/marker key from the selected remote URL. Coordinator, Doctor,
builder, target security, and nightly pass that selection end-to-end; all `gh`
calls inherit the exact `GH_REPO`, and Doctor's API probe names the same
repository explicitly. Credentialed URLs, non-GitHub remotes, and requested
repository mismatches are rejected without printing the remote URL.

Signed recovery output now goes through the release target-security boundary
before parent creation, extraction moves, or feed publication. The exact
`release/signed/<app>` target must have canonical case and a private,
current-owner, non-symlink ancestor chain. Security/publication hashing uses
internal streaming SHA-256 or canonical `/usr/bin/shasum`; PATH resolution is
not trusted for repository keys, DMGs, metadata, or mutable appcasts. A failed
explicit DMG detach remains fatal, retains the mounted workspace, and prevents
feed mutation and recursive cleanup.

Round-2 verification:

- Final focused correction regressions after formatting: 10 passed.
- Builder suite: 30 passed; nightly/coordinator suite: 38 passed; Doctor and
  naming suites: 49 passed (117 focused tests total).
- Contract-defined broader release suite: 202 passed in 234.673 seconds; three
  additional release modules: 7 passed.
- Python compilation, Bash syntax, PyYAML/Ruby workflow parsing (12 jobs), Black
  formatting, `git diff --check`, and the release-skill validator passed.
- No live tag/push, GitHub mutation/publication, credential access, signing,
  notarization, or remote mutation was performed.

## Independent-review correction round 3

The third review found one Critical GitHub-host binding gap and three Important
repository/publication identity gaps. Behavioral REDs were captured before
production changes:

- With inherited `GH_HOST=mirror.example.test`, Doctor, exact-SHA CI polling,
  and builder publication did not explicitly select github.com.
- The selected remote helper accepted divergent or multiple push endpoints,
  credentialed endpoints, and effective non-GitHub URL rewrites; its scratch
  key also varied with the remote spelling.
- An otherwise well-shaped remote mutable feed was classified complete when
  local completion metadata/appcasts were missing or contained newer bytes.
- The selected-upstream builder fixture exposed hard-coded original-repository
  Sparkle download and release-note URL prefixes.

The correction binds one validated github.com repository end to end. The
selected remote must expose exactly one effective fetch endpoint and one
effective push endpoint through `git remote get-url --all` and `--all --push`;
both must be credential-free github.com URLs for the same owner/repository.
`insteadOf` and `pushInsteadOf` rewrites are therefore evaluated, and the
repository key is the canonical hash of `github.com/owner/repository`, stable
across HTTPS/SSH syntax and remote renames. Error paths never echo endpoints.

Doctor explicitly authenticates and queries `--hostname github.com`.
Coordinator, nightly, and builder remove inherited `GH_HOST`, export a
host-qualified `GH_REPO=github.com/owner/repository`, and pass that exact
repository to every direct `gh` invocation. The builder derives Preview,
Stable, bridge, versioned-download, and release-note URL prefixes from the same
validated selected repository; no original owner/path constant remains in the
release transaction.

The tagged-publication classifier now requires receipt-bound, size-bounded
local completion metadata for the exact commit/channel/version and exact local
primary/bridge appcast paths, hashes, and sizes beneath the marked release
directory. Remote mutable assets must match those local bytes. Missing local
completion evidence is safely incomplete and resumes; conflicting metadata or
unsafe paths fail closed. A failure-injection test proves that a crash after a
mutable target edit but before upload cannot misclassify a stale canonical
asset as complete.

Round-3 verification:

- Strict focused regressions: 30 passed after formatting, including hostile
  `GH_HOST`, selected-upstream URL derivation, effective fetch/push endpoint
  validation, stale mutable bytes, and crash recovery.
- Builder suite: 30 passed; nightly/coordinator suite: 41 passed; Doctor suite:
  50 passed; workflow/packaging/prune static suite: 48 passed.
- Broader release discovery: 193 passed in 263.981 seconds.
- Python compilation, Bash syntax, PyYAML/Ruby workflow parsing, Black format,
  `git diff --check`, and the release-skill validator passed.
- No live tag/push, GitHub query or mutation, credential access, signing,
  notarization, or remote publication was performed.

## Independent-review correction round 4

The fourth review found three Important provenance and canonical-identity gaps.
Strict behavioral REDs were captured before each production correction:

- Eight complete/incomplete transaction cases accepted receipts with an
  unknown field, noncanonical JSON, mode other than 0600, or a stale builder
  hash because the classifier used only a shallow identity read.
- The exact-path regression first demonstrated that an alternate contained
  appcast was accepted when its bytes matched; the completed matrix also covers
  swapped primary/bridge paths, symlinked leaves and parents, and case aliases.
- Mixed-case fetch/push GitHub identities failed comparison and changed the
  repository boundary; a packaging-to-recovery case change failed before the
  package gate. A follow-up RED also covered host and `.git` extension case.

The classifier now calls the repository's exact production candidate-receipt
verifier for every tagged complete or incomplete transaction before inspecting
publication state. That verifier alone enforces canonical JSON/schema, mode,
current clean HEAD, contract app identity, exact scratch, payload, builder,
manifest, package lock, contract, toolchain, and input hashes. The coordinator
and nightly path share this one verifier; nightly's duplicate partial receipt
parser was removed. An untagged normal preparation remains unaffected because
there is not yet a recovery receipt to verify.

Mutable completion evidence is accepted only at the exact canonical contract
paths `release/sparkle-appcast/<primary filename>` and, when required,
`release/sparkle-appcast/<legacy bridge filename>`. Metadata must provide the
matching path/hash/size key set. Alternate contained files, aliases, wrong
letter case, swapped keys, and any symlink component fail closed; missing
completion metadata or missing exact artifacts remains safely incomplete.

GitHub owner/repository identity now rejects non-ASCII and invalid segments,
normalizes validated owner/repository text to lowercase, and treats harmless
ASCII case changes in the github.com host, owner, repository, and `.git`
extension canonically. Fetch/push comparisons, repository keys, `GH_REPO`,
scratch/markers, and derived Sparkle URLs therefore remain stable across a
case-only remote change. A stateful builder regression packages with mixed
case, publishes the immutable release, changes remote case, and resumes without
rebuilding the immutable artifact.

Round-4 verification:

- Focused RED: 14 expected failures/errors before production changes; all
  focused regressions passed after implementation and formatting.
- Nightly/coordinator suite: 43 passed; Doctor/preflight suite: 50 passed;
  builder suite: 31 passed.
- Final post-format broader release discovery: 196 passed in 282.774 seconds.
- Python compilation, Bash syntax, PyYAML/Ruby workflow parsing, Black format,
  `git diff --check`, and the release-skill validator passed.
- No live tag/push, GitHub query or mutation, credential access, signing,
  notarization, or remote publication was performed.
