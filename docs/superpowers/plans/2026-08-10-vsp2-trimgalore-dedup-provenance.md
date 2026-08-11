# VSP2 TrimGalore Deduplication Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to implement this plan task-by-task.
> Follow strict test-driven development and record RED/GREEN evidence.

**Goal:** Keep the efficient fused VSP2 fastp execution while making its
deduplication component, native JSON evidence, and real process provenance
durable; stop presenting the combined read loss as dedup-only; and disclose
TrimGalore's adapter/quality/short-read filtering at invocation.

**Architecture:** One physical fastp process produces one `RecipeStepResult`
with ordered logical components and actual execution evidence. Its native JSON
report flows through the existing auxiliary-artifact materializer into the final
bundle and canonical provenance. `RecipeAppliedInfo` distinguishes performed
deduplication from a valid standalone dedup read delta. A shared
`ClumpingTool` disclosure supplies conditional import-sheet copy and one
structured operation-log notice immediately before resolved TrimGalore use.

**Tech Stack:** Swift 6, AppKit, XCTest, Swift Package Manager, fastp,
TrimGalore, Lungfish provenance envelopes

## Global Constraints

- Do not split the VSP2 deduplication and trimming steps into multiple fastp
  processes or alter their scientific arguments, except replacing fastp's JSON
  `/dev/null` path with a retained report path.
- Keep `toolName`/`tool` equal to `fastp`; logical recipe components are
  additional metadata, not synthetic executions.
- Never label the fused input/output delta as deduplication-only or derive an
  exact dedup-only removal count from fastp's report.
- Missing or unreadable requested fastp JSON is a blocking import failure.
- Preserve actual exit status, start/end timestamps, duration, bounded stderr,
  argv, tool version, inputs, outputs, checksums, sizes, and durable artifact
  paths in provenance.
- New Codable fields must decode old bundles with empty or `nil` defaults.
- Emit one progress event and one duration per physical recipe process.
- Show the TrimGalore disclosure for explicit TrimGalore selection and emit the
  operation notice when either explicit or automatic selection resolves to
  TrimGalore.
- Follow RED-GREEN-REFACTOR for every behavioral change.

---

### Task 1: Add backward-compatible logical components and truthful summaries

**Files:**
- Modify: `Tests/LungfishIOTests/RecipeAppliedInfoSummaryTests.swift`
- Modify: `Tests/LungfishIOTests/FASTQMetadataStoreTests.swift` or the existing
  nearest `RecipeStepResult` Codable test file
- Modify: `Sources/LungfishIO/Formats/FASTQ/FASTQMetadataStore.swift`

- [ ] **Step 1: Add failing model and compatibility tests**

Add a `RecipeLogicalComponent: Codable, Sendable, Equatable` fixture with
`typeID` and `displayName`. Construct a fused `RecipeStepResult` carrying both
VSP2 logical components plus `exitStatus`, `stderr`, `startedAt`, and
`completedAt`. Assert JSON round-trip and `replacingAuxiliaryOutputs` preserve
every field. Decode legacy JSON without the additive fields and assert empty or
`nil` defaults.

Run:

```bash
swift test --filter 'RecipeAppliedInfoSummaryTests|FASTQMetadataStoreTests'
```

Expected: FAIL because the component and execution-evidence fields do not exist.

- [ ] **Step 2: Implement the additive metadata model**

Add the component type and optional/defaulted fields to `RecipeStepResult`, its
initializer, `CodingKeys`, custom decoder/encoder, and
`replacingAuxiliaryOutputs`. Keep `durationSeconds` for compatibility and make
the actual timestamps authoritative when present. Normalize stderr through the
repository's existing bounded-provenance convention.

Run the focused tests and expect PASS.

- [ ] **Step 3: Add failing dedup-summary tests**

Cover all three cases:

1. a standalone dedup result still returns `deduplicationSummary`;
2. a structured fused dedup-plus-trim result returns no dedup-only summary but
   reports that deduplication was performed in a combined pass;
3. a legacy fused record is conservatively recognized from its combined name or
   `--dedup` plus trimming arguments and likewise suppresses the false summary.

Run `swift test --filter RecipeAppliedInfoSummaryTests` and confirm RED.

- [ ] **Step 4: Implement truthful summary semantics**

