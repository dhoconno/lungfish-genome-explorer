# LGE comprehensive engineering assessment

**2026-09-05 · Review only · Baseline `13e114087b1c0a994ad1d957ce7d71b963e5575d`**

Lungfish Genome Explorer has a substantive implementation and several good architectural foundations. Its largest risk is inconsistent use of those foundations at workflow boundaries: cancellation versus actual process exit, payload publication versus provenance publication, window-local intent versus global state, and a test runner's exit versus proof that its intended tests completed. Address these contracts before expanding functionality. A wholesale rewrite or indiscriminate test reduction is not justified by this assessment.

This audit identifies **35 numbered findings**, plus separately labeled product questions and conditional risks. **Ten findings carry P1 priority** in the specialist reports. They include source-confirmed data-loss interleavings and provenance violations, reproduced CLI failures, and a reproduced fail-open test gate. No P0 emergency or evidence of a compromised release was established. This is not a certification that all features work or that the current release is ready.

## Review packet

| Read | Purpose |
|---|---|
| This report | Overall judgment, priorities, boundaries, design recommendations and decision points |
| [Implementation plan](../../superpowers/plans/2026-09-05-lge-audit-remediation.md) | Sequenced work packages, dependencies, file targets, acceptance gates and handoff instructions |
| [Architecture](architecture.md) | Ten findings: cancellation, rollback, project access, window ownership, responsiveness and recovery |
| [User workflows](workflows.md) | Eight defects, 16-family coverage map, AI/setup/export/retry decisions and conditional risks |
| [Data integrity and provenance](data-integrity.md) | Eight findings: publication, consumed inputs, GUI provenance, replay, statistical boundaries |
| [Testing and releases](quality-release.md) | Nine findings: gate trust, locks, evidence, UI testing, CI and corrective release recovery |
| [Validation and inventory](validation.md) | Executed checks, observed failures, codebase size, source baseline and important exclusions |
| [Evidence](evidence/) | Retained build/test logs and structured synthetic CLI probe output |

## Overall assessment by area

| Area | Judgment | What to preserve | Main repair |
|---|---|---|---|
| Module architecture | Useful boundaries; responsibility concentration persists inside modules | Core/IO/Workflow graph, separate CLI, feature UI leaves, app-only Sparkle | Extract ownership and publication responsibilities from selected controllers, not arbitrary file chunks |
| Swift/AppKit concurrency | Good local patterns, incomplete global adoption | MainActor UI state, request-generation gates, session registry | Worker-acknowledged cancellation; identity checks at every asynchronous publication |
| Persistence | Strong transactions in places; inconsistent failure recovery | SQLite transactions, versioned state envelopes, explicit provenance primitives | Retain backups on failed restoration; validate access/version before mutable open |
| Feature completeness | Real breadth, uneven entry-point behavior | Native bundles, guided tools, diagnostics, specialized result views | Same object identity and input validation across open/panel/drop/ZIP; every operation terminates |
| Scientific integrity | Rich provenance infrastructure; caller defects remain | Full hashes, runtime/options records, snapshots, rehydration | Publish data and provenance together; record consumed bytes; exercise replay |
| Computational consistency | Boundary errors found in small generic summaries | Existing parsers and streaming/histogram approaches | Shared Nx implementation and record-preserving composition; truthful flags/help |
| Tests | Extensive suite, but counts and green outcomes overstate assurance | Behavioral fault-injection, protocol/format fixtures, targeted UI tests | Gate completeness, caller tests, small independent numerical oracles, measured flake tracking |
| Releases | Serious receipt/signing/channel design; evidence gap | Single coordinator, immutable candidate identity, monotonic Sparkle builds, relocation smoke | Fail-closed gates, candidate-bound results, focused real app checks and forward-fix drill |
| Runtime dependencies | Managed manifest valuable; exported lock is lossy | Tool build specs, bootstrap/overlay checksums, install provenance | Exact environment/platform/artifact round trip; explicit database snapshot policy |
| Product simplicity | Breadth is ahead of consistency | Core/specialized grouping, native desktop controls | Consistent scope, recovery and persistence; avoid more top-level commands until existing paths cohere |

