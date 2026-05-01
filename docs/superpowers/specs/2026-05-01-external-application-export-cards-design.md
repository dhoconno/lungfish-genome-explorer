# External Application Export Cards Design

Date: 2026-05-01

## Summary

Add an Import Center operation family for application and platform exports. These imports differ from ordinary single-format imports because a user selects a folder, archive, or project-like export from another system, and LGE inventories the contents, routes parseable standard files into native `.lungfish*` bundles, preserves the original source and unsupported artifacts, and writes a report plus provenance for the whole migration.

The first implementation should keep the Geneious card, but place it under a new Import Center tab or group named `Application Exports`. Follow-on cards should be based on documented formats that LGE can parse without requiring the original vendor application.

## Design Decisions

- Treat `Application Exports` as a new Import Center operation family, not as a reference-sequence subtype.
- Prefer standard documented export formats over proprietary native project formats.
- Preserve unsupported native files as binary artifacts with warnings rather than rejecting the whole import.
- Create one project-visible import collection for every selected export source.
- Reuse existing LGE importers for FASTA, FASTQ, GenBank, annotations, BAM/CRAM/SAM, VCF/BCF, signal tracks, metadata tables, and reports.
- Gate new native data types behind separate specs: `.lungfishmsa`, `.lungfishtree`, Sanger trace/contig bundles, microbiome/table bundles, and large phylogenetics result bundles.
- Make provenance mandatory for every output bundle, preserved source artifact, generated report, and workflow-level inventory.

## Documentation Tiers

| Tier | Meaning | Import behavior |
| --- | --- | --- |
| Ready | Vendor or project documentation lists concrete export files that map to known public formats. | Parse standard files immediately and preserve source layout. |
| Partial | Documentation lists useful standard exports, but native project/container files are proprietary or under-specified. | Parse exported standard files; preserve native files and warn that native decoding is not available. |
| Deferred native | Documentation is good, but LGE lacks the required native bundle/viewer type. | Recognize and preserve now; route to native bundles after the LGE type exists. |
| Preserve only | Documentation is weak, old, or describes UI export behavior without enough machine-readable detail. | Preserve files, identify likely formats, and tell users which standard export they should produce for better import fidelity. |

## Documented Format Survey

