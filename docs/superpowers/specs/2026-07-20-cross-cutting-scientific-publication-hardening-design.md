# Cross-Cutting Scientific Publication Hardening Design

Date: 2026-07-20

Status: Approved audit design; implementation is split into an immediate tranche and a later coordinated transaction tranche

## Summary

Lungfish has strong local safeguards in several recent workflows, but equivalent scientific operations still use different publication, rollback, parsing, process, and provenance patterns. This produces cross-cutting risks that cannot be removed reliably by patching individual feature edges.

This design establishes central boundaries for:

1. publishing SQLite scientific databases without losing WAL content and on filesystems such as ExFAT;
2. reading FASTQ records strictly and consistently in every demultiplexing path;
3. executing external scientific processes without pipe deadlocks, orphaned children, or missing telemetry;
4. proving that each output-writing CLI leaf has an exact provenance policy;
5. mutating bundle payloads, manifests, and provenance as one durable, recoverable generation; and
6. attesting the exact input generation used by a workflow.

The first four items form the immediate tranche. They are independently releasable and fit the remaining overnight work window. Durable multi-file bundle and provenance transactions are a later coordinated tranche because partial migration would leave inconsistent ownership boundaries.

## Motivation

The full-length MHC candidate work exposed filesystem behavior that is not unusual for Lungfish deployments: scientific projects live on removable and network-adjacent volumes, including ExFAT, while the app and CLI may both operate on the same bundle. The same investigation showed that some shared helpers assume APFS rename behavior, some rollback helpers survive Swift errors but not process death, and some scientific parsers downgrade malformed input to a warning.

These are architectural issues. Fixing each caller independently would duplicate hardening logic and allow future workflows to regress. The desired state is that a scientific feature obtains safety by using a central primitive, while bypassing that primitive is visible in tests.

## Scope

### Immediate tranche

- Harden the shared SQLite database publisher.
- Make SQLite errors in the NVD unique-read enrichment path explicit rather than returning a successful zero-row result.
- Introduce one strict raw FASTQ record stream and migrate exact-barcode demultiplexing paths that currently accept arbitrary four-line chunks.
- Repair the unbounded cross-process test teardown that blocks aggregate verification.
- Extend the existing hardened process runner for arbitrary executable plus file-output use, migrate the two confirmed deadlock-prone scientific callers, and add a source-level guardrail against new direct `Process()` use.
- Require exact leaf-level scientific CLI provenance policies.

### Later coordinated tranche

- Add one cross-process bundle mutation coordinator.
- Publish bundle payloads, manifests, provenance sidecars, and signing artifacts as one recoverable generation.
- Replace destructive temporary-directory rollback snapshots.
- Add pre-execution input generation attestations.
- Move bundle-member mutations to descriptor-relative, no-follow filesystem operations.
- Migrate annotation, alignment, and variant attachment services onto the shared transaction boundary.

### Non-goals

- Cosmetic or product behavior changes.
- Changes to genotype interpretation, MHC classification, or viewport presentation.
- A wholesale rewrite of SQLite database model code.
- Migrating every direct `Process()` call in one session. The immediate tranche handles confirmed scientific risks and prevents new bypasses; remaining sites are inventoried and migrated deliberately.
- Making tolerant FASTQ parsing the default. If a future workflow needs recovery mode, it must be explicit and provenance-visible.
- Treating `.atomic` Foundation writes as a substitute for multi-file transaction semantics.
- Silently repairing ambiguous transaction state. Ambiguity must stop publication and preserve all identifiable generations for operator recovery.

## Provenance constraints

The AGENTS.md requirements are binding:

- Every CLI command or app workflow that creates, imports, transforms, exports, or wraps scientific data must publish reproducibility provenance.
- Provenance records must contain tool/workflow name and version, exact argv or reproducible command, user-visible options and resolved defaults, runtime or container identity, input and output paths, checksums, sizes, exit status, wall time, and useful stderr.
- GUI-imported CLI output must preserve or rehydrate provenance to the final stored payload path.
- A new scientific payload without matching provenance is a blocking defect.

Hardening therefore follows two additional rules:

1. A completed provenance record must describe the final stored payload generation, not a staging path or a different file generation observed after execution.
2. Payload and provenance publication must fail closed. If the system cannot prove a complete old or complete new generation, it retains evidence and reports an ambiguous transaction instead of deleting or guessing.

## Ranked audit evidence

### P0: SQLite publication can discard WAL content and fails on ExFAT

`Sources/LungfishIO/Formats/Common/SQLiteDatabasePublication.swift:28-50` publishes with `FileManager.replaceItemAt` when the destination exists. The real MHC exemplar demonstrated that the corresponding exclusive rename family is unsupported on the ExFAT analysis volume, so APFS-only assumptions are not acceptable for shared scientific publication.