Add a component lookup such as `didApplyDeduplication` and a combined-pass flag
or display value suitable for the inspector. Restrict `deduplicationSummary` to
standalone dedup steps. Leave `humanScrubSummary` and total net removal
unchanged.

Run the focused tests and expect PASS.

- [ ] **Step 5: Commit Task 1**

```bash
git diff --check
git add Sources/LungfishIO/Formats/FASTQ/FASTQMetadataStore.swift Tests/LungfishIOTests
git commit -m "fix: distinguish fused recipe deduplication"
```

---

### Task 2: Retain fastp JSON and real fused-process provenance

**Files:**
- Modify: `Tests/LungfishWorkflowTests/Recipes/RecipeEngineTests.swift`
- Modify: `Tests/LungfishWorkflowTests/Recipes/RecipeIntegrationTests.swift`
- Modify: `Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift`
- Modify: `Tests/LungfishWorkflowTests/FASTQBatchImporterRecipeIntegrationTests.swift`
- Modify: `Sources/LungfishWorkflow/Recipes/RecipeStepExecutor.swift`
- Modify: `Sources/LungfishWorkflow/Recipes/RecipeEngine.swift`
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`
- Modify only if needed: `Sources/LungfishWorkflow/Provenance/ProvenanceRecord.swift`

- [ ] **Step 1: Add failing fused-plan and execution tests**

Assert the fused plan carries ordered `fastp-dedup` and `fastp-trim` logical
components while retaining one physical entry and `--dedup`. In a runner-backed
execution test, assert fastp receives a real workspace path after `-j`, keeps
`-h /dev/null`, and returns the created JSON as an auxiliary output. Add failure
coverage for a successful process that omits or creates unreadable JSON.

Run:

```bash
swift test --filter 'RecipeEngineTests|RecipeIntegrationTests'
```

Expected: FAIL on missing components/report behavior.

- [ ] **Step 2: Implement fused report and execution evidence**

Extend `PlannedStep.fusedFastp` with ordered logical components. Extend
`StepOutput` only as needed to propagate the actual process exit status, stderr,
and start/end timestamps from `executeFusedFastp`. Allocate a collision-safe
workspace JSON filename, pass it to `-j`, retain `-h /dev/null`, validate the
JSON is present and readable after successful fastp execution, and attach it to
`auxiliaryOutputs`. Build the single `RecipeStepResult` from actual evidence.

Keep progress based on the physical plan count and emit one fused completion.

Run the focused recipe tests and expect PASS.

- [ ] **Step 3: Add failing provenance/materialization tests**

Assert batch import materializes the JSON under
`metadata/recipe-step-artifacts`, rewrites the durable `-j` argument, and writes
checksum and file size for the report. Assert canonical fastp provenance carries
the logical component IDs/names as resolved step metadata plus actual status,
timestamps, wall time, and bounded stderr—not synthesized success data.

Add an end-to-end VSP2 fixture assertion that one fastp argv contains both
`--dedup` and trimming options and that the final metadata has no false
dedup-only metric.

Run:

```bash
swift test --filter 'FASTQBatchImporterTests|FASTQBatchImporterRecipeIntegrationTests'
```

Expected: FAIL before provenance propagation is implemented.

- [ ] **Step 4: Implement canonical provenance propagation**

Update `recipeProvenanceSteps` to use the result's actual process evidence and
add logical component IDs/names to the step's canonical resolved metadata. Use
the existing auxiliary materializer and path-rewrite pipeline; do not duplicate
artifact storage. Ensure the final bundle descriptor is calculated from the
staged artifact but points to its published path.

Run all Task 2 focused tests and expect PASS.

- [ ] **Step 5: Commit Task 2**

```bash
git diff --check
git add Sources/LungfishWorkflow Tests/LungfishWorkflowTests
git commit -m "fix: retain fused fastp execution evidence"
```

---

### Task 3: Disclose resolved TrimGalore filtering and update presentation

**Files:**
- Modify: `Tests/LungfishWorkflowTests/FASTQClumpingToolTests.swift`
- Modify: `Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift`
- Modify: `Tests/LungfishAppTests/FASTQImportConfigurationTests.swift`
- Modify: `Tests/LungfishAppTests/CLIImportRunnerTests.swift`
- Modify: `Tests/LungfishCLITests/ImportFastqCommandTests.swift`
- Modify: `Sources/LungfishWorkflow/Ingestion/ClumpingTool.swift`
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift`
- Modify: `Sources/LungfishApp/Services/CLIImportRunner.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`

