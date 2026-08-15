# Database-Aware Bracken Profile Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to execute this plan task-by-task.
> Each task begins with a committed or captured failing test state and receives
> separate specification and code-quality review before the next task begins.

**Goal:** Resolve automatic Bracken rank from stable database identity, preflight
the actual Kraken report and 150-base distribution, and persist/report completed
versus degraded profiling without losing valid Kraken output.

**Architecture:** Introduce small Codable request/resolution/outcome value types
in `LungfishWorkflow`, carry stable catalog/recipe identity through
`ClassificationConfig`, and make the structured result outcome the source of
truth for pipeline provenance, CLI behavior, and app/batch reporting. Kraken2 is
the hard-success boundary; every later Bracken problem becomes an explicit
degraded Kraken-only result, while sidecar or provenance persistence failure
remains a hard error.

**Tech Stack:** Swift 6.2, Foundation, Swift Argument Parser, XCTest, SwiftPM,
Kraken2 kreport/Bracken parsers, micromamba-managed Kraken2 and Bracken, Lungfish
canonical provenance envelopes

---

## Global constraints

- Work only in `.worktrees/bracken-profile-fix` on
  `codex/bracken-profile-fix`.
- Read length is always the explicit resolved value `150`. Do not inspect FASTQ
  lengths, infer lengths, or add mixed-length handling.
- Automatic rank is genus only for stable SILVA/Greengenes catalog IDs or their
  `.kraken2Special` recipes. Never match display-name substrings.
- Explicit rank is never rewritten. Supported Bracken ranks are exactly
  `D/P/C/O/F/G/S`; unsupported explicit ranks degrade before tool execution.
- A profiling command must not run unless the parsed kreport contains the exact
  resolved rank and `database150mers.kmer_distrib` is readable, regular, and
  non-empty.
- A degraded profile keeps report, Kraken output/index, result sidecar, and
  provenance. It never exposes a failed Bracken artifact as successful output.
- Every scientific output and transform must record exact argv/replay command,
  requested/default/resolved settings, stable database identity, managed runtime
  identity, inputs/outputs with checksums and sizes, exit status, wall time, and
  useful stderr.
- Use `apply_patch` for edits. Preserve unrelated user changes. Run
  `git diff --check` before every commit.

## Task 1: Bracken request, database capability, and durable outcome models

**Files:**

- Create: `Sources/LungfishWorkflow/Metagenomics/BrackenProfileModels.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationConfig.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationResult.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationConfig+SummaryParameters.swift`
- Test: `Tests/LungfishWorkflowTests/Metagenomics/ClassificationPipelineTests.swift`
- Test: `Tests/LungfishWorkflowTests/Metagenomics/TaxonomyExtractionTests.swift`
- Test: `Tests/LungfishWorkflowTests/Metagenomics/ConfigSummaryParametersTests.swift`

- [ ] **Step 1: Add failing capability and config tests**

Add tests for the following public behavior:

```swift
XCTAssertEqual(
    BrackenDatabaseCapabilities.resolve(
        catalogID: "kraken2-special-silva",
        installationRecipe: .kraken2Special(type: .silva),
        request: .automatic
    ).rank,
    .genus
)
XCTAssertEqual(
    BrackenDatabaseCapabilities.resolve(
        catalogID: "kraken2-special-greengenes",
        installationRecipe: .kraken2Special(type: .greengenes),
        request: .automatic
    ).rank,
    .genus
)
XCTAssertEqual(ordinaryResolution.rank, .species)
XCTAssertEqual(explicitGenus.rank, .genus)
XCTAssertEqual(explicitSpecies.rank, .species)
XCTAssertNil(BrackenDatabaseCapabilities.levelCode(for: .kingdom))
XCTAssertEqual(BrackenDatabaseCapabilities.levelCode(for: .domain), "D")
```

Extend the config Codable test to assert database catalog ID, installation
recipe, `goal: .profile`, automatic request, read length 150, and threshold 10
round-trip. Decode a legacy JSON fixture without the new optional fields and
assert it still succeeds.

- [ ] **Step 2: Run the model tests and verify RED**

Run:

```bash
swift test --filter 'ClassificationConfigTests|BrackenProfileModelTests|ConfigSummaryParametersTests'
```

Expected: compilation failures for missing Bracken request/capability APIs and
new config fields. Capture the failure in the task handoff.

- [ ] **Step 3: Implement the request and resolution values**

Create the new model file with:

- `BrackenRankRequest.automatic` and `.explicit(TaxonomicRank)`;
- `BrackenProfileRequest` with `.automaticDefault` resolving read length 150 and
  threshold 10;
- `BrackenProfileResolution` containing request, resolved rank, resolution source,
  read length, and threshold;
- a failable supported-level mapper for exactly `D/P/C/O/F/G/S`;
- `BrackenProfileState.notRequested/completed/degraded`;
- a stable `BrackenProfileDegradationReason` enum covering unsupported rank,
  missing kreport rank, unavailable distribution, unavailable tool, nonzero tool,
  missing output, and parse/merge failure;
- `BrackenProfileOutcome` constructors that require the resolution for completed
  and degraded outcomes and preserve reason/message/tool version.

The automatic resolver checks catalog ID first, then special recipe, then the
ordinary species fallback. Include a human-readable resolution-source value in
the result for provenance.

- [ ] **Step 4: Carry stable identity and request through config**

Add optional `databaseCatalogID`, `databaseInstallationRecipe`, and
`brackenProfileRequest` fields to `ClassificationConfig`. Extend its initializer
and `fromPreset` with defaulted parameters. Preserve the fields in every config
reconstruction, including `ClassificationResult.resolvingRelativeConfigURLs`.

Do not add new scientific flags to `kraken2Arguments()`. Extend config summary
parameters with goal, catalog ID/recipe, Bracken requested mode/rank, read length,
and threshold when profiling is requested.

- [ ] **Step 5: Persist a structured result outcome**

Add `profileOutcome` to `ClassificationResult`, defaulting to `.notRequested` at
the source-compatible initializer. Persist it in
`PersistedClassificationResult` as an optional field and implement compatibility
decoding:

- present field: use it;
- absent field plus an existing referenced Bracken file: infer completed with
  legacy automatic/species settings only as compatibility metadata;
- absent field and no existing Bracken file: infer not requested;
- never return a non-nil `brackenURL` merely because a missing path was stored.

Update `summary` and copyable-command fallback to use the structured state and
persisted resolved settings. A degraded summary must name the retained Kraken
classification and the Bracken reason.

- [ ] **Step 6: Verify GREEN and commit**

Run:

```bash
swift test --filter 'ClassificationConfigTests|ClassificationResultTests|ClassificationResultPersistenceTests|BrackenProfileModelTests|ConfigSummaryParametersTests'
git diff --check
```

Expected: all selected tests pass and legacy sidecars decode.

Commit:

```bash
git add Sources/LungfishWorkflow/Metagenomics/BrackenProfileModels.swift Sources/LungfishWorkflow/Metagenomics/ClassificationConfig.swift Sources/LungfishWorkflow/Metagenomics/ClassificationResult.swift Sources/LungfishWorkflow/Metagenomics/ClassificationConfig+SummaryParameters.swift Tests/LungfishWorkflowTests/Metagenomics/ClassificationPipelineTests.swift Tests/LungfishWorkflowTests/Metagenomics/TaxonomyExtractionTests.swift Tests/LungfishWorkflowTests/Metagenomics/ConfigSummaryParametersTests.swift
git commit -m "feat: model database-aware Bracken outcomes"
```

## Task 2: Preflighted Bracken execution and honest sample provenance

**Files:**

- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Native/ShellUtilities.swift` only if a small
  test seam is needed; the production Bracken call must pass `flags: ["-v"]`
- Modify: `Tests/LungfishWorkflowTests/Metagenomics/ClassificationPipelineProvenanceSourceTests.swift`
- Modify: `Tests/LungfishWorkflowTests/Metagenomics/ClassificationPipelineTests.swift`

- [ ] **Step 1: Extend the fake tool fixture and add failing pipeline tests**

Teach `FakeClassificationCondaFixture` to:

- write a configurable kreport rank (`G` or `S`);
- optionally create a non-empty `database150mers.kmer_distrib`;
- record or reject Bracken profiling calls;
- return `Bracken v3.0.1` only for `-v` and fail `--version`;
- optionally exit nonzero, omit output, or write malformed output.

Add tests that assert:

1. SILVA automatic selection invokes Bracken with `-l G -r 150 -t 10`.
2. An ordinary database invokes automatic `-l S`.
3. Explicit genus/species remains unchanged even when the database default is
   different.
4. Missing resolved rank skips Bracken and returns degraded with reason
   `rankAbsentFromReport`.
5. Missing/empty/non-regular `database150mers.kmer_distrib` skips Bracken and
   returns degraded with reason `distributionUnavailable`.
6. Unsupported explicit rank does not invoke Bracken or silently use `S`.
7. Nonzero, missing-output, and malformed-output Bracken runs return degraded,
   leave Kraken outputs, and do not expose `brackenURL`.
8. A successful run returns completed and merges Bracken reads.
9. Version detection captures `3.0.1` using `-v`.

- [ ] **Step 2: Run pipeline tests and verify RED**

Run:

```bash
swift test --filter 'ClassificationPipelineProvenanceSourceTests|BrackenProfilePipelineTests'
```

Expected: failures showing absent preflight/outcome behavior and the wrong
version flag. Keep the RED output in the implementation report.

- [ ] **Step 3: Make profile request resolution config-driven**

Keep `classify(config:)` Kraken-only. Make the canonical `profile(config:)`
consume `config.brackenProfileRequest ?? .automaticDefault`. Preserve a
source-compatible overload taking explicit read length/rank/threshold, but have
it create an explicit request and delegate; it must never run through the old
species fallback.

Resolve database capabilities once before provenance begins and add these
top-level parameters to `ProvenanceRecorder.beginRun`:

- `goal`;
- `databaseCatalogID` and serialized recipe;
- `brackenRankRequest` and explicit rank when present;
- `brackenResolvedRank` and capability source;
- `brackenReadLength: 150` and threshold;
- eventual profile state/reason in the final canonical envelope.

- [ ] **Step 4: Implement preflight and degraded execution**

After Kraken report parsing and before the Bracken profiling command:

1. validate the supported level mapping;
2. test `tree.nodes(at: resolvedRank).isEmpty`;
3. inspect the exact distribution path using resource values and file
   attributes, rejecting directories, symlinks, unreadable files, and zero size.

Record a `Lungfish Bracken Preflight` step for both pass and fail. Its argv must
include the kreport, database, read length, requested mode, and resolved rank.
Inputs include the checksummed kreport and distribution only when the latter
exists as a valid consumed file. It records wall time, exit status, and useful
stderr. Depend it on the Kraken step.

Only after successful preflight detect Bracken with:

```swift
detectToolVersion(
    toolName: "bracken",
    environment: Self.brackenEnvironment,
    condaManager: condaManager,
    flags: ["-v"]
)
```

Remove only `effectiveConfig.brackenURL` before a new attempt. Run the exact
resolved argv. Convert tool-unavailable/launch errors, nonzero exit, absent or
empty output, and parser errors into a failed Bracken step plus a degraded
outcome. Remove a failed current-run Bracken artifact so it cannot be reopened
as a profile. Do not throw after a valid Kraken report for these cases.

- [ ] **Step 5: Finish sample sidecar and provenance honestly**

Construct the result with its outcome before saving. Sidecar and compacted
Kraken outputs remain successful scientific outputs. For a completed profile,
complete the legacy run as `.completed`; for a degraded requested profile,
complete it as `.failed` while retaining successful Kraken steps/outputs. Save
the provenance in either case. Progress text ends with “Profiling complete” or
“Kraken classification complete; profiling degraded” as appropriate.

The canonical envelope inferred from the legacy run must have nonzero overall
exit status for degraded profiling, contain the exact failed/skipped preflight or
Bracken evidence, and retain checksummed Kraken outputs. Sidecar/provenance write
failure remains thrown and removes the success-looking sidecar as today.

- [ ] **Step 6: Verify GREEN and commit**

Run:

```bash
swift test --filter 'ClassificationPipelineProvenanceSourceTests|BrackenProfilePipelineTests|ClassificationPipelineErrorTests'
git diff --check
```

Expected: every new branch is green; degraded provenance is nonzero and valid
Kraken descriptors remain complete.

Commit:

```bash
git add Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift Sources/LungfishWorkflow/Native/ShellUtilities.swift Tests/LungfishWorkflowTests/Metagenomics/ClassificationPipelineProvenanceSourceTests.swift Tests/LungfishWorkflowTests/Metagenomics/ClassificationPipelineTests.swift
git commit -m "fix: preflight Bracken profiling by database rank"
```

## Task 3: CLI profile intent, resolved options, and degraded exit

**Files:**

- Modify: `Sources/LungfishCLI/Commands/ClassifyCommand.swift`
- Modify: `Tests/LungfishCLITests/CLIRegressionTests.swift`

- [ ] **Step 1: Add failing CLI parsing/config/provenance tests**

Add tests using `ClassifyCommand.parse` and focused internal helpers to assert:

- `--profile` with no `--bracken-level` produces `goal: .profile` and an
  automatic request;
- `--profile --bracken-level G` produces an explicit genus request;
- the selected registry database's version, digest, catalog ID, and recipe are
  copied into config;
- default options say automatic, explicit options omit rank unless the flag was
  supplied, and resolved options contain `G` for SILVA/Greengenes or `S` for an
  ordinary database;
- read length is resolved as 150 in config and provenance;
- degraded result provenance uses nonzero overall exit status, retains Kraken
  outputs, preserves failed/preflight pipeline-only steps, and does not synthesize
  a successful Bracken step;
- the terminal completion policy is success/zero only for completed requested
  profiles and warning/workflow-error for degraded profiles.

- [ ] **Step 2: Run CLI tests and verify RED**

Run:

```bash
swift test --filter ClassifyCommandMaterializationRegressionTests
```

Expected: failures for the current default `"S"`, classify goal, missing stable
identity, and forced exit-zero provenance.

- [ ] **Step 3: Build profile config from registry identity**

Change `brackenLevel` to `String?` with automatic help text. Validate an explicit
value by constructing `TaxonomicRank(code:)` and allowing the pipeline's
supported-rank preflight to produce an honest degraded result rather than
rewriting it.

When constructing the config, pass:

```swift
goal: profile ? .profile : .classify
databaseVersion: dbInfo.version ?? "unknown"
databaseCatalogID: dbInfo.catalogID
databaseInstallationRecipe: dbInfo.installationRecipe
databaseDigest: dbInfo.payloadDigest
brackenProfileRequest: profile ? resolvedCLIRequest : nil
```

Call the canonical config-driven `pipeline.profile(config:)` path.

- [ ] **Step 4: Make CLI provenance result-driven**

Update `writeProvenance` and all option helpers to derive requested/resolved rank,
read length, threshold, state, reason, database identity, and exit status from
`result.config` and `result.profileOutcome`. Preserve exact top-level and durable
argv. Reuse pipeline Bracken/preflight steps rather than inventing a successful
fallback. A completed Bracken output may still be represented as a canonical
step with checksummed input/output.

- [ ] **Step 5: Surface degradation and exit nonzero after persistence**

Print the result summary and valid output paths first. Then:

- completed profile: print profile success and return zero;
- classify-only: print classification success and return zero;
- degraded profile: print a warning that Kraken succeeded and Bracken did not,
  include the reason, never print the unconditional success line, and throw
  `CLIExitCode.workflowError.exitCode` after provenance is written.

Do not delete the output directory in this path.

- [ ] **Step 6: Verify GREEN and commit**

Run:

```bash
swift test --filter 'ClassifyCommandMaterializationRegressionTests|CLIClassificationFolderResolverTests'
git diff --check
```

Expected: config intent and provenance tests pass, including degraded nonzero
semantics.

Commit:

```bash
git add Sources/LungfishCLI/Commands/ClassifyCommand.swift Tests/LungfishCLITests/CLIRegressionTests.swift
git commit -m "fix: report degraded Bracken profiles in CLI"
```

## Task 4: Wizard identity, batch statuses, and classification root provenance

**Files:**

- Modify: `Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate+Classification.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsBatchResultStore.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/MetagenomicsBatchProvenanceWriter.swift`
- Modify: `Tests/LungfishAppTests/ClassificationWizardTests.swift`
- Create: `Tests/LungfishAppTests/ClassificationBatchOutcomeTests.swift`
- Modify: `Tests/LungfishAppTests/BatchAggregatedViewTests.swift`
- Modify: `Tests/LungfishWorkflowTests/MetagenomicsBatchProvenanceWriterTests.swift`

- [ ] **Step 1: Add failing wizard and batch model tests**

Assert a wizard-produced profile config carries an automatic request plus the
selected SILVA/Greengenes catalog ID and recipe, and its capability resolves to
genus.

Extend `MetagenomicsBatchSampleRecord` tests for optional `status` and `message`,
and `ClassificationBatchResultManifest` tests for optional outcome counts.
Decode a schema-1 fixture lacking the new fields to prove compatibility.

Add a pure batch-status formatter/policy test that turns completed, degraded, and
hard-failed samples into TSV statuses `ok`, `degraded`, and `failed`, includes
requested/resolved ranks and message, and requests warning completion whenever a
valid returned sample is degraded or any sample hard-failed.

- [ ] **Step 2: Add failing classification batch provenance test**

Build two tiny sample directories with canonical child envelopes: one completed
profile and one degraded profile with successful Kraken output. Write summary,
manifest, and SQLite fixtures. Assert a new API:

```swift
MetagenomicsBatchProvenanceWriter.writeClassificationBatchProvenance(
    batchRoot: batchRoot,
    manifest: manifest,
    summaryURL: summaryURL,
    sqliteURL: sqliteURL,
    command: ["LungfishApp", "classification-batch", "--output", batchRoot.path]
)
```

produces a root envelope containing:

- both child steps and outputs;
- original input descriptors;
- checksummed summary, manifest, and SQLite outputs;
- database name/version, goal, completed/degraded/failed counts, and resolved
  profile ranks in options;
- nonzero overall exit for any degraded requested profile;
- useful child stderr and total wall time.

- [ ] **Step 3: Run app/batch tests and verify RED**

Run:

```bash
swift test --filter 'ClassificationWizardTests|ClassificationBatchOutcomeTests|BatchAggregatedViewTests|MetagenomicsBatchProvenanceWriterTests'
```

Expected: missing identity propagation, manifest fields/policy, and provenance API
failures.

- [ ] **Step 4: Propagate automatic wizard intent**

Pass `db.catalogID`, `db.installationRecipe`, and
`.automaticDefault` into every wizard-generated profile config. Do not add a rank
control. Keep read length 150 invisible but explicit in the config.

- [ ] **Step 5: Persist honest batch outcome data**

Add an optional Codable classification status/message to sample records with
defaulted initializer arguments. Add optional completed/degraded/failed counts to
the classification manifest. Keep old JSON decodable. Write schema version 2 for
new classification batches.

Extract a focused formatter/policy so `AppDelegate+Classification` does not
duplicate scientific status logic. Add TSV columns:

```text
sample_id status profile_state requested_rank resolved_rank total_reads classified_reads classified_pct species_count dominant_species message
```

Returned degraded results stay in `successfulResults` for Kraken aggregation but
write `degraded`. Hard failures remain absent from loadable sample records and
write `failed` TSV rows.

- [ ] **Step 6: Surface single and batch warnings without deleting results**

For a single degraded result, display it and call
`OperationCenter.completeWithWarning` with the resolved rank/reason. For a batch
with at least one valid returned result, use `completeWithWarning` whenever any
sample is degraded, failed, or SQLite indexing warned; otherwise use `complete`.
Analysis manifest summary/parameters must include `profileState=degraded` and the
reason so `.completed` is not an unqualified profile-success claim. Do not remove
degraded sample directories.

- [ ] **Step 7: Write required batch-root provenance before UI completion**

Implement classification rollup beside the existing EsViritu rollup, using
child sample envelopes as evidence. Include the classification manifest itself
as an output. Call it after SQLite construction and before dispatching terminal
UI state. If root provenance cannot be written, mark the operation failed and
retain the batch/sample directories for diagnosis; do not present a successful
batch.

- [ ] **Step 8: Verify GREEN and commit**

Run:

```bash
swift test --filter 'ClassificationWizardTests|ClassificationBatchOutcomeTests|BatchAggregatedViewTests|MetagenomicsBatchProvenanceWriterTests|MetagenomicsWizardMultiBundlePickerSourceTests'
git diff --check
```

Expected: new schema round-trips, legacy schema decodes, UI policy is warning for
degradation, and root provenance is complete.

Commit:

```bash
git add Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift Sources/LungfishApp/App/AppDelegate+Classification.swift Sources/LungfishWorkflow/Metagenomics/MetagenomicsBatchResultStore.swift Sources/LungfishWorkflow/Metagenomics/MetagenomicsBatchProvenanceWriter.swift Tests/LungfishAppTests/ClassificationWizardTests.swift Tests/LungfishAppTests/ClassificationBatchOutcomeTests.swift Tests/LungfishAppTests/BatchAggregatedViewTests.swift Tests/LungfishWorkflowTests/MetagenomicsBatchProvenanceWriterTests.swift
git commit -m "fix: surface degraded Bracken batches"
```

## Task 5: Cross-layer regression review and verification

**Files:** all files changed in Tasks 1–4; no new behavior unless review finds a
requirement gap.

- [ ] **Step 1: Run the focused cross-layer suite**

```bash
swift test --filter 'ClassificationConfigTests|ClassificationResultTests|ClassificationResultPersistenceTests|BrackenProfile|ClassificationPipelineProvenanceSourceTests|ClassifyCommandMaterializationRegressionTests|ClassificationWizardTests|ClassificationBatchOutcomeTests|BatchAggregatedViewTests|MetagenomicsBatchProvenanceWriterTests|MetagenomicsWizardMultiBundlePickerSourceTests'
```

Expected: all focused tests pass.

- [ ] **Step 2: Run broader affected-target verification**

```bash
swift test --filter 'Classification|KreportParserTests|BrackenParserTests|MetagenomicsDatabaseTests|MetagenomicsBatchProvenanceWriterTests|ProvenanceEnvelopeTests|ProvenanceBuilderTests'
```

Expected: all selected tests pass; integration tests may skip only for their
documented missing live-tool/database prerequisites.

- [ ] **Step 3: Inspect provenance fixtures directly**

For one completed genus profile, one missing-rank degraded profile, and one
nonzero-Bracken degraded profile, decode the saved result and provenance in tests
and verify:

- requested and resolved rank agree across config/result/envelope;
- read length is 150 everywhere;
- `bracken -v` reports 3.0.1;
- exact attempted argv is retained;
- only genuine outputs have checksums/sizes and output roles;
- degraded overall status/exit is non-success while Kraken step/output is
  successful;
- batch root has final stored paths, not staging or temporary input paths.

- [ ] **Step 4: Run repository hygiene and inspect every commit**

```bash
git diff --check e3a13aa01db9a05a9d986a56e364e4e09988d0ee..HEAD
git status --short
git log --oneline --decorate e3a13aa01db9a05a9d986a56e364e4e09988d0ee..HEAD
git diff --stat e3a13aa01db9a05a9d986a56e364e4e09988d0ee..HEAD
```

Expected: no whitespace errors, no unrelated files, no uncommitted changes, and
logical docs/model/pipeline/CLI/app commits.

- [ ] **Step 5: Perform two-stage review**

Send the full diff and design acceptance criteria to a fresh specification
reviewer. Resolve every requirement gap with a new RED test and focused commit.
Then send the corrected diff to a separate code-quality reviewer. Resolve only
grounded correctness, compatibility, maintainability, and provenance findings;
rerun the focused suite after each correction.

- [ ] **Step 6: Final verification and branch handoff**

Run the exact focused and broader suites again after review. Report commit IDs,
test counts/results, any documented skips, and the branch/worktree to the parent
agent. Do not push, merge, or delete the worktree.