More critically, `SQLiteDatabasePublication.swift:58-75` ignores the result of `sqlite3_wal_checkpoint_v2` and then removes `-wal` and `-shm` unconditionally. A busy or failed checkpoint can therefore be followed by deletion of the only copy of committed pages.

The helper is a genuine central boundary: it is used by annotation database building, VCF database creation, and classifier databases. The NVD enrichment path compounds the problem by converting SQLite open, prepare, step, begin, update, and commit failures into `updatedRows: 0` at `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift:2273-2381`, after which its caller continues.

### P0: bundle writers can lose concurrent mutations

Several writers load a bundle manifest, create payloads, save a modified manifest, and restore the earlier manifest on error without a cross-process lock or generation check:

- `ReferenceBundleAnnotationImportService.swift:150-172,210-243`
- `SequenceAnnotationTrackWorkflow.swift:262-282,300-368`
- `PreparedAlignmentAttachmentService.swift:181-199,258-274`
- `BundleVariantTrackAttachmentService.swift:28-60`

Actors and `@MainActor` serialize only one in-process instance. They do not coordinate separate service instances, app windows, or CLI processes. Two writers can both derive from manifest generation N, publish different files, and each save a generation N+1 that omits the other. A failing writer can restore generation N after another writer has already committed.

### P0: payload/provenance rollback is not crash-safe

`Sources/LungfishWorkflow/Provenance/ProvenancePublicationSnapshot.swift:19-60` copies prior artifacts to the system temporary directory and restores with remove-then-copy. It has no durable marker, destination identity, generation check, recovery entry point, or protection against edits made after capture. Similar private snapshot implementations occur in annotation workflows.

`Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift:45-60,121-178` writes root provenance, rollups, focused sidecars, signatures, and pruning as separate operations. Signing rewrites and re-signs a sidecar multiple times at `ProvenanceWriter.swift:69-115`. Swift errors can trigger rollback in some callers; process death can still leave a scientific payload with stale, incomplete, or mismatched provenance.

### P1: demultiplexing bypasses strict FASTQ validation

The canonical `FASTQReader` validates headers, separators, sequence characters, wrapped sequence and quality, quality length, and EOF at `Sources/LungfishIO/Formats/FASTQ/FASTQReader.swift:200-351`.

Exact barcode paths instead treat each four lines as a record without validating the header, separator, or sequence/quality lengths and merely warn about trailing lines:

- `ExactBarcodeDemux.swift:253-264,344-347`
- `DemultiplexingPipeline.swift:1867-1913,2015-2073`

This can silently remove reads from sample counts and derived bundles while producing a successful run.

### P1: direct process execution repeats a documented pipe deadlock

`NativeToolRunner.runProcess` already drains stdout and stderr concurrently and supports timeout, cancellation, and process-tree termination at `Sources/LungfishWorkflow/Native/NativeToolRunner.swift:859-1006`. `Tests/LungfishWorkflowTests/CondaManagerTests.swift:727-755` documents the 64 KiB pipe-buffer deadlock that occurs when a parent waits before draining.

Two production callers still use unsafe variants:

- `ReferenceBundleImportService.swift:406-427` waits for exit before draining stderr.
- `MappingSummaryBuilder.swift:140-169` drains stdout and stderr sequentially, allowing one full pipe to block the child while the parent waits on the other.

Many additional direct `Process()` sites exist, so a guardrail is required in addition to the two immediate migrations.

### P1: provenance hashes local inputs after execution

`CLIProvenanceSupport.recordSingleStepRun` builds provenance after work has completed and reopens local input paths at `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift:182-187,227-235`. `ProvenanceRunBuilder.swift:275-291` rejects a precomputed local descriptor added verbatim, effectively forcing a post-run hash.

If an input is edited or atomically replaced during a long run, provenance may contain the checksum of a generation the tool never read.

### P1: provenance coverage tests only top-level command names

`Tests/LungfishCLITests/ScientificCLIProvenanceCoverageTests.swift:51-71` verifies top-level registrations. A new output-writing nested command can inherit a broad `fastq`, `genotype`, or `import` policy without proving that the leaf writes provenance. `ScientificProvenancePolicy.swift:178-181` currently contains exact path entries for only two nested commands.

### P1: aggregate test teardown can wait forever

`Tests/LungfishWorkflowTests/FullLengthONTMHCCohortAlignmentBuilderTests.swift:1571-1578` performs an unbounded `waitUntilExit()` and repeats it from `deinit`. This matches the observed aggregate-suite hang even though focused alignment tests pass.