- [ ] **Step 1: Add failing disclosure and combined-option tests**

Define one shared import-sheet disclosure and one operation notice on
`ClumpingTool`. Test that only TrimGalore has those strings. Add CLI argument
coverage for `--recipe vsp2-target-enrichment` together with
`--clumping-tool trim-galore`, including command parsing at the CLI boundary.

Add a structured `notice` import event test. Assert explicit TrimGalore and an
automatic choice resolving to TrimGalore emit it once immediately before the
storage invocation, while BBTools and `.none` do not.

Run:

```bash
swift test --filter 'FASTQClumpingToolTests|FASTQBatchImporterTests|CLIImportRunnerTests|ImportFastqCommandTests'
```

Expected: FAIL on the missing disclosure and notice behavior.

- [ ] **Step 2: Implement shared wording and structured notice**

Use these approved meanings:

- Import sheet: “Trim Galore also performs adapter detection/removal, quality
  trimming, and short-read filtering.”
- Operation log: “Trim Galore --clumpify also performs adapter/quality filtering
  and may remove short reads.”

Add a structured import-log event, JSON encoding/parsing, and Operation Center
handling. Resolve the clumping tool once for the invocation and emit the notice
immediately before `FASTQIngestionPipeline.run` when the resolved tool is
TrimGalore. Do not infer it from CLI argv and do not change TrimGalore arguments.

Run the focused tests and expect PASS.

- [ ] **Step 3: Add failing UI and inspector tests**

Add a testable configuration seam for the import-sheet note. Assert it is shown
for explicit TrimGalore and hidden for other explicit selections. Assert a
combined fastp result displays: “Performed in combined fastp pass; an exact
dedup-only removed count is unavailable.” Standalone dedup continues to show its
read delta.

Run:

```bash
swift test --filter 'FASTQImportConfigurationTests|RecipeAppliedInfoSummaryTests'
```

Expected: FAIL before UI presentation changes.

- [ ] **Step 4: Implement UI and inspector presentation**

Add a wrapping secondary `NSTextField` beneath the clumping selector, update it
when the popup changes, and keep layout stable when hidden. Update the inspector
to use the combined-pass status when deduplication ran without a valid standalone
summary.

Run all Task 3 focused tests and expect PASS.

- [ ] **Step 5: Commit Task 3**

```bash
git diff --check
git add Sources/LungfishWorkflow Sources/LungfishApp Tests/LungfishWorkflowTests Tests/LungfishAppTests Tests/LungfishCLITests
git commit -m "fix: disclose TrimGalore filtering during import"
```

---

### Task 4: Integration review, verification, and debug build

- [ ] **Step 1: Run the complete focused regression set**

```bash
swift test --filter 'RecipeEngineTests|RecipeIntegrationTests|RecipeAppliedInfoSummaryTests|FASTQMetadataStoreTests|FASTQClumpingToolTests|FASTQBatchImporterTests|FASTQBatchImporterRecipeIntegrationTests|FASTQImportConfigurationTests|CLIImportRunnerTests|ImportFastqCommandTests'
```

Expected: PASS with no unexpected skips in pure planning, model, argv, event,
and artifact-rewrite tests.

- [ ] **Step 2: Run broader package verification**

```bash
swift test
```

Expected: PASS. If a pre-existing unrelated failure occurs, record the exact
test and prove the focused set remains green before deciding whether it is in
scope.

- [ ] **Step 3: Have Sol perform final code and provenance review**

Review the full branch diff against the approved design and AGENTS provenance
requirements. Resolve every correctness or provenance finding through a new
RED/GREEN cycle, then rerun affected focused tests.

- [ ] **Step 4: Build the requested debug application**

```bash
scripts/build-app.sh --configuration debug
```

Expected: PASS and produce `build/Debug/Lungfish.app`.

- [ ] **Step 5: Verify the artifact and repository state**

```bash
test -d build/Debug/Lungfish.app
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' build/Debug/Lungfish.app/Contents/Info.plist
git diff --check
git status --short --branch
git log -5 --oneline
```

Expected: valid Lungfish debug bundle and clean feature branch containing the
design, plan, implementation, and any review-fix commits.