| Source program or platform | Documentation status | Documented formats useful to LGE | Parser readiness |
| --- | --- | --- | --- |
| Geneious Prime | Ready for standard exports; native `.geneious` decoding remains separate. | FASTA, GenBank, CSV/TSV, ABI, FASTQ, QUAL, GFF, BED, Phylip, NEXUS, MEGA, ACE, SAM/BAM, VCF, Newick, WIG, PDF, EndNote, HTML, Geneious native. | Existing Geneious card plus future native decoder. |
| QIAGEN CLC Genomics Workbench | Ready for standard exports; `.clc` is rich but proprietary. | FASTA, FASTQ, GenBank, EMBL, Nexus, PIR, Swiss-Prot, SAM/BAM/CRAM, ACE, AGP, coverage TSV, ClustalW, MSF, Phylip, Newick, BED, GFF3/GVF/GTF, VCF, Wiggle, CSV/XLS/XLSX, JSON, CLC `.clc`. | High priority card. Parse standards; preserve `.clc`. |
| DNASTAR Lasergene, SeqMan, GenVision | Partial. Vendor has format lists, but native Lasergene files are not enough for no-app parsing. | SeqMan NGen `.sqd`, BAM, FASTA, TXT reports; GenVision BAM, GFF, VCF, images, `.gvp`; SeqMan Pro ACE; sequence export GenBank, FASTA, DNA Multi-Seq, `.seq`, `.pro`, ABI, EMBL. | High priority card. Parse standards; preserve native Lasergene files. |
| Benchling | Ready. Bulk export is well documented. | Multipart GenBank, individual GenBank ZIP, Multi-FASTA, CSV, SVG, SBOL RDF. | High priority card. Parse GenBank/FASTA/CSV; preserve SBOL/SVG until supported. |
| SnapGene | Partial. Standard exports and `GenBank - SnapGene` qualifiers are documented; native `.dna` is not a vendor public interchange spec. | GenBank, FASTA, EMBL, multi-sequence collection exports, image exports, `GenBank - SnapGene` extra qualifiers; native `.dna`. | Medium priority card or merged sequence-design card. Parse GenBank-SnapGene; preserve `.dna` unless a supported decoder is approved. |
| Vector NTI Express | Partial legacy documentation. | GenBank, DDBJ, FASTA, EMBL, GCG, ASCII, GenPept, SWISS-PROT, TrEMBL, oligo CSV, REBASE, contig `.cepx`, Vector NTI archives `.ma4`, `.pa4`, `.oa4`, `.ga4`, `.ba6`. | Medium priority migration card. Parse standard exports; preserve archives. |
| CodonCode Aligner | Ready for exports. | FASTA plus QUAL, SCF, FASTQ, ACE, NEXUS/PAUP, Phylip, CSV feature tables. | High value for Sanger card. Needs Sanger trace/contig bundle for full fidelity. |
| Sequencher | Partial. Current public pages document MSA exports; legacy manuals document broader sequence and trace exports that need fixture confirmation. | FASTA, MSF, Phylip, NEXUS; legacy documented formats include GenBank, EMBL, NBRF, SCF, CAF, and project files. | Medium value for Sanger card. Parse standard exports; preserve `.spf` and unverified project files. |
| MacVector | Ready for standard sequence/alignment interchange. | GenBank, GenPept, EMBL, SWISS-PROT, PHYLIP, NEXUS, FASTA, Staden, GCG RSF/MSF, text, CODATA. | Medium priority, covered by Sequence Design and Alignment/Tree cards. |
| MEGA | Ready for alignment/tree interchange, but needs LGE MSA/tree support. | MEGA, FASTA, PAUP/NEXUS, NBRF/PIR, Newick. | Deferred native MSA/tree card. |
| Jalview | Ready. CLI docs list alignment output formats. | FASTA, PFAM, Stockholm, PIR, BLC, AMSA, JSON, PileUp, MSF, Clustal, Phylip, Jalview project, EPS/SVG/HTML/BioJS images. | Deferred native MSA card; parse sequence/alignment standards after `.lungfishmsa` exists. |
| UGENE | Ready for native UGENE project-support files and standard formats. | UGENE database `.ugenedb`, short reads FASTA `.srfa`, workflow `.uwl`, query `.uql`, dotplot `.dpt`, plus standard sequence/alignment/tree files. | Deferred native MSA/tree plus workflow preservation. |
| Oxford Nanopore MinKNOW/EPI2ME | Ready. Output specifications are public. | POD5, deprecated FAST5, BAM, FASTQ, sequencing summary TSV, sample sheet, output hash, final summary, barcode alignment report. | High priority platform run-folder card. Parse FASTQ/BAM/summaries; preserve POD5 until raw-signal support exists. |
| PacBio SMRT Link | Ready. User guide lists job directory and output formats. | BAM/BAI, BED, CSV, FASTA/FASTQ, GFF, PBI, VCF/gVCF, report JSON, dataset XML, datastore JSON, stdout/stderr logs. | High priority platform run-folder card. Parse standards; preserve PBI/XML/report JSON. |
| Illumina BaseSpace and Local Run Manager | Ready. Docs describe downloadable analysis files and local output folders. | FASTQ, BAM/BAI, VCF/gVCF, CSV, sample sheets, RunInfo.xml, RunParameters.xml, InterOp metrics, reports. | High priority platform run-folder card. Reuse FASTQ/BAM/VCF importers and preserve run metadata. |
| Ion Torrent Suite/Ion Reporter | Ready enough for common outputs. | BAM, VCF, FASTQ, reports, plugin/upload metadata. | Include in platform run-folder card. Preserve Ion-specific metadata and warn where flow-space fields are not represented. |
| IGV Desktop/Web sessions | Ready but not a scientific-data migration source by itself. | IGV XML session files plus track references to BAM/CRAM/VCF/BED/GFF/WIG/BigWig and indexes. | Lower priority. Import as a track-set/session artifact after track bundles are mature. |
| QIIME 2 | Ready. `.qza` and `.qzv` are zip archives with `data`, `metadata`, and `provenance`. | QZA/QZV archives; exported data may be FASTA, BIOM, Newick, TSV, taxonomy tables, visualizations. | Good documentation, but product fit depends on microbiome bundle scope. Defer unless LGE adds microbiome tables. |
| Nextclade, Nextstrain, UShER, Taxonium | Ready for modern phylogenetics outputs. | Nextclade aligned FASTA, translation FASTA, TSV/CSV, JSON/NDJSON, Auspice v2 JSON, Newick; Nextstrain Auspice JSON and sidecars; UShER MAT protobuf `.pb`; Taxonium JSONL. | High scientific value but deferred until `.lungfishmsa`, `.lungfishtree`, or phylogenetics result bundles exist. |

