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

Add to `AnalysesFolder`:

```swift
public static func batchSampleDirectory(named sampleName: String, in batchDirectory: URL) throws -> URL
```

Sanitizes `sampleName` using `MetagenomicsSampleGrouper.sanitizeSampleId`'s character policy (replicated or shared — the grouper lives in LungfishApp, so AnalysesFolder gets its own copy of the policy with a cross-reference comment), dedups collisions with `-2`, `-3`, … against the batch directory's existing entries, creates the directory, returns its URL. **This sanitize+dedup policy is NEW logic in the helper, not an extraction**: the classification inline code at `AppDelegate+Classification.swift:730-737` performs neither (its names were sanitized upstream by the grouper and are unique by construction). Classification/EsViritu call sites adopt the helper anyway so all surfaces share one path; their behavior is pinned by existing batch tests. A sibling `batchSampleFileURL(named:extension:in:)` covers flat-file outputs (Savont) with the same sanitize+dedup policy, creating no file (callers write it). Classification/EsViritu call sites are refactored onto the helper (behavior-preserving).

### 2. Mapping fan-out (`AppDelegate+ToolsMenu.swift`)

In `runManagedMapping`, when `plan.requests.count > 1`: create ONE `createAnalysisDirectory(tool: request.tool.rawValue, isBatch: true)` before the sequential loop; each child receives `batchSampleDirectory(named: <bundle display name>, in: batchDir)` as its output directory. The per-child `createAnalysisDirectory` call at :1094-1097 is bypassed in batch mode (kept for single runs). The bundle display name is the same one already used for the operation title and @RG SM tag. Combined mode unchanged.

### 3. Assembly fan-out (`MainSplitViewController+GenomicsDisplay.swift` / `MainSplitViewController.swift`)

`independentAssembleLaunchRequests` dispatch: create ONE batch directory up front; each child request carries `preferredOutputDirectory = batchSampleDirectory(named: <bundle display name>, in: batchDir)`. Fix the branch ordering at `GenomicsDisplay:1073-1081` so a provided `preferredOutputDirectory` wins over the per-child `createAnalysisDirectory` fallback (the fallback stays for single runs). The existing `uniqueAssemblyProjectName` dedup continues to feed `projectName`/op titles; directory naming uses the shared helper's dedup. **Ordering invariant (binding):** both dedup passes must consume the bundle list in the same fixed order — the original `inputURLs` order — so a name colliding twice gets the same `-2`/`-3` suffix in both the folder name and the project name/op title. For assembly this holds naturally (sequential dispatch); the orchestrator must precompute all sample directory names in input order BEFORE dispatching children, never inside concurrently-running child tasks.

### 4. Savont `.perInput` (`FASTQOperationPlanner.swift` + dispatch site)

Savont is the ONLY tool that currently exercises a `.perInput` multi-bundle fan-out (`GenomicsDisplay:991-1015`, deliberately concurrent). pbaa has no multi-bundle path today (`PBAAClusteringRunRequest.inputFASTQURL` is singular; `.pbaa` takes the unsplit `default:` in `splitExecutionRequestsIfNeeded`) and is OUT of scope; if pbaa gains multi-input later it adopts this same pattern. When the Savont dispatch fans out N>1: the dispatch site creates ONE batch directory (tool "savont", `isBatch: true`) and passes it as `baseOutputDirectory`. `outputParentDirectory` keeps Savont's flat-file shape inside that root, but per-input naming switches from input-file stem to **source bundle display name** where the input is bundle-derived (fall back to stem for loose files), via `batchSampleFileURL`'s sanitize+dedup.

### 5. Sidebar

No new rendering code expected: `buildBatchAnalysisNode`'s generic branch (`SidebarProjectScanner.swift:658-691`) already renders expandable batch groups with filesystem children — currently dead code, lit up by the new producers. Verify `appendBatchChildrenFromFilesystem` handles flat FILES (Savont) as children, not only directories; fix if not. Tests pin: batch row appears grouped, children named by bundle, non-batch single runs unaffected.

### 6. Error handling

Batch directory is created before the first child launches; child failure isolation is preserved (siblings' results remain; the failed child's subdirectory may contain partial output, consistent with current single-run failure behavior). **Empty-batch cleanup** runs only after ALL children have reached a terminal state, never mid-flight: mapping and assembly perform the check at the end of their existing sequential loops; Savont's concurrent dispatch gains a completion barrier (a TaskGroup join or an all-children `awaitOperationTerminal` sweep at the dispatch site — the dispatch site at `GenomicsDisplay:991-1015` owns the check) before evaluating "does the batch directory contain any sample entries." `analysis-metadata.json` alone does not count as content. Because sample names/paths are precomputed in input order before dispatch (section 3 invariant), no child creates entries the cleanup pass cannot account for.

### 7. Testing

TDD per surface: two-bundle fan-out yields one `<tool>-batch-*` dir with two correctly-named children and no sibling `<tool>-<ts>` dirs (mapping, assembly, savont, pbaa); helper unit tests (sanitization, collision dedup, flat-file variant); classification/EsViritu refactor is behavior-pinned by their existing batch tests; sidebar scanner test for generic batch groups incl. flat-file children; empty-batch cleanup test. Green bar per campaign definition; zero new strict-concurrency warnings; house rules apply (OperationCenter update+log, no @unchecked Sendable).
