# Codex Triage of Claude Review Findings

Date: 2026-05-15
Repository commit: `5797eb09`

Claude's review artifacts were found at
`.claude/worktrees/fervent-boyd-45e388/review/2026-05-15/`; the requested
root path `review/2026-05-15/` is not present in this checkout.

This triage was produced by five independent read-only review passes:

- architecture and dead code
- AppKit, HIG, dialogs, and wizards
- pipelines, provenance, cancellation, and CLI parity
- IO and bioinformatics formats
- plugins, runtime polish, and tests

No source code was changed as part of the review. Representative claims were
checked against the current repo root, which matches the Claude review commit.

## Decision Rules

Treat the following as implementation blockers or near-blockers:

- Silent wrong scientific output.
- Missing reproducibility provenance for workflows that create, import,
  transform, export, or wrap scientific data.
- CLI/app parity gaps that make scripted workflows produce different scientific
  artifacts from GUI workflows.
- Cancellation or runtime-state bugs that make the app lie about a running
  operation.
- Broken IO for common bioinformatics formats or common compressed inputs.

Treat the following as important but secondary:

- Large structural refactors whose benefit is maintainability rather than
  immediate correctness.
- UI consistency work that is best solved by introducing a small shared shell.
- Test cleanup that depends on deleting or keeping production code.

Reject or defer findings that are only stylistic, depend on a product roadmap
that does not exist yet, or propose broad rewrites where a narrower pattern will
solve the problem.

## Implement First

### Scientific Correctness and Provenance

Implement these before broad architecture or polish work.

| Finding | Decision |
|---|---|
| `P0-pipeline-managed-assembly-skips-virtual-fastq-materialization` | Implement. The GUI managed assembly path and `lungfish assemble` pass request inputs directly to `ManagedAssemblyPipeline`; derived virtual FASTQ bundles can therefore assemble `preview.fastq`. |
| `lungfish assemble` provenance gap | Treat as blocking even though Claude bundled it under the assembly finding. `assemble` creates scientific output and must write provenance under the AGENTS.md rule. |
| CLI derived-bundle materialization gaps | Implement as a broader blocker. `classify`, `map`, and `assemble` use `SequenceInputResolver.resolvePrimarySequenceURL` in important paths; derived-bundle resolution must preserve the exact derived payload, not fall back to a root or preview payload. |
| `P2-pipeline-orient-and-minimap2-pipelines-no-provenance` | Promote to P1/blocking. GUI Orient and legacy Minimap2 produce transformed scientific data without provenance. |
| `P2-cli-parity-markdup-pipeline-divergence` | Promote. `markdup` transforms BAM data; if the CLI bypasses the GUI pipeline and writes no provenance, it violates the provenance requirement. |
| `P1-cli-parity-specific-exit-codes-unused` | Implement incrementally. Scripted scientific workflows need stable machine-readable failures. |

### Pipeline Reliability

| Finding | Decision |
|---|---|
| `P1-pipeline-missing-cancel-callbacks` | Implement. Verified for Minimap2, ManagedMapping, MAFFT, Orient, SequenceAnnotation, and ViralRecon. |
| `P1-pipeline-managed-mapping-pipeline-no-cancel-handler-inside` | Split. First wire GUI cancel callbacks; then fix subprocess cancellation more broadly, including `CondaManager.runTool`. |
| `P1-pipeline-operationcenter-coverage-gaps-by-pipeline` | Split. Cancellation gaps belong with the P1 cancellation work. Log-only gaps are lower-priority UX cleanup. |

### IO and Bioformat Correctness