## Import Center Card Set

### Card: Geneious Export

- Card id: `geneious-export`.
- Operation family: `applicationExport`.
- Accepted inputs: `.geneious` archives, Geneious export folders, ZIP folders that contain Geneious-native and standard files.
- First behavior: scan, import embedded standard files, preserve native Geneious XML/sidecars, write report and provenance.
- Future behavior: route decoded Geneious sequence and annotation documents to `.lungfishref` when the native decoder is available.
- Output collection: `<source> Geneious Import`.

### Card: CLC Workbench Export

- Card id: `clc-workbench-export`.
- Operation family: `applicationExport`.
- Accepted inputs: CLC export folders, ZIP archives, `.clc` files, and standard exported files from CLC.
- Recognized standard files: FASTA/FASTQ, GenBank, EMBL, Nexus, SAM/BAM/CRAM, ACE, AGP, coverage TSV, ClustalW, MSF, Phylip, Newick, BED, GFF3/GVF/GTF, VCF, Wiggle, CSV/XLS/XLSX, JSON, PDF/SVG/PNG/JPEG/TIFF reports.
- Native handling: preserve `.clc` as a binary artifact with a warning that CLC's rich native object is not decoded.
- Output collection: `<source> CLC Workbench Import`.
- First native routes: references, reads, mappings, variants, annotation tracks, signal tracks, reports.
- Deferred routes: MSA and tree bundles.

### Card: DNASTAR Lasergene Export

- Card id: `dnastar-lasergene-export`.
- Operation family: `applicationExport`.
- Accepted inputs: Lasergene/SeqMan/GenVision export folders, ZIP archives, `.ace`, `.sqd`, `.seq`, `.pro`, `.sbd`, `.gvp`, `.bam`, `.fas`, `.gff`, `.vcf`, `.abi`, `.ab1`, `.embl`, `.gb`, `.txt`.
- Standard routes: FASTA/GenBank/EMBL to reference bundles; BAM to mapping bundles; VCF to variant tracks; GFF to annotation tracks; ACE and ABI/AB1 to preserved artifacts until Sanger bundles exist.
- Native handling: preserve `.sqd`, `.seq`, `.pro`, `.sbd`, and `.gvp` unless an approved parser is added.
- Output collection: `<source> Lasergene Import`.
- Deferred routes: Sanger contig, trace, and assembly bundle.

### Card: Benchling Bulk Export

- Card id: `benchling-bulk-export`.
- Operation family: `applicationExport`.
- Accepted inputs: Benchling ZIP exports, multipart GenBank files, individual GenBank ZIPs, Multi-FASTA, CSV metadata, SVG maps, SBOL RDF.
- First routes: GenBank and FASTA to references, CSV to project metadata/attachments, SVG to attachments.
- Native handling: no proprietary native file expected in the default flow.
- SBOL behavior: preserve RDF and warn until LGE supports SBOL parsing.
- Output collection: `<source> Benchling Import`.

### Card: Sequence Design Library Export

- Card id: `sequence-design-library-export`.
- Operation family: `applicationExport`.
- Source programs: SnapGene, Vector NTI, MacVector, ApE, Clone Manager, Serial Cloner, and similar plasmid/sequence-design tools.
- Accepted inputs: GenBank, GenBank-SnapGene, FASTA, EMBL, DDBJ, GCG, SWISS-PROT, GenPept, TrEMBL, NBRF/PIR, CODATA, text sequence, multi-sequence ZIPs, SnapGene `.dna`, Vector NTI archives `.ma4`, `.pa4`, `.oa4`, `.ga4`, `.ba6`.
- First routes: standard sequence files to references; primer-like features in GenBank-SnapGene to primer candidates when required fields are present; CSV oligo lists to primer import where compatible.
- Native handling: preserve `.dna` and Vector NTI archive files with app-specific warnings.
- Output collection: `<source> Sequence Library Import`.
- Product reason: this card avoids one card per legacy plasmid editor while still helping users migrate sequence libraries.

### Card: Sanger Assembly Project Export

