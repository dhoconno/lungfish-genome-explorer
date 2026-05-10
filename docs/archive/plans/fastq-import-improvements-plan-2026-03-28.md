# FASTQ Import Improvements Plan (2026-03-28)

## Scope
Implement the requested FASTQ import/operations improvements with emphasis on:
- Operations Panel overdraw fix (disclosure triangle instead of More/Less text),
- ingest I/O path optimization (no upfront source copy; temp workspace on source volume),
- recipe command persistence and inspector visibility,
- making recipe tools available in FASTQ Operations,
- orchestration/performance strategy for multi-sample imports.

## Constraints and Principles
- Preserve import correctness and cancellation semantics.
- Keep original source FASTQs immutable.
- Persist reproducibility metadata (tool, version, command line, duration) for recipe-applied imports.
- Avoid introducing cross-bundle manifest schema conflicts.

## Work Plan

### 1) Operations Panel UI overdraw fix
1. Replace text-based More/Less control with a disclosure-style control in the Operation column.
2. Keep current row expansion behavior but remove text-button overlap risk by using icon-only disclosure state.
3. Validate row-height recalculation and clipping at default and expanded sizes.

Files:
- `Sources/LungfishApp/Views/Operations/OperationsPanelController.swift`

### 2) Ingestion I/O path optimization
1. Replace `FileManager.default.temporaryDirectory` workspace with a same-volume workspace rooted via item-replacement semantics using input FASTQ URL as anchor.
2. Remove upfront copy of R1/R2 into temp workspace for `ingestAndBundle(pair:...)`.
3. Run first recipe step(s) directly against source inputs; write outputs into workspace.
4. Ensure no source deletion by setting pipeline `deleteOriginals` appropriately when inputs are source files.
5. Keep cleanup semantics for success/failure/cancel.

Files:
- `Sources/LungfishApp/Services/FASTQIngestionService.swift`

### 3) Recipe command persistence and inspector display
1. Extend `RecipeStepResult` with an optional `commandLine` field.
2. Populate `commandLine` for recipe steps executed in:
   - materialized recipe pipeline,
   - delayed-interleave VSP2 paired-prefix execution.
3. Persist this metadata through existing ingestion sidecar save path.
4. Surface command lines in Inspector Document section under the applied recipe step list.

Files:
- `Sources/LungfishIO/Formats/FASTQ/FASTQMetadataStore.swift`
- `Sources/LungfishApp/Services/FASTQDerivativeService.swift`
- `Sources/LungfishApp/Services/FASTQIngestionService.swift`
- `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`

### 4) FASTQ Operations parity with recipe tools
1. Add Human Read Scrub operation to FASTQ Operations sidebar categories and request builder.
2. Provide minimal scrub parameters in UI (DB selection default + remove/mask toggle).
3. Verify operation request wiring executes through existing derivative service path.

Files:
- `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`

### 5) Multi-sample orchestration strategy (evaluation + plan)
1. Evaluate local orchestrator options:
   - current in-app queueing,
   - bounded in-app parallelism,
   - Nextflow local executor integration.
2. Compare on: startup overhead, failure/cancel UX, per-sample observability in Operations Panel, provenance capture complexity, reproducibility, packaging burden, and throughput.
3. Produce recommendation and phased implementation path.
4. Keep current implementation on in-app orchestration for now; prepare a follow-up RFC for optional Nextflow backend.

Deliverable:
- add section to benchmark report with pros/cons and recommended path.

### 6) Compression/decompression and multithreading audit
1. Confirm pigz/parallel tools are used where available (`pigz=t`, tool thread flags).
2. Ensure human scrub thread count tracks available cores and remains configurable from centralized logic.
3. Document remaining opportunities (if any) in benchmark report.

## Execution Order
1. Operations Panel overdraw fix.
2. Ingestion temp/workspace + no-copy path.
3. Recipe command persistence + inspector display.
4. FASTQ Operations parity (Human Read Scrub UI).
5. Orchestration and compression/threading evaluation notes in report.
6. Build validation (`swift build -c debug`).

## Validation Checklist
- Operations panel row text no longer overlaps and disclosure control behaves correctly.
- Import with recipe succeeds from source FASTQs without temp copy.
- Workspace is created on same volume as source input when possible.
- Source FASTQs remain untouched after import.
- Recipe step command lines are present in persisted metadata and visible in Inspector.
- Human Read Scrub available and runnable from FASTQ Operations.
- Build succeeds.

## Implementation Status (2026-03-28)
- Done: Operations Panel disclosure control (More/Less replaced with disclosure triangle, overlap mitigated).
- Done: ingest path switched to source-in-place processing; temp workspace uses same-volume item-replacement directory when available.
- Done: recipe step command lines captured and persisted (metadata + import manifest), surfaced in Document Inspector.
- Done: Human Read Scrub exposed in FASTQ Operations UI and wired to existing derivative request path.
- Done: FASTQ statistics integrated into import completion path before bundle is shown in sidebar.
- Done: VSP2 ordering benchmark and delayed-interleave optimization implemented.
- Done: bounded multi-import scheduling added (imports queue via global slot coordinator to prevent CPU/disk contention).
- Pending: optional Nextflow backend RFC for large batch mode and richer adaptive per-step CPU budgeting.