| Finding | Decision |
|---|---|
| `P1-io-gzip-lines-yields-spurious-empty-lines` | Implement first in the IO cluster. It is foundational and can corrupt FASTQ state machines. |
| `P1-io-gziindex-unaligned-load` | Implement. Low-effort, high-reliability fix for bgzip FASTA random access. |
| `P1-io-fasta-reader-ignores-gzip-extension` | Implement with transparent gzip support and tests. |
| `P1-io-bed-and-gff-no-gzip-support` | Implement with FASTA gzip support as a consistent compressed-text-format pass. |
| `P1-io-fasta-index-builder-loads-whole-file` | Implement streaming `.fai` construction and compare against `samtools faidx`. |
| `P1-io-bigwig-reader-broken-and-unused` | Implement by deleting or marking `BigWigReader` unavailable. Do not delete BigBed in the same change without a separate review. |
| `P2-io-vcf-structural-variant-end-and-classification` | Implement, but coordinate `VCFVariant`, `VariantDatabase.classifyVariant`, UI labels, and tests. |
| `P2-io-vcf-filter-line-id-without-comma` | Implement. |
| `P2-io-fasta-header-splits-on-space-only` | Implement for FASTA, FAI, and FASTQ header parsing. |
| `P2-io-search-like-pattern-injection` | Implement. This is not SQL injection, but unescaped `%` and `_` broaden searches and delete-by-prefix behavior. |

Merge `P2-io-fastq-zero-length-record-quality-collision` into the gzip-lines
fix/test work. Split `P2-io-genbank-loads-whole-file-and-nested-complement-loses-strand`:
streaming GenBank parsing is worth doing; mixed-strand per-segment support
requires a model/API change and should be separate.

### Runtime and Plugin Reliability

| Finding | Decision |
|---|---|
| `P1-plugins-pack-install-no-atomicity` | Implement. Failed pack installs leave partial conda environments and stale status cache. |
| `P1-runtime-plugin-pack-orphan-env-hashes-leaked` | Merge with install atomicity plus a UI recovery/hide/reclaim path. |
| `P1-runtime-database-recommended-exceeds-system-ram` | Implement. The recommendation threshold currently picks a 67 GB database on a 48 GB machine. |
| `P2-plugins-conda-root-env-override-bypasses-validation` | Implement. Apply the same no-spaces validation used by GUI-selected storage roots. |

### Module Boundaries and Dead Code

| Finding | Decision |
|---|---|
| `P1-architecture-lungfishcore-imports-appkit` | Implement early. Core models should not import AppKit. Move UI adapters outward. |
| `P1-architecture-misplaced-services-in-lungfishapp` | Implement as a boundary refactor, preserving provenance behavior in data-writing services. |
| `P1-architecture-cli-imports-lungfishapp` | Implement after moving pure services out of `LungfishApp`. |
| `P1-architecture-operationcenter-in-downloadcenter` | Implement as a small file split without redesigning the singleton. |
| `P1-architecture-resource-binary-duplication` | Implement after fixing any scripts that still reference root resources. |
| `P2-architecture-lungfishui-and-lungfishplugin-dead-modules` | Delete unless there is an immediate product plan to revive them. Current production code has no consumers. |
| `P1-plugins-builtin-plugins-never-registered` | Merge into dead-module cleanup. Prefer deletion over wiring a parallel plugin API. |
| `P2-plugins-container-tool-plugin-dead` | Delete with dead-code cleanup unless a declarative container-tool roadmap exists. |
| `P2-dead-code-unused-typealiases` | Implement. |
| `P3-architecture-dead-protocols` and `P3-dead-code-unused-methods-and-decls` | Implement after checking protocol requirements and test-only call sites. |

For `P2-dead-code-unreferenced-modules`, do not delete schema code blindly.
`WorkflowConfigurationPanel` and `SnakemakeRunner` appear test-only, but
`NextflowSchemaParser` and `UnifiedWorkflowSchema` are still used by
`NFCoreRegistry` and have legitimate model coverage.

### AppKit and Polish Quick Wins