- Card id: `sanger-assembly-export`.
- Operation family: `applicationExport`.
- Source programs: CodonCode Aligner, Sequencher, DNASTAR SeqMan Pro, CLC Sanger workflows, Geneious trace exports.
- Accepted inputs: ABI/AB1, SCF, PHD, QUAL, FASTA plus QUAL, FASTQ, ACE, Phylip, NEXUS/PAUP, MSF, CSV feature tables, Sequencher `.spf`, Lasergene `.sqd`.
- First routes: consensus FASTA/GenBank to references; FASTQ to reads; CSV feature tables to attachments unless a reference can be resolved.
- Native handling: preserve traces and project files until LGE has Sanger trace/contig bundles.
- Output collection: `<source> Sanger Import`.
- New LGE type dependency: `.lungfishtrace` or `.lungfishsanger` is required for full-fidelity trace chromatograms and contig assemblies.

### Card: Alignment And Tree Export

- Card id: `alignment-tree-export`.
- Operation family: `applicationExport`.
- Source programs: MEGA, Jalview, UGENE, MacVector, CLC, Geneious, Sequencher, CodonCode.
- Accepted inputs: aligned FASTA, Clustal/ALN, MSF, Stockholm, PFAM, PIR/NBRF, Phylip, NEXUS/PAUP, MEGA, AMSA, PileUp, Jalview project, UGENE `.srfa`, Newick, Extended Newick/NHX, NEXUS trees, MEGA trees, SVG/PDF/HTML alignment or tree exports.
- First behavior: inventory, validate, preserve, and import unaligned sequence content only when doing so is explicitly non-lossy.
- Future routes: `.lungfishmsa` and `.lungfishtree`.
- Output collection: `<source> Alignment Tree Import`.
- Warning rule: do not flatten an alignment to ordinary FASTA or a rich tree to plain Newick unless the preview clearly identifies metadata loss and the user chooses that conversion.

### Card: Sequencing Platform Run Folder

- Card id: `sequencing-platform-run-folder`.
- Operation family: `applicationExport`.
- Source platforms: Illumina BaseSpace/Local Run Manager/run folders, Oxford Nanopore MinKNOW/EPI2ME outputs, PacBio SMRT Link jobs, Ion Torrent Suite/Ion Reporter outputs.
- Accepted inputs: run folders, downloaded analysis folders, ZIP archives, FASTQ, BAM/CRAM/SAM, BAI/CSI/CRAI, VCF/gVCF/BCF, BED, GFF, CSV/TSV summaries, JSON reports, XML run metadata, InterOp files, POD5, FAST5, PBI.
- First routes: FASTQ to reads, BAM/CRAM/SAM to mapping bundles, VCF/gVCF/BCF to variant tracks, BED/GFF to annotations, CSV/TSV/JSON/XML/report files to preserved metadata artifacts.
- Native handling: preserve POD5, FAST5, PBI, InterOp, and platform-specific metadata until native viewers or summary importers exist.
- Output collection: `<source> Sequencing Run Import`.
- Special behavior: infer sample names, barcodes, lanes, read groups, and platform from sample sheets and run metadata when available.

### Card: Phylogenetics Result Set

- Card id: `phylogenetics-result-set`.
- Operation family: `applicationExport`.
- Source programs: Nextclade, Nextstrain/Augur/Auspice, UShER/matUtils, Taxonium, BEAST-family exports when present as standard tree files.
- Accepted inputs: Nextclade output folders, aligned FASTA, translation FASTA, TSV/CSV, JSON/NDJSON, Auspice v2 JSON, Newick, Nextstrain sidecar JSON files, UShER MAT protobuf `.pb`, Taxonium JSONL/JSONL.GZ, BEAST `.trees`.
- First behavior: inventory and preserve; import only ordinary sequence/metadata tables that do not require new tree/MSA semantics.
- Future routes: `.lungfishmsa`, `.lungfishtree`, and a possible `.lungfishphylo` analysis bundle.
- Output collection: `<source> Phylogenetics Import`.
- Warning rule: preserve mutation-annotated tree metadata; do not silently reduce UShER MAT or Auspice JSON to plain Newick.

### Card: QIIME 2 Archive

- Card id: `qiime2-archive`.
- Operation family: `applicationExport`.
- Accepted inputs: `.qza`, `.qzv`, exported QIIME 2 folders, QIIME 2 ZIP collections.
- First behavior: safely unzip, read archive metadata, preserve provenance, inventory `data` files, and route FASTA/Newick/TSV where LGE has native support.
- Deferred routes: BIOM tables, taxonomy tables, diversity results, and interactive visualizations require a microbiome/table result bundle.
- Output collection: `<source> QIIME 2 Import`.
- Product status: documented and technically straightforward, but lower priority unless LGE explicitly targets microbiome workflows.

