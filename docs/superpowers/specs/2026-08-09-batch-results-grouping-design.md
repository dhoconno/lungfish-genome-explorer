# Batch Results Grouping — Design

**Date:** 2026-08-09 · **Branch:** `worktree-batch-results-grouping` · **Approved by user in session.**

## Problem

When a tool runs once per selected bundle (the multi-bundle fan-outs shipped in the 2026-08-08 campaign), each child run creates its own `Analyses/<tool>-<timestamp>/` directory. N samples produce N sibling folders at the Analyses root, distinguishable only by timestamp (user hit this with SPAdes). Kraken2/EsViritu/TaxTriage batches already do the right thing: one `Analyses/<tool>-batch-<timestamp>/` folder containing one subdirectory per sample.

## Goal

Every surface that processes multiple datasets in one user action groups its results as:

```
Analyses/<tool>-batch-<timestamp>/
  analysis-metadata.json            (tool, isBatch: true, created — written by AnalysesFolder)
  <original bundle name A>/…
  <original bundle name B>/…
```

Per-sample subdirectories (or files, for flat-file tools) are named by the **source bundle's display name**, sanitized, with `-2`/`-3` dedup on collision. Single-dataset runs and combined/pooled runs are unchanged.

## Non-Goals

Kraken2's single-run flat layout (inconsistent with its own batch sibling — follow-up, not touched). MAFFT / ONT-genotyping / 12S / MHC fixed-name folders (inherently single-result; Workflow Operations' missing collision uniquing is a separate ticket). TaxTriage (already correct). Migration of existing on-disk results (new runs only).

## Design

### 1. Shared helper (LungfishIO, `AnalysesFolder`)

Extract the per-sample subdirectory logic currently inlined at `AppDelegate+Classification.swift:730-755` into:

```swift
public static func batchSampleDirectory(named sampleName: String, in batchDirectory: URL) throws -> URL
```

Sanitizes `sampleName` (same character policy as the classification inline code), dedups collisions with `-2`, `-3`, … , creates the directory, returns its URL. A sibling `batchSampleFileURL(named:extension:in:)` covers flat-file outputs (Savont) with the same sanitize+dedup policy, creating no file (callers write it). Classification/EsViritu call sites are refactored onto the helper (behavior-preserving).

### 2. Mapping fan-out (`AppDelegate+ToolsMenu.swift`)

In `runManagedMapping`, when `plan.requests.count > 1`: create ONE `createAnalysisDirectory(tool: request.tool.rawValue, isBatch: true)` before the sequential loop; each child receives `batchSampleDirectory(named: <bundle display name>, in: batchDir)` as its output directory. The per-child `createAnalysisDirectory` call at :1094-1097 is bypassed in batch mode (kept for single runs). The bundle display name is the same one already used for the operation title and @RG SM tag. Combined mode unchanged.

### 3. Assembly fan-out (`MainSplitViewController+GenomicsDisplay.swift` / `MainSplitViewController.swift`)

`independentAssembleLaunchRequests` dispatch: create ONE batch directory up front; each child request carries `preferredOutputDirectory = batchSampleDirectory(named: <bundle display name>, in: batchDir)`. Fix the branch ordering at `GenomicsDisplay:1073-1081` so a provided `preferredOutputDirectory` wins over the per-child `createAnalysisDirectory` fallback (the fallback stays for single runs). The existing `uniqueAssemblyProjectName` dedup continues to feed `projectName`/op titles; directory naming uses the shared helper's dedup independently.

### 4. Savont / pbaa `.perInput` (`FASTQOperationPlanner.swift` + dispatch site)

When a `.perInput` split produces `totalRequestCount > 1`: the dispatch site (`GenomicsDisplay:991-1015`) creates ONE batch directory (tool name from the operation) and passes it as `baseOutputDirectory`. `outputParentDirectory` (:432-448) keeps its current shapes inside that root — Savont flat files, pbaa per-input directories — but per-input naming switches from input-file stem to **source bundle display name** where the input is bundle-derived (fall back to stem for loose files). Sanitize+dedup via the shared helper's policy.

### 5. Sidebar

No new rendering code expected: `buildBatchAnalysisNode`'s generic branch (`SidebarProjectScanner.swift:658-691`) already renders expandable batch groups with filesystem children — currently dead code, lit up by the new producers. Verify `appendBatchChildrenFromFilesystem` handles flat FILES (Savont) as children, not only directories; fix if not. Tests pin: batch row appears grouped, children named by bundle, non-batch single runs unaffected.

### 6. Error handling

Batch directory is created before the first child launches; child failure isolation is preserved (siblings' results remain; the failed child's subdirectory may contain partial output, consistent with current single-run failure behavior). If ALL children fail or the batch is cancelled before any child starts, the orchestrator removes the batch directory iff it contains no sample subdirectories (empty-batch cleanup). `analysis-metadata.json` alone does not count as content.

### 7. Testing

TDD per surface: two-bundle fan-out yields one `<tool>-batch-*` dir with two correctly-named children and no sibling `<tool>-<ts>` dirs (mapping, assembly, savont, pbaa); helper unit tests (sanitization, collision dedup, flat-file variant); classification/EsViritu refactor is behavior-pinned by their existing batch tests; sidebar scanner test for generic batch groups incl. flat-file children; empty-batch cleanup test. Green bar per campaign definition; zero new strict-concurrency warnings; house rules apply (OperationCenter update+log, no @unchecked Sendable).