| Finding | Decision |
|---|---|
| `P2-appkit-hig-destructive-action-flag-missing` | Implement. Six destructive alert buttons lack `hasDestructiveAction`; one correct exemplar exists. |
| `P2-appkit-hig-deprecated-textured-segment-button-style` | Implement, but retitle. `NSButton` `.texturedRounded` is deprecated; segmented `.texturedRounded` is stale/inconsistent rather than SDK-deprecated. |
| `P1-dead-code-runmodal-violations` | Implement as sheet migrations, preferably when touching affected dialogs/import sheets. |
| `P2-runtime-welcome-install-button-shown-when-ready` | Implement. The Ready state should not keep a primary Install action. |
| `P2-runtime-remove-buttons-use-accent-not-destructive-color` | Implement with visual verification. A global orange tint appears to override destructive intent. |
| `P3-runtime-tools-menu-submenu-ellipsis` | Implement. Submenu titles should not also use an ellipsis. |
| `P3-runtime-welcome-window-content-overflow-not-scrollable` | Implement opportunistically with a scroll view or a route to Plugin Manager. |

Treat `P2-dead-code-wants-layer-explicit` as low-priority cleanup, not as a
release-critical deprecation fix. Smoke-test affected custom views.

## Implement, But With Revised Scope

### Dialog and Wizard Consolidation

Implement the consolidation idea, but do not treat the current P1 severity as
release-blocking.

| Finding | Revised Decision |
|---|---|
| `P1-dialogs-wizardsheet-framework` | Downgrade to P2. Build a narrow shared shell: header, scroll body, footer/status, and embedded-run contract. Start with Orient/EsViritu, then Classification/TaxTriage. Do not force ViralRecon early. |
| `P1-dialogs-import-sheet-framework` | Downgrade to P2. CZ-ID, NAO-MGS, and NVD imports are near-duplicates and already share validation concepts. Fold in CZ-ID `runModal()` migration and preserve provenance. |
| `P2-dialogs-mapreads-mapping-duplicate` | Implement first. Delete dead `MapReadsWizardSheet` before consolidating mapping UI. |
| `P2-dialogs-reference-picker-adoption` | Merge into the wizard work. Scope Mapping first; handle ViralRecon's local FASTA branch later. |
| `P2-dialogs-run-button-label-drift` | Merge into shell work with a taxonomy: `Run` for pipelines, `Apply` for filters, `Save` for persistence, `Search`/`Download Selected` for database search. Do not blanket-rename every primary button. |
| `P2-dialogs-sheet-sizing-drift` | Merge into shared shell sizing. Do not force table/query dialogs into wizard dimensions. |
| `P2-dialogs-validation-pattern` | Merge into the shell/state work. |

Do not implement `P2-architecture-dialog-pattern-inconsistency` literally as
"convert every dialog to Presenter+State+View." Use Presenter+State where it
removes duplicated lifecycle code or makes validation testable.

### Large Architecture Refactors

| Finding | Revised Decision |
|---|---|
| `P0-architecture-appdelegate-god-object` | Valid, but not a standalone P0 blocker. Do it in phases after module-boundary work reduces the file's responsibilities. |
| `P1-architecture-fat-fastq-services` | Valid. Merge with the `LungfishApp/Services` to `LungfishWorkflow` cleanup. Preserve and retest provenance. |
| `P1-architecture-fat-viewer-files` | Valid. Split by existing viewer responsibility boundaries when touching those areas; avoid a giant mechanical-only PR. |
| `P2-architecture-fat-bundle-databases` | Valid as maintainability debt. Split by schema/query/import boundaries when working in those files. |
| `P2-architecture-inconsistent-pipeline-shapes` | Do not force every pipeline into one type shape. Define a small taxonomy: stateless command builders, stateful runners, and actors where isolation is needed. |

## Defer