### Card: IGV Session Or Track Set

- Card id: `igv-session-track-set`.
- Operation family: `applicationExport`.
- Accepted inputs: IGV XML session files, `.json` IGV-Web session/share files where documented, folders containing referenced track files and indexes.
- First behavior: parse session references, import local track files that LGE already supports, preserve the session file, and report missing remote or local resources.
- Deferred routes: LGE track-set/session bundle once mapping, variant, annotation, and signal bundles can be linked in a saved viewport.
- Output collection: `<source> IGV Session Import`.
- Product status: lower priority than true migration cards because IGV sessions mainly organize files rather than store primary scientific data.

## Shared Workflow

1. User selects an `Application Exports` card.
2. LGE opens a file/folder picker configured for the card's known extensions while allowing other file types.
3. The scanner recursively inventories the source, rejecting unsafe archive paths and unsafe symlinks.
4. The preview groups contents into native LGE imports, preserved artifacts, deferred native types, warnings, and hard errors.
5. User chooses the destination collection name and preservation options.
6. LGE stages parseable files and calls existing import services.
7. LGE copies unsupported and source files into the collection's preserved-artifacts area.
8. LGE writes `inventory.json`, `import-report.md`, and provenance.
9. The app opens the new collection in the project sidebar.

## Output Collection Layout

Each application export import creates:

- `LGE Bundles/` for created `.lungfish*` outputs.
- `Binary Artifacts/` for unsupported or deferred files.
- `Source/` for the original archive or a manifest-preserved copy of selected source files.
- `inventory.json` for the machine-readable scan result.
- `import-report.md` for user-readable warnings and routing decisions.
- `.lungfish-provenance.json` for workflow-level provenance.

Existing imported bundles must also carry bundle-local provenance that points to final stored payloads, not only temporary staged files.

## Parser Strategy

The shared parser should classify files by both extension and lightweight content sniffing:

- Sequence: FASTA, FASTQ, GenBank/GenPept, EMBL, DDBJ, Swiss-Prot, PIR/NBRF, GCG, raw sequence.
- Annotation: GFF2/GFF3, GTF, GVF, BED, feature CSV/TSV.
- Mapping: SAM, BAM, CRAM, ACE, AGP, coverage TSV.
- Variant: VCF, BCF, gVCF.
- Signal: WIG, bedGraph, BigWig where supported.
- MSA: aligned FASTA, Clustal, MSF, Stockholm, Phylip, NEXUS, MEGA, PFAM, AMSA, PileUp.
- Tree: Newick, NEXUS tree blocks, MEGA trees, Auspice JSON, UShER MAT, Taxonium JSONL, BEAST `.trees`.
- Sanger: ABI/AB1, SCF, PHD, QUAL, ACE.
- Platform metadata: sample sheets, RunInfo.xml, RunParameters.xml, sequencing summary TSV, datastore JSON, report JSON/XML, InterOp, output hash files.
- Project/native: `.geneious`, `.clc`, `.dna`, `.ma4`, `.pa4`, `.oa4`, `.sqd`, `.seq`, `.pro`, `.sbd`, `.gvp`, `.spf`, `.ugenedb`, `.jvp`, `.qza`, `.qzv`.

Parsing must be strict enough to avoid false native imports. If classification is uncertain, preserve the file and report it as `recognized-but-not-imported` or `unknown-preserved`.

## Warning Policy

Warnings should be specific and action-oriented:

- `native-format-preserved`: LGE preserved the native file but did not decode it.
- `viewer-type-missing`: LGE recognized a tree, MSA, trace, or microbiome result but lacks the native bundle/viewer type.
- `standard-file-import-failed`: LGE tried an existing importer and preserved the original after validation failed.
- `metadata-loss-risk`: a conversion would discard alignment, tree, mutation, primer, quality, color, or application-specific metadata.
- `external-reference-missing`: a project/session file referenced a resource not present in the selected source.
- `remote-resource-not-fetched`: a session referenced a URL; LGE did not download it automatically.
- `unsupported-compression`: a compressed member was preserved because the decompressor is not supported.

## Provenance

Every card in this operation family creates scientific data or wraps scientific data, so provenance is mandatory. The provenance record must include:

