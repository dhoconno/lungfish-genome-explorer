# In-App Help Surface Map

Date: 2026-06-13
Reviewers: Genomics workflow audit, virology and metagenomics audit, documentation expert review
Scope: Scientific workflows, operation dialogs, classifier result controls, bundled Help topics, and provenance-facing help.

## Documentation Style Applied

- Tooltips should usually be 8-18 words and one sentence.
- Inline help should be one or two short sentences.
- Use concrete biology and file words: reads, reference, bundle, annotation, variant, alignment, provenance.
- Mention provenance when a workflow creates, imports, transforms, exports, extracts, or wraps scientific data.
- Avoid implying that BLAST, classifier, AI, or variant-impact results are final. Use candidate, supports review, often, usually, and may when evidence is conditional.
- Do not use hype language, em dashes, or exclamation marks in bundled Help copy.

## First-Pass Implemented Surfaces

| Persona | File | Surface | First-pass action | Help copy summary | Follow-up |
|---|---|---|---|---|---|
| Genomics researcher | `Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift` | Tool sidebar rows | Added shared SwiftUI help | Choose the operation to run on selected scientific inputs. | Add dynamic tool-specific copy when the sidebar model carries help IDs. |
| Genomics researcher | `Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift` | Readiness text | Added shared SwiftUI help | Shows whether selected inputs and settings are ready. | Add per-error remediation copy from validation state. |
| Genomics researcher | `Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift` | Run button | Added shared SwiftUI help | Run visible settings and write output provenance. | Add popover link to provenance help topic. |
| Genomics researcher | `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift` | Overview | Added shared SwiftUI help | Review what the selected operation does to reads. | Add operation-specific warnings for demultiplexing, human scrub, and MAFFT. |
| Genomics researcher | `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift` | Auxiliary inputs | Added shared SwiftUI help | Select required reference, database, or barcode input. | Distinguish copied bundle payload paths from external source paths in UI. |
| Genomics researcher | `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift` | Output Strategy | Added shared SwiftUI help | Choose per-input or grouped output. | Add examples for grouped FASTA and multi-sample reads. |
| Genomics researcher | `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift` | Advanced arguments | Added shared SwiftUI help | Extra arguments are passed directly to the command and recorded in provenance. | Add per-tool argv previews where available. |
| Genomics researcher | `Sources/LungfishApp/Views/BAM/BAMPrimerTrimToolPanes.swift` | Primer scheme picker | Added shared SwiftUI help | Choose the scheme matching the amplicon protocol. | Surface scheme version and checksum next to selected scheme. |
| Genomics researcher | `Sources/LungfishApp/Views/BAM/BAMPrimerTrimToolPanes.swift` | Trim thresholds | Added shared SwiftUI help | Adjust only for assay-specific iVar behavior. | Add inline definitions for quality, sliding window, and offset. |
| Genomics researcher | `Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift` | Alignment track | Added shared SwiftUI help | Select the analysis-ready BAM track. | Show source BAM checksum and index status in the picker row. |
| Genomics researcher | `Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift` | Minimum AF and depth | Added shared SwiftUI help | Blank uses caller defaults, explicit values record user thresholds. | Split allele-frequency and depth copy when fields get separate help IDs. |
| Genomics researcher | `Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift` | iVar primer-trim attestation | Added shared SwiftUI help | Mark only if primers were removed from this exact BAM. | Prefer provenance sidecar evidence over manual trust. |
| Genomics researcher | `Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift` | Medaka and Clair3 model | Added shared SwiftUI help | Enter model matching basecaller chemistry. | Add model picker when managed model metadata is available. |
| Virology researcher | `Sources/LungfishKit/ClassifierActionBar.swift` | BLAST Review | Added AppKit tooltip and accessibility help | Submit selected reads to NCBI BLAST for review. | State sampled-read behavior in classifier-specific panels. |
| Virology researcher | `Sources/LungfishKit/ClassifierActionBar.swift` | Export | Added AppKit tooltip and accessibility help | Export the current results table. | Clarify whether exports reflect current filters for each table. |
| Virology researcher | `Sources/LungfishKit/ClassifierActionBar.swift` | Extract FASTQ | Added AppKit tooltip and accessibility help | Extract reads matching current selection with provenance. | Explain clade, accession, taxon, and allowlist behavior per classifier. |
| Virology researcher | `Sources/LungfishKit/ClassifierActionBar.swift` | Provenance | Added AppKit tooltip and accessibility help | Show tool, database, inputs, runtime, and import provenance. | Block or warn on missing provenance at result open. |
| Documentation reviewer | `Sources/LungfishApp/Resources/Help/*.md` | Bundled Help topics | Added four topics and cleaned existing copy | Reads, classifiers, alignments/variants, and provenance now have in-app topics. | Add generated Help Book HTML for new topics when Help Book build pipeline is refreshed. |