### P2: path checks are check-then-use rather than descriptor-anchored

`BundleManifest+Validation.swift:93-119` validates a URL and returns a path for later use. `PreparedAlignmentAttachmentService.swift:333-395` resolves path components, then later removes and moves through ordinary paths. A parent directory can be replaced after validation and before mutation.

The long-term transaction layer must operate relative to open directory descriptors with `O_NOFOLLOW`, not rely on repeated lexical checks.

## Architecture

### 1. `SQLiteDatabasePublication`

The existing type remains the public internal boundary, but its implementation becomes a durable publisher rather than a convenience rename.

Publication sequence:

1. Confirm the staging file is a regular, non-symlink file adjacent to the final destination.
2. Open the staging database read/write with full mutex.
3. Require `sqlite3_wal_checkpoint_v2(..., SQLITE_CHECKPOINT_TRUNCATE, ...) == SQLITE_OK`.
4. Require `PRAGMA journal_mode = DELETE` to return `delete`.
5. Run `PRAGMA quick_check` and require exactly `ok`.
6. Close SQLite, fsync the database file, and verify no non-empty WAL remains.
7. Publish with `RENAME_SWAP` where available. If the filesystem reports `ENOTSUP`, use an exclusive destination reservation whose identity is attested before a three-rename generation rotation.
8. Fsync the destination parent.
9. Remove the retired generation only after the final database reopens and passes `quick_check`.

Failures never remove WAL/SHM files unless a successful checkpoint and journal-mode transition prove they are no longer authoritative.

The NVD enrichment helper becomes throwing. Missing optional BAMs may remain an explicit skipped-row outcome, but SQLite and samtools failures are errors recorded in failed provenance.

### 2. `FASTQRawRecordStream`

LungfishIO gains a raw-record type and streaming reader that preserves the original record text needed by demultiplex writers while sharing strict validation semantics with `FASTQReader`.

The API supports:

- one or multiple input URLs;
- gzip auto-decompression;
- strict four-line records for the demultiplexing use case;
- header and separator validation;
- exact sequence/quality length validation;
- file path and line number in every error;
- cancellation through stream termination; and
- no implicit skipping of truncated input.

Wrapped FASTQ remains supported by the existing normalized `FASTQReader`. The raw stream intentionally rejects wrapping because downstream demultiplex writers preserve four-line records. The distinction is explicit in names and documentation.

### 3. bounded test process ownership

Cross-process test helpers own an explicit `close()` operation. Cleanup writes the release sentinel, polls for a short deadline, terminates the process tree if needed, and fails the test through the calling test rather than blocking in `deinit`. `deinit` performs only nonblocking best-effort termination.

### 4. one scientific process executor

`NativeToolRunner` gains a generic streamed file-output method accepting an executable URL, arguments, output URL or already-open output handle, environment, working directory, timeout, tool name, and stderr bound. It uses the same pipe drain, cancellation state, process registry, and result type as `runProcess`.

Scientific workflow code may not instantiate `Process` directly. A source test maintains a narrow allowlist for the executor implementation, runtime discovery, container runtime adapters, and test fakes. Confirmed decompression and mapping-summary callers migrate immediately; remaining sites are audited and moved in later bounded groups.

### 5. exact leaf provenance policy

The policy registry gains entries keyed by the full command path for every scientific leaf. Each entry states whether the leaf is inspect-only, metadata-writing, or scientific-data-writing and names its writer/publication strategy.

A recursive ArgumentParser inventory test fails when:

- a production leaf lacks an exact policy;
- a policy names no current leaf;
- a data-writing leaf has no provenance writer declaration; or
- an inspect-only leaf is known to create an output.

Top-level fallback remains available for display and compatibility, but it cannot satisfy the coverage gate for a data-writing leaf.

### 6. later `ScientificPublicationTransaction`

The coordinated transaction tranche adds focused types rather than one monolith:

- `FilesystemIdentity`: device, inode, type, size, and modification identity obtained without following symlinks.
- `DirectoryHandle`: descriptor-relative child open, create, fsync, rename, and removal.
- `BundleMutationLock`: adjacent no-follow lock file plus `flock`, shared by app and CLI.
- `PublicationGeneration`: staged/final/retired paths and checksummed artifact inventory.
- `ScientificPublicationJournal`: immutable schema-versioned intent and attestation record.
- `ScientificPublicationTransaction`: prepare, validate, commit, recover, and retire orchestration.
- `ProvenanceInputAttestation`: pre-execution local input generation descriptor and completion revalidation.

The transaction state machine is:

```text
absent
  -> prepared (staged generation complete and attested)
  -> committed (final name identifies the new generation)
  -> finalized (retired generation removed, journal archived/removed)
```