- Workflow name and version, such as `application-export-import` plus card id.
- Exact argv or reproducible command for scanner, archive extraction, and each import service call.
- User-visible options and resolved defaults.
- Source paths, archive member paths, checksums, file sizes, and safe-extraction decisions.
- Application/source format classification and detected application versions when available.
- Existing importer identities, options, exit status, wall time, and stderr when useful.
- Runtime identity for helper tools, decompression tools, conda/container environments, and parser libraries.
- Staging paths and final stored payload paths.
- Final checksums and sizes for every created bundle and preserved artifact.
- Warnings, unsupported-content records, and deferred-native-type records.

Missing provenance is a blocking defect for every implementation task in this feature family.

## Rollout

Phase 1: Card family and common scanner.

- Add `Application Exports` tab/group.
- Keep Geneious as the first shipping card.
- Add card metadata for CLC, DNASTAR, Benchling, Sequence Design Library, Sanger, Alignment/Tree, Sequencing Platform Run Folder, Phylogenetics, QIIME 2, and IGV Session.
- Implement shared inventory, preservation, report, and provenance contract.

Phase 2: Highest-value standard import routes.

- CLC Workbench Export.
- Benchling Bulk Export.
- Sequencing Platform Run Folder.
- DNASTAR Lasergene Export standard routes.
- Sequence Design Library standard routes.

Phase 3: New native bundle support.

- `.lungfishmsa`.
- `.lungfishtree`.
- Sanger trace/contig bundle.
- Track-set/session bundle.

Phase 4: Large analysis and microbiome result sets.

- Nextclade/Nextstrain/UShER/Taxonium result bundles.
- QIIME 2 archive result bundles if microbiome workflows become product scope.
- Platform raw-signal metadata and richer QC summaries.

## Acceptance Criteria

- Import Center has a distinct `Application Exports` operation family.
- Each card describes a documented export source and does not require the vendor application to be installed.
- Selecting an export creates one project collection containing native LGE bundles where possible and preserved binary artifacts otherwise.
- Unsupported native formats are never silently discarded.
- The scanner records enough source classification to explain why each file was imported, deferred, preserved, or rejected.
- All created bundles and collection artifacts include provenance that satisfies the Lungfish provenance requirements.

## Primary Sources

- Geneious Prime user manual, Importing and Exporting Data: https://manual.geneious.com/en/latest/ImportExport.html
- QIAGEN CLC Genomics Workbench 25.0.2 manual, sequence/read-mapping/alignment/tree/annotation formats: https://resources.qiagenbioinformatics.com/manuals/clcgenomicsworkbench/2502/
- DNASTAR file formats: https://www.dnastar.com/resources/file-formats/
- Benchling DNA and RNA sequence export documentation: https://help.benchling.com/hc/en-us/articles/39110680274189-DNA-and-RNA-sequence-overview
- SnapGene import/export documentation and GenBank-SnapGene format notes: https://support.snapgene.com/hc/en-us/sections/10384241008404-Importing-and-Exporting
- Vector NTI Express user guide: https://tools.thermofisher.com/content/sfs/manuals/VectorNTIExpressUG.pdf
- CodonCode Aligner export documentation: https://www.codoncode.com/aligner/quicktour/export.htm
- Sequencher alignment export documentation: https://www.genecodes.com/sequencher-features/sanger-sequencing/sequence-alignment
- MacVector import/export format overview: https://macvector.com/getting-started/useful-workflows/importing-sequences-into-macvector/
- Jalview command-line output formats: https://www.jalview.org/help/html/features/clarguments-basic.html
- UGENE supported/native file formats: https://ugene.net/docs/appendixes/appendix-a-supported-file-formats/ugene-native-file-formats/
- Oxford Nanopore output specifications: https://nanoporetech.github.io/ont-output-specifications/latest/minknow/support/
- PacBio SMRT Link user guide: https://www.pacb.com/wp-content/uploads/SMRT-Link-v25.3-user-guide.pdf
- Illumina BaseSpace and Local Run Manager documentation: https://help.basespace.illumina.com/manage-data/download/download-analysis-files and https://support.illumina.com/sequencing/sequencing_software/local-run-manager/documentation.html
- QIIME 2 archive documentation: https://amplicon-docs.qiime2.org/en/latest/explanations/archives.html
- Nextclade CLI output documentation: https://docs.nextstrain.org/projects/nextclade/en/stable/user/nextclade-cli/usage.html
- Nextstrain data format documentation: https://docs.nextstrain.org/en/latest/reference/formats/index.html
- UShER matUtils documentation: https://usher-wiki.readthedocs.io/en/latest/matUtils.html
- Taxonium tools documentation: https://docs.taxonium.org/en/latest/taxoniumtools.html
