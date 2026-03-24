# EsViritu + TaxTriage Integration Status

## Branch: metagenomics-workflows

## Completed

### EsViritu (Viral Detection)
- [x] `EsVirituPipeline` actor (conda-based, `CondaManager.runTool`)
- [x] `EsVirituConfig` with validation
- [x] `EsVirituDatabaseManager` (Zenodo download)
- [x] TSV parsers: detection, tax profile, coverage windows, assembly grouping
- [x] `EsVirituResultViewController` — sunburst + detection table + sparklines
- [x] `EsVirituWizardSheet` — sample name, paired-end, database, quality
- [x] `EsVirituCommand` CLI
- [x] Native BLAST verification (consensus FASTA → BlastService)
- [x] OperationCenter tracking with progress + cancellation

### TaxTriage (Clinical Triage)
- [x] `TaxTriagePipeline` actor (Nextflow via ProcessManager)
- [x] `TaxTriageConfig` + `TaxTriageSample` (multi-sample samplesheet)
- [x] Parsers: report, TASS metrics
- [x] `TaxTriageResultViewController` — PDF + Krona + organism table
- [x] `TaxTriageWizardSheet` — platform, classifier, database
- [x] `TaxTriageCommand` CLI
- [x] Native BLAST verification (Kraken2 output → BlastService)
- [x] OperationCenter tracking with progress + cancellation

### Unified Wizard
- [x] `UnifiedMetagenomicsWizard` — three analysis type cards
- [x] Tool availability badges (conda check for Kraken2/EsViritu, Nextflow check for TaxTriage)
- [x] All three wizard sheets wired
- [x] `runEsViritu()` and `runTaxTriage()` in AppDelegate
- [x] Output parsing (EsViritu TSV → LungfishIO display model)

### Menu Gating
- [x] Tools > Classify & Profile Reads opens unified wizard
- [x] Availability badges show installed/not-installed status
- [x] CondaManager.isToolInstalled() for lightweight filesystem check

## Remaining Work
- [ ] Test with real data (EsViritu on School030 FASTQ)
- [ ] Test TaxTriage with Docker/container runtime
- [ ] Coverage sparkline rendering polish
- [ ] Multi-sample batch EsViritu (run in parallel via OperationCenter)
- [ ] Compare results across tools (side-by-side view)
- [ ] Linked BAM viewer for TaxTriage reference alignments

## Test Suite
- 5,115 tests passing
- 1 known network-dependent skip (SRA search)
- 0 failures related to new code