The journal is immutable once published. Recovery infers progress from journal attestations and current directory-entry identities; it does not rewrite a mutable phase field. If neither the old nor new generation matches its attestation, recovery returns an ambiguity error and preserves all artifacts.

The commit unit includes scientific payloads, the manifest, root provenance, rollups, focused sidecars, and signing artifacts. A consumer never observes a completed manifest that declares a payload generation with provenance from another generation.

### 7. input attestation

Before a scientific command launches, local inputs are hashed and identified. At completion, the workflow verifies that each path still names the same file generation. Stable inputs use the pre-execution checksum in provenance. Changed inputs cause `inputChangedDuringExecution` unless the workflow consumed an immutable staged snapshot; in that case provenance points to the final stored snapshot and records the source-to-snapshot relationship.

## Error handling

- SQLite checkpoint, quick-check, fsync, publish, reopen, and enrichment errors are fatal.
- FASTQ structural errors are fatal in strict raw-record workflows and include URL plus line number.
- Process timeout and cancellation terminate the complete process tree and return distinct errors.
- Provenance policy absence is a test and release-gate failure.
- Transaction recovery never deletes unattested artifacts.
- Rollback is permitted only while the destination generation still matches the identity captured by the transaction.
- Cleanup failure after a proven commit is reported as retained recoverable state, not as scientific publication failure.

## Testing strategy

### Immediate tranche gates

- Focused SQLite publication and caller tests pass, including injected ExFAT fallback and failed checkpoint cases.
- Exact demultiplex tests reject malformed and truncated FASTQ and leave no completed outputs.
- The complete cohort-alignment test suite terminates within its test timeout.
- Native process tests pass with simultaneous stdout/stderr above pipe capacity, timeout, and cancellation.
- Recursive CLI leaf provenance coverage has no missing or stale policies.
- Existing focused MHC viewport, workbook, bundle-loader, and full-length pipeline tests remain green because the hardening work is cross-cutting but must not alter their scientific semantics.

### Later tranche gates

- Crash injection at every state transition yields a complete old generation, a complete new generation, or an explicit ambiguity with no deletion.
- Separate-process mutation tests prove no lost manifest updates.
- Payload and final-path provenance checksums agree after commit and recovery.
- Symlink and destination-race tests cannot escape the bundle root or overwrite an unrelated entry.
- APFS and simulated ExFAT rename capabilities both pass.

## Rollout and observability

The immediate tranche does not change bundle schemas. It adds stricter failures where the current behavior silently succeeds on malformed FASTQ or SQLite errors. Error messages must identify the affected file and operation so users can distinguish damaged input, unsupported filesystem behavior, and tool failure.

The later transaction journal has an explicit schema version and records the publication mechanism (`rename-swap`, `exclusive-reservation-generation-rotation`, or a future supported mechanism). Provenance records the actual mechanism used rather than claiming atomic exchange unconditionally.

Recovery diagnostics include transaction ID, bundle path, attested generation identities, observed identities, and retained paths. They must not include scientific sequence contents or secrets.

## Stop/go boundaries

### Immediate tranche go criteria

- The candidate-feature branch is otherwise ready for debug testing.
- Focused feature tests are green before hardening begins.
- SQLite and FASTQ changes can be committed independently and reverted independently.

### Immediate tranche stop criteria

- A change requires altering candidate naming, genotype interpretation, workbook semantics, or another product surface.
- The SQLite publisher cannot prove safe recovery on an injected failure.
- Strict FASTQ parsing changes valid-record counts on a well-formed fixture.
- The aggregate verification hang persists after bounded helper cleanup.

### Later transaction go criteria

- At least one uninterrupted 6–8 hour implementation block remains.
- The transaction API and state machine receive an independent safety review before caller migration.
- Crash, race, and ambiguity tests pass for the primitive itself.

### Later transaction stop criteria

- Only part of a payload/manifest/provenance commit unit can be migrated.
- Recovery relies on mutable phase markers, lexical path checks, or unattested deletion.
- A caller needs product-specific semantics inside the generic transaction layer.

## Recommended sequence

For the remaining overnight window:

1. Bound the hanging cross-process test cleanup.
2. Harden SQLite publication and make NVD SQLite failures explicit.
3. Add and adopt strict raw FASTQ streaming in exact demultiplexing.
4. Add the generic safe process file-output API, migrate the two confirmed risky sites, and install the direct-`Process` guardrail.
5. Add exact leaf provenance coverage if time remains.
6. Begin the coordinated transaction tranche only if its full primitive, recovery tests, and independent review can be completed without rushing caller migration.

This ordering yields independently valuable, centrally enforced improvements while avoiding a half-installed transaction architecture.