| Finding | Reason |
|---|---|
| `P2-pipeline-spades-hardcoded-to-apple-container-runtime` | The current normal GUI assembly route appears to use managed assembly; `SPAdesAssemblyPipeline` looks legacy/test-only. Defer unless that path is revived. |
| `P2-cli-parity-runner-adapter-fragility` | Real, but fix workflow parity/provenance first. |
| `P2-cli-parity-extract-sequence-output-mismatch` | Defer until higher-risk CLI provenance/materialization issues are closed. |
| `P2-pipeline-cli-cannot-reach-spades-and-demux-scout` | Demux scout is not blocking unless it writes/export results; require provenance for any future output. |
| `P2-plugins-pack-registry-hardcoded` | True, but not a reliability defect while pack changes ship with app releases. Revisit with dynamic/offline/admin catalog work. |
| `P3-plugins-no-update-notifications` | Depends on mutable pack catalog work. |
| `P2-runtime-welcome-status-pill-visual-inconsistency` | Real polish issue; bundle after misleading actions are fixed. |
| `P2-dialogs-fastq-import-config-appkit` | AppKit is acceptable in this app. Revisit after `WizardSheet` exists; the issue is divergent layout/validation, not AppKit itself. |
| `P3-dialogs-state-restoration` | Defer. Restoring scientific parameters can be risky; only consider in-session, keyed by tool and dataset. |
| `P2-tests-fragile-source-string-contains-assertions` | Migrate gradually. Some checks are legitimate sanitizer/config assertions; do not bulk-delete. |
| `P2-tests-compile-only-empty-input-tests` | Replace with mock behavior if practical, otherwise delete with test cleanup. |
| `P3-tests-duplicate-primer-scheme-fixture` | Bundle with fixture hygiene. |
| `P3-tests-duplicate-coverage-translation-and-alphabet` | Reassess after `LungfishPlugin` deletion removes duplicate coverage. |
| `P3-dead-code-stale-root-planning-docs` and `P3-dead-code-todo-fixme-markers` | Docs/housekeeping batch, not engineering blockers. |

For `P2-io-kraken2-output-parser-loads-whole-file`, the parser does load full
files, but current production extraction/index paths already stream. Defer as
public API cleanup rather than treating it as a blocking workflow defect.

For `P2-io-test-coverage-gaps-by-format`, keep a corrected tracking issue.
Some claims are stale, but real gaps remain for BigWig/BigBed, FASTAIndex,
gzip chunk boundaries, FASTA gzip/tab headers, VCF SV/FILTER edges, and
GenBank streaming/mixed-strand cases.

## Reject or Rework as Filed

| Finding | Decision |
|---|---|
| `P3-appkit-hig-deprecated-default-button-cell` | Reject as filed. `NSWindow.defaultButtonCell` is not SDK-deprecated in the checked Xcode 26.5 headers/docs. Do not remove without visual keyboard/default-button testing. |
| `P3-appkit-hig-alerts-missing-branding` | Reject blanket edits. `NSAlert` already uses the app icon by default. If needed, create a central alert factory/policy rather than 25 one-line branding calls. |
| `P3-runtime-file-menu-save-icons-wrong-glyph` | Reject from source evidence. `MainMenu.swift` does not assign explicit Save/Save As images. If the live app shows a wrong glyph, file a narrower runtime bug with a screenshot. |
| "Make every pipeline an actor" | Reject. Use the pipeline taxonomy described above. |
| "Convert every dialog to Presenter+State+View" | Reject. Use shared shells and testable state where they remove real duplication. |

## Suggested Execution Order

1. Fix scientific-output blockers: assembly materialization, CLI derived-bundle
   materialization, `assemble`/Orient/Minimap2/markdup provenance.
2. Fix foundational IO correctness: gzip line preservation, GZI unaligned
   loads, compressed FASTA/BED/GFF/GTF support, streaming FASTA indexing, VCF
   edge cases.
3. Fix operation cancellation and runtime reliability: missing cancel callbacks,
   subprocess cancellation, plugin pack install atomicity, orphan env recovery,
   RAM recommendation.
4. Clean module boundaries: remove AppKit from Core, move pure services out of
   `LungfishApp`, remove the CLI dependency on `LungfishApp`, split
   `OperationCenter`.
5. Delete dead modules and tests if no product owner wants `LungfishUI` or
   `LungfishPlugin` revived.
6. Land low-risk AppKit polish: destructive flags, textured style replacement,
   runModal-to-sheet migrations, welcome/plugin manager action fixes.
7. Introduce `WizardSheet` and `ImportSheet` shells and migrate in phases.
8. Split `AppDelegate`, FASTQ services, viewer files, and database files only
   after correctness and boundary prerequisites are in place.