The technical principles here align with [Apple's responsiveness guidance](https://developer.apple.com/documentation/xcode/improving-app-responsiveness), [Swift's data-race safety model](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/), [SQLite's live-backup guidance](https://www.sqlite.org/backup.html), [GitHub's action hardening guidance](https://docs.github.com/en/actions/reference/security/secure-use), and [Sparkle's publishing model](https://sparkle-project.org/documentation/publishing/). These sources inform recommendations; individual defects are established from repository evidence. Async syntax alone does not move synchronous work off the main actor, and signing authenticates an artifact rather than proving it is correct.

## Findings ledger and implementation mapping

Priorities are engineering triage, not vulnerability scores. P1: high-impact integrity/correctness, explicit provenance blocker, or release authorization defect. P2: bounded correctness, recovery, responsiveness or assurance gap. P3: maintainability improvement. Source-confirmed races/failure paths still need deterministic regression tests before repair; they are not described as crashes observed in a live user session.

| ID | Priority | Finding | Plan package |
|---|---|---|---|
| ARCH-01 | P1 | Cancellation unlocks before child exit/cleanup; old cleanup can delete replacement output | 02 |
| ARCH-02 | P1 | Failed rollback suppresses errors and deletes the only recovery backup | 03 |
| ARCH-03 | P2 | Project open creates/migrates writable storage before validation/access decision | 06 |
| ARCH-04 | P2 | Project restoration materializes all sequences on MainActor | 08 |
| ARCH-05 | P2 | External file load can publish into a newer selection/session | 07 |
| ARCH-06 | P2 | Global document events and stale projectless facade violate window ownership | 07 |
| ARCH-07 | P2 | Root change removes refresh subscriptions without recovery notification | 09 |
| ARCH-08 | P2 | UI mutation paths synchronously copy/hash large databases | 08 |
| ARCH-09 | P2 | Future metadata/database versions accepted for writing | 06 |
| ARCH-10 | P3 | Concentrated controller responsibilities and duplicated transactions | 16 |
| WF-01 | P1 | Native bundle drops flatten package contents | 05 |
| WF-02 | P1 | Failed sidebar reference import leaves an immortal Running operation | 02 |
| WF-03 | P2 | Wizard cards accept drops then no-op and record successful dispatch | 05 |
| WF-04 | P2 | Multiple sample-sheet drops silently discard all but first | 05 |
| WF-05 | P2 | Standard project Save/Save As has no implementation | 15 |
| WF-06 | P2 | Missing/invalid workflow registrations disappear and cannot be removed normally | 10 |
| WF-07 | P2 | Replacement package paths reintroduce duplicate workflow IDs after reload | 10 |
| WF-08 | P2 | Settings tab departure cancels pending credential persistence | 11 |
| DATA-01 | P1 | GUI GFF3 export lacks provenance | 04 |
| DATA-02 | P1 | Failed forced conversion replaces previous output before sidecar failure | 03 |
| DATA-03 | P1 | In-place conversion records post-write bytes as consumed input | 03 |
| DATA-04 | P1 | Post-write GUI sidecar failures can delete replaced exports | 03, 04 |
| DATA-05 | P2 | Exported replay script ignores durable replay argv | 04 |
| DATA-06 | P2 | Bookmark export records a non-executable descriptive action as durable argv | 04 |
| DATA-07 | P2 | Nx rounding can overstate N50/N90 across multiple implementations | 12 |
| DATA-08 | P2 | Composition crosses record boundaries; advertised stats options are unused | 12 |
| QR-01 | P1 | Isolated test retry can erase an original process crash status | 01 |
| QR-02 | P2 | Empty/incomplete test runs can report gate success | 01 |
| QR-03 | P1 | Conda lock round trip loses environment, platform and source identity | 13 |
| QR-04 | P2 | Stable release gates do not execute Xcode UI target | 14 |
| QR-05 | P2 | Candidate receipt does not retain/bind actual gate results | 01 |
| QR-06 | P2 | Database labels/URLs lack expected payload digests | 13 |
| QR-07 | P2 | Automatic CI does not compile/test Swift behavior | 14 |
| QR-08 | P2 | CI actions/test dependencies resolve mutable versions | 14 |
| QR-09 | P2 | No demonstrated installed-client corrective-release drill | 14 |

WF-02 is a P1 user-workflow blocker within its report, but queue it after data-loss and gate-authorization repairs when staff is constrained. WF-R1's AI disclosure recommendation is a product-priority risk, not an additional confirmed P1 defect; it is not included in the ten-count above. WF-R3 overlaps ARCH-01 and must not generate a duplicate cancellation implementation.

## Most consequential examples

1. **Cancellation can outlive ownership.** The VCF import cancellation callback only sets a flag. The operation center unlocks the bundle before the child exits; later cleanup deletes a deterministic database path. Restarting into that path creates an unsafe interleaving. Fix ownership and cleanup identity together.
2. **Rollback can destroy recovery.** Two mutation services suppress restoration errors and always delete backups. A successful rollback test does not cover a failed rollback. Preserve recovery artifacts and surface a recoverable state.
3. **A failed CLI export changes files anyway.** The synthetic conversion probe exits 1 for an obstructed provenance path, while its previous output has already been replaced. Another probe records an input digest from the newly converted bytes. These are independently reproduced caller defects despite passing selected provenance suites.
4. **A green gate can conceal missing execution.** Extracted unmodified gate functions return success for a zero-test stub and for a crashed full run followed by a passing isolated retry. The simulated runner does not claim the real suite is currently crashing; it proves that the authorization wrapper permits this outcome.
5. **Objects behave differently at different doors.** Native MSA/tree bundles are recognized by external open, but sidebar import can descend into their internals. Wizard cards can accept a drop and close without dispatching a wizard. The fix is entry-point parity around one existing object model.

## Recommended target architecture

Retain the current product graph. Add or extend only small components that own a demonstrable invariant:

- **Window/session coordinator:** owns document membership, request identity, selection, progress and error presentation. Global state can be a compatibility read view, never the authority for mutation destinations.
- **Operation lifecycle:** registered → running → cancellation requested → worker drained → terminal. The lease remains held through process exit, stream drain, publication and cleanup. Every importer has exactly one terminal outcome.
- **Scientific publication transaction:** snapshots consumed input, stages payload/provenance, validates final identity, commits, and retains recovery state if restoration fails. The existing builder/writer/snapshot layers remain the implementation foundation.
- **Bundle capability registry:** recognizes an object once and supplies existing open/import/export capabilities. It should be an extension of present descriptors/enums, not a parallel plugin platform.
- **Persistent workflow registration:** identity and last-known metadata survive missing source files. Validation produces status, not the existence of the registration itself.
- **Release evidence:** exact source/runtime identity plus executed-test evidence authorizes a candidate. Retrying is diagnostic evidence and cannot erase a crashed or incomplete run.

Do not begin by migrating all AppKit to SwiftUI, replacing SQLite, introducing a universal event bus, creating one generic abstraction for every workflow, or splitting giant files by line count. There is no evidence those changes would resolve the identified failures. Keep bespoke scientific/viewer behavior where it represents different user needs; unify lifecycle, error, scope and storage contracts where inconsistency creates defects.

## Product decisions to settle during implementation review

No user input was required to finish this assessment. These are explicit future design decisions, with recommended defaults:

| Decision | Recommended default | Why / evidence |
|---|---|---|
| Save semantics | Explain automatic persistence; offer a separate coherent “Save Project Copy…” only if full portability is implemented | Avoid inert document commands and undefined copy scope (WF-05) |
| First-run tool setup | Let read-only viewing proceed where it has no dependency; install tools at the operation boundary | Current Welcome route gates entry on core setup; other file-open routes differ (WF-R2) |
| Retry | “Run Again…” restores inspectable configuration after prior worker termination | Do not blindly rerun partial mutations or relabel a failed attempt (WF-R3) |
| Export scope | Show named source, selection count, destination and format consistently | Current viewer versus sidebar precedence and first-item narrowing differ (WF-R4) |
| Workflow package add | Explicit linked registration with Locate/Remove, or managed copy with declared update behavior | Missing-volume and duplicate-ID issues need durable identity (WF-06/07) |
| AI context | Default-off stays; preview included context and disclose selected/fallback recipient | Existing disclosure mentions fallback; sample/table context warrants more precise control (WF-R1) |
| Dependency locks | Call requested-spec manifests exactly that; promise resolved replay only when artifact identity is retained | Existing “lock” format drops required identity (QR-03/06) |
| Feature breadth | Pause expansion in affected families until happy/failure/reopen/export journeys are coherent | Breadth of catalog is not proof of completion |

These recommendations do not claim data was disclosed without consent, that every offline route is blocked, or that any installed dependency is compromised. Those stronger claims were not established.

## Testing strategy: more discriminating evidence, not simply more tests

Keep high-value tests that validate transaction failure boundaries, format conformance, final payload hashes, numerical edge cases, and user-visible state changes. Replace source-string assertions only when a behavioral seam protects the same requirement. Static contract tests are still appropriate for release config and generated manifests. A large fixture or test file is not, by itself, overtesting.

The first additions should be small deterministic scenarios: delayed cancellation acknowledgement, restore failure preserving backup, stale A-after-B load, malformed bundle drop, empty gate, crash-plus-retry, sidecar failure during overwrite, aliased input snapshots, odd-total Nx, and adjacent records that must remain separate. These make current defects fail without large real-world scientific runs.

Use a narrow real-app smoke gate for responder chains, selection routing, key persistence and reopen behavior that in-process tests cannot establish. Use representative larger synthetic files for responsiveness and memory measurement. Keep expensive external-tool conformance in a separate required environment with explicit skip policy and actual executed counts. Do not fabricate a line-coverage percentage or deletion target; this audit measured neither semantic redundancy nor mutation sensitivity.

## Delivery sequence and exit conditions

**Wave A — Trust and data preservation:** plan 01–05. Gates reject incomplete runs; cancellation retains ownership; failed publication/rollback preserves old data or recoverable artifacts; essential exports have correct provenance; native imports preserve bundle identity.

**Wave B — Correct state and computation:** plan 06–07, 10–13. Validate project formats/access, complete window ownership and registrations, preserve settings writes, fix generic statistics and dependency identity. Run these after their prerequisites; not every package depends on Wave A completion.

**Wave C — Responsiveness and product continuity:** plan 08–09 and 15. Measure catalog-first loading, background database mutation, root/volume recovery, Save/scope/retry/setup behavior. Build on the ownership contracts already repaired.

**Wave D — Release and maintainability closure:** plan 14 and 16. Bind graphical checks into release evidence, execute a corrective-release drill, add affordable current-commit CI, then remove obsolete wrappers and selected source-shape tests. Release infrastructure work can proceed alongside earlier waves; final signoff requires their results.

Before asserting readiness for a wider stable rollout, all P1 findings must be repaired and verified or the affected route explicitly removed/disabled with a documented supported alternative. Missing scientific provenance is not waived by adding a warning. Remaining P2 work needs named ownership and explicit scope. No code or release changes are authorized by this packet itself; it is the requested material for review before implementation.
