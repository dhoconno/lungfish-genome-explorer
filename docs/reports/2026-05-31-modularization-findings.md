# LungfishApp Modularization: Findings and Path Forward

**Date:** 2026-05-31
**Status:** Kernel extracted (LungfishKit); leaf extraction blocked by shared infrastructure; designed follow-up required

## What was done

1. **Split the seven giant source files** (AppDelegate 10K, AnnotationTableDrawerView 8.8K,
   SequenceViewerView 8.5K, MainSplitViewController 5.9K, InspectorViewController 5.2K,
   VariantDatabase 6K, FASTQDerivativeService 6.4K, plus SidebarViewController 5K) into
   focused files. Swift type-checks a file as a unit, so this directly reduces incremental
   recompile cost for edits in those areas. Pure mechanical, zero behavior change.
2. **Extracted `LungfishKit`**, a shared UI-kernel module that sits below `LungfishApp`
   and above LungfishCore/IO/Workflow. It holds 10 clean kernel pieces (~2,244 LOC):
   `WindowStateScope`, `SelectionIdentityStore`, `ColumnFilter`, `SplitPaneSizing`,
   `TwoPaneTrackedSplitCoordinator`, `TrackedDividerSplitView`, `MetadataColumnController`,
   `BatchTableView`, `ResultViewportController` (+ `BlastRequest`/`ResultExportFormat`/
   `BlastVerifiable`), and `PasteboardWriting`. It builds standalone (proving zero
   back-dependency on LungfishApp).

## Why leaf feature-module extraction is blocked

The plan was to extract leaf feature modules (12S results, Genotype, Phylogenetics, ...)
below LungfishApp. Investigation showed this is **not currently possible by moving feature
directories**, because every candidate leaf depends on shared LungfishApp-internal
infrastructure that is itself woven throughout the module:

- **12S results UI** references `ClassifierActionBar`, `BlastResultsDrawerTab`/`Container`
  (BLAST drawer widgets), `LungfishCLIRunner`, and `MinimumReadsThreshold` — all defined in
  LungfishApp and shared by 4-11 other result controllers that stay in LungfishApp. A module
  below LungfishApp cannot reference types defined in LungfishApp (that is the cycle).
- **Phylogenetics** references `FASTQOperationDialogState` and `AppUITestConfiguration`
  (app-internal).
- The shared widgets are not all cleanly promotable either: `BlastResultsDrawerTab`
  references `MetagenomicsFilePanelFactory`, and `LungfishCLIRunner` depends on
  `CLIImportRunner`, which depends on `OperationCenter` and the whole FASTQ-import event
  pipeline.

In short, LungfishApp has a dense shared-infrastructure layer (operation center, dialog
states, CLI runner, file-panel factories, BLAST/classifier widgets) that multiple feature
surfaces consume. Leaf extraction requires **first promoting that shared layer into the
kernel**, which is a large, behaviorally-sensitive refactor (it crosses the OperationCenter
and import-pipeline boundaries), not a mechanical move.

A prior survey called 12S "cycle-free"; that was inaccurate — it matched only the
lower-module types (correctly in LungfishIO) and missed the shared-widget and CLI-runner
coupling. Verified directly.

## Recommended path forward (a designed follow-up, not a blind change)

To make feature surfaces leaf-extractable, do this as its own reviewed effort:

1. **Promote the shared classifier/result UI cluster into LungfishKit**, untangling each
   dependency in order:
   - `ClassifierActionBar` (already clean: AppKit only) — move first.
   - `MinimumReadsThreshold` (clean, 33 LOC) — move.
   - Extract the pure CLI-binary-resolution logic from `CLIImportRunner` into a kernel
     helper, so `LungfishCLIRunner` can move without dragging `OperationCenter`/the import
     pipeline. (`LungfishCLIRunner` only needs the binary path, not the event pipeline.)
   - `BlastResultsDrawerTab`/`Container`/`ClassifierActionBar`: resolve the
     `MetagenomicsFilePanelFactory` reference (inject the panel factory via a protocol, or
     move a kernel-safe file-panel abstraction down). Then move the BLAST drawer cluster.
2. Once the shared cluster is in LungfishKit, extract leaf modules in order of
   independence, each with its own test target, each landing green:
   12S results -> Genotype results (+ its Inspector sections, breaking the Genotype<->Inspector
   cycle) -> Phylogenetics -> larger surfaces.
3. The central hubs (`ViewerViewController`, `InspectorViewController`, the Metagenomics
   batch controllers, `SidebarViewController`, `MainSplitViewController`) are architectural
   cores, not leaves; they stay in LungfishApp and compose the leaf modules. Extracting them
   is not "completing" modularization — it would be a different, riskier project.

## Net result of this effort

- Incremental builds for edits in the eight split files are meaningfully cheaper (smaller
  type-check units).
- LungfishKit is a real, clean shared module — the foundation the leaf extraction needs.
- The remaining leaf extraction is scoped, sequenced, and documented for a deliberate
  follow-up, rather than forced into a fragile state. Per the engineering principle that a
  clean, working module boundary beats a half-untangled one that breaks behavior.
