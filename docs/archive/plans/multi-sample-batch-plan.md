# Multi-Sample Batch Analysis: Implementation Plan

## Status Tracking

- [x] Phase 1: Minimal Viable Batch Support
  - [x] 1A: Storage — common ancestor output directory + sourceBundleURLs
  - [x] 1C: Viewer — sample segmented control + per-sample filtering
  - [x] 1B: Sidebar — batch group node for multi-sample TaxTriage runs
  - [x] 1D: Routing — sidebar click routing for batch/sample selection
  - [x] QA/QC: Tests + regression check
  - [x] Expert review + sign-off
  - [x] Commit
- [x] Phase 2: Enhanced Navigation & Cross-Sample Features
  - [x] 2A: Batch overview view (organism×sample heatmap)
  - [x] 2B: Cross-reference sidecars in source bundles
  - [x] 2C: Link Kraken2/EsViritu results to TaxTriage organisms
  - [x] 2D: Keyboard shortcuts for sample navigation
  - [x] QA/QC: Tests + regression check
  - [x] Expert review + sign-off
  - [x] Commit
- [x] Phase 3: Advanced Batch Analytics
  - [x] 3A: Negative control awareness
  - [x] 3B: Batch-level PDF/CSV export
  - [x] 3C: Strain-level comparison (consensus SNP diff)
  - [x] 3D: Batch history and re-analysis
  - [x] QA/QC: Tests + regression check
  - [x] Expert review + sign-off
  - [x] Commit

## Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Where to store output | Common ancestor directory of source bundles + sidecar refs | TaxTriage produces a single output dir |
| Sidebar grouping | Batch group node under first source bundle, cross-refs in others | Matches existing classification-batch pattern |
| Per-sample navigation | Segmented control at top of TaxTriageResultViewController | macOS convention; avoids sidebar round-trips |
| Cross-sample data | Group TaxTriageMetric rows by existing `sample` field | Zero new parsing needed |

## Phase 1: Minimal Viable Batch Support

### 1A. Storage

- Fix output directory for multi-bundle TaxTriage runs: use common ancestor of source bundles
- Add `sourceBundleURLs: [URL]?` to TaxTriageConfig and TaxTriageResult
- Persist in taxtriage-result.json for provenance

Files: TaxTriageWizardSheet.swift, TaxTriageConfig.swift, TaxTriageResult.swift

### 1C. Viewer (per-sample filtering)

- Add NSSegmentedControl to TaxTriageResultViewController
- "All Samples" shows current merged view
- Selecting a sample filters organism table using TaxTriageMetric.sample field
- BAM viewer, sunburst, reports update to match selected sample

Files: TaxTriageResultViewController.swift

### 1B. Sidebar

- Detect multi-sample TaxTriage runs (config.samples.count > 1)
- Show as .batchGroup node with per-sample children
- Cross-reference scanning for results outside the current bundle

Files: SidebarViewController.swift (or equivalent sidebar file)

### 1D. Routing

- Click batch group → open result VC with "All Samples" selected
- Click per-sample child → open result VC with that sample pre-selected
- Accept optional sampleId parameter in displayTaxTriageResultFromSidebar

Files: MainSplitViewController.swift

## Phase 2: Enhanced Navigation & Cross-Sample Features

### 2A. Batch Overview View

- New TaxTriageBatchOverviewView
- Summary cards (samples, runtime, high-confidence count per sample)
- Organism × sample heatmap (rows=organisms, columns=samples, cells=TASS color)
- Cross-sample table (organism, # samples detected, mean TASS, min/max reads)
- Click cell → navigate to that organism in that sample

Files: New TaxTriageBatchOverviewView.swift, TaxTriageResultViewController.swift

### 2B. Cross-reference sidecars

- After TaxTriage completes, write taxtriage-ref-{runId}.json into each source bundle
- Contains: resultDirectory, runId, sampleId, createdAt
- Sidebar scans for these refs to show results under each contributing bundle

Files: New TaxTriageBatchResultStore.swift, AppDelegate.swift, SidebarViewController.swift

### 2C. Link Kraken2/EsViritu

- When viewing TaxTriage, discover related Kraken2/EsViritu results in source bundles
- Show "Related Analyses" navigation links
- Cross-navigate between result types for matching organisms

Files: TaxTriageResultViewController.swift, MainSplitViewController.swift

### 2D. Keyboard shortcuts

- Cmd+]/Cmd+[ to switch samples
- Cmd+0 for "All Samples" overview

Files: TaxTriageResultViewController.swift

## Phase 3: Advanced Batch Analytics

### 3A. Negative control awareness

- Tag samples as negative control in wizard
- Flag contamination-suspect organisms
- Add "Contamination Risk" column

Files: TaxTriageConfig.swift, TaxTriageWizardSheet.swift, TaxTriageResultViewController.swift

### 3B. Batch-level export

- Cross-sample organism matrix CSV
- Summary PDF with heatmap and per-sample highlights
- "Export Batch Report" button in action bar

Files: New TaxTriageBatchExporter.swift, TaxTriageResultViewController.swift

### 3C. Strain-level comparison

- For organisms in multiple samples, extract consensus sequences
- Mini MSA view highlighting SNP differences

Files: New StrainComparisonView.swift, New ConsensusExtractor.swift

### 3D. Batch history

- Log all batch runs
- Enable re-analysis with modified parameters
- Compare old vs new results

Files: New BatchRunHistory.swift

## Existing Code to Reuse

- TaxTriageMetric.sample field (already parsed, line 299 of TaxTriageMetricsParser.swift)
- .batchGroup sidebar item type (used by classification-batch, esviritu-batch)
- TaxTriageResult.save()/load() persistence
- TaxTriageSummaryBar for batch-level summary cards
- BlastResultsDrawerTab pattern for new drawer views