## Follow-Up Surface Map

| Persona | File | Surface | Suggested help copy | Scientific caution |
|---|---|---|---|---|
| Genomics researcher | `Sources/LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift` | Platform popup | Choose the sequencing platform used to generate these reads. This sets import defaults only. | Confirmed platform belongs in import provenance. |
| Genomics researcher | `Sources/LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift` | Pairing popup | Choose how read mates are represented in the selected FASTQ files. | Wrong pairing changes downstream counts and metadata. |
| Genomics researcher | `Sources/LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift` | Quality binning popup | Preserve original qualities for fidelity, or bin qualities to reduce bundle size. | Binning is irreversible and should be captured in provenance. |
| Genomics researcher | `Sources/LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift` | Processing recipe | Run a predefined workflow immediately after import. | Recipe ID, placeholders, and outputs are provenance-critical. |
| Genomics researcher | `Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceDialog.swift` | Model field | Enter an IQ-TREE model or model-selection preset, such as MFP. | Requested model and selected model both matter for reproducibility. |
| Genomics researcher | `Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceDialog.swift` | Seed and threads | Set Seed for repeatable stochastic steps. Leave Threads blank for automatic selection. | Threading and resolved defaults belong in provenance. |
| Genomics researcher | `Sources/LungfishApp/Views/Operations/OperationsPanelController.swift` | CLI command copy | Copy the command Lungfish ran for this operation. | Replay command helps, but bundle provenance is authoritative. |
| Genomics researcher | `Sources/LungfishApp/Views/Operations/OperationsPanelController.swift` | Failure report | Copy command, error details, and logs for troubleshooting. | Reports may include local paths or sample names. |
| Virology researcher | `Sources/LungfishApp/Views/Metagenomics/TaxonomyTableView.swift` | Reads and Direct columns | Reads includes this taxon and descendants. Direct is exact assignments only. | Clade reads can double-count nested taxa if summed manually. |
| Virology researcher | `Sources/LungfishApp/Views/Metagenomics/ClassifierExtractionDialog.swift` | FASTQ or FASTA format picker | FASTQ preserves qualities. FASTA keeps sequence only. | FASTA drops quality scores and pairing context. |
| Virology researcher | `Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift` | Hits and Unique Reads | Hits are total alignments. Unique Reads are deduplicated read support. | Hits can inflate duplicates or multi-mapping. |
| Virology researcher | `Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift` | Recompute Unique Reads | Recalculate unique reads from BAM alignments. | Can change interpretation and cached outputs. Record provenance and runtime. |
| Virology researcher | `Sources/LungfishTaxTriageUI/TaxTriageBatchOverviewView.swift` | Facet control | Choose the value shown in sample columns. | Colors still follow TASS score when cells show reads or coverage. |
| Virology researcher | `Sources/LungfishEsVirituUI/ViralDetectionTableView.swift` | Detection columns | Use unique reads, coverage breadth, depth, and identity together. | Reads alone can overstate evidence. |
| Virology researcher | `Sources/LungfishEsVirituUI/SegmentCompletenessView.swift` | Segment grid | Coverage color summarizes segment support. | Segment presence is coverage/read based, not full-genome assembly evidence. |
| Virology researcher | `Sources/LungfishNvdUI/NvdResultViewController.swift` | Grouping control | Group contigs by sample or adjusted taxonomy. | Taxon grouping is adjusted taxonomy, not necessarily raw top BLAST hit. |
| Virology researcher | `Sources/LungfishNvdUI/NvdResultViewController.swift` | BLAST Verify | Submit this contig sequence to BLAST. | Re-BLAST validates the contig sequence, not read-level abundance. |
| Virology researcher | `Sources/LungfishApp/Views/Metagenomics/CzIdImportSheet.swift` | Preview rows | Preview sample, row count, database versions, and top taxa. | Hosted CZ-ID thresholds and database versions can differ from local classifiers. |

## Review Notes

The first pass intentionally favors shared controls and high-traffic scientific dialogs. The follow-up items are more domain-specific and should get separate implementation slices because many need dynamic copy from row selection, table filter state, or provenance availability.
