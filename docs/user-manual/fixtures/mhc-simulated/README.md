# Simulated macaque MHC teaching fixture

These are simulated observations for demonstrating the native genotype workflow and workbook export. They are not reads from animals and are not evidence for a biological genotype, haplotype, expression level, or assay sensitivity. No private reads or Williams project data are used.

The generator selects three amplicons from the application's bundled MCM reference. It verifies the complete bundled payload checksum manifest and matches each selected amplicon, on either strand, to its public ENA accession record. Cached ENA records make subsequent runs independent of network access.

| Bundled record | Public accession | Reference allele | Amplicon length |
|---|---|---|---|
| MCM_MHC_MiSeq_0002 | [OR823640](https://www.ebi.ac.uk/ena/browser/view/OR823640) | Mafa-G_02:31:01:01 | 156 bp |
| MCM_MHC_MiSeq_0005 | [OR823568](https://www.ebi.ac.uk/ena/browser/view/OR823568) | Mafa-DRB_W001:03:01:01 | 244 bp |
| MCM_MHC_MiSeq_0007 | [OR823525](https://www.ebi.ac.uk/ena/browser/view/OR823525) | Mafa-DPA1_07:02:01:01 | 173 bp |

All three public records identify Macaca fascicularis. The reference labels are retained from the bundled reference. Selecting these records does not assert that the mixture represents an individual animal or a compatible haplotype.

The deterministic generator emits error-free 150-base mates at constant Phred 40. Sample A has 120, 80, and 4 pairs from the three targets in table order. Sample B has 12, 60, and 100. `simulation-truth.json` records the exact sequences, source headers, and counts. Both separate mate files and explicit interleaved files are provided. The builder imports the interleaved files so both mates are preserved.

## Reproduce

From the repository root, with the desktop demo project already created, run only the bounded step below.

```sh
python3 docs/user-manual/fixtures/demo-project/extend-demo-fixtures.py mhc-simulated
```

This verifies or generates the fixture, imports two Illumina FASTQ bundles, runs the real native genotype-only cohort workflow with two threads, retains intermediates, imports the three-record reference for GUI selection, and checks the result against the simulation truth. Existing results are validated and retained. A changed fixture source or output fails validation rather than being silently replaced.

The native pipeline actually invokes BBMerge, minimap2, samtools, pysam, and openpyxl. It merges all 376 pairs, retains all 376 merged fragments, and assigns all of them. The reported total of 752 counts individual input mate records. Consequently the native retained percentage is 50%, even though no pairs were lost.

## Durable outputs

All paths below are relative to `~/Desktop/lge-docs/LGE Manual Demo.lungfish`.

- `Imports/SIMULATED-MHC-A-pairs.lungfishfastq`
- `Imports/SIMULATED-MHC-B-pairs.lungfishfastq`
- `Reference Sequences/SIMULATED-MHC-annotated-reference.lungfishref`
- `Analyses/SIMULATED-MHC-bundle-validated`
- `Analyses/SIMULATED-MHC-bundle-validated/artifacts/workbooks/current.xlsx`

The result's `genotype-result.json` declares `miseq-amplicon-mhc-genotype` and `genotypeOnly`. Its native `.lungfish-provenance.json` records the executed arguments, explicit options and defaults, runtime, successful steps, time, and file identities. The companion `retained-demux-genotyping-provenance.json` records pinned managed package versions. BBMerge's actual conda package metadata is preserved in `teaching-source/bbmerge-runtime.json`, and its stderr logs and merge arguments remain in `.amplicon-genotyping`.

`fixture-generation-provenance.json` separately identifies simulation generation and hashes the source script, bundled source records, public accession records, and generated payloads. Copies of this record and the simulation truth accompany both imported bundles and the native result in `teaching-source`. Command execution audits live under `~/Desktop/lge-docs/LGE Manual Demo.build/fixture-provenance`.

The native FASTQ import records retain an additional temporary compression-input path after cleanup, alongside the original interleaved input and final stored output checksums. The source files remain available here. The native genotype result was run with Keep Intermediates so all 28 files in its top-level provenance remain available and verifiable.

## Capture in the app

Open the demo project and select the final result under Analyses for export screenshots. Use Inspector, View, Genotype Display, Export, Filtered Pivot. The primary workbook has sample columns, the empty haplotype band, and three allele rows beneath Genotype, Total, and # Obs. Set any desired numeric filters explicitly and document them. For example, a minimum of 50 reads removes A's DPA1 count of 4 and B's G count of 12. These thresholds are demonstration choices.

For a genuine Operations screenshot, open Tools, Genotyping, miSeq amplicon MHC genotyping. Choose `SIMULATED-MHC-annotated-reference` and only the two `SIMULATED-MHC-*-pairs` FASTQ bundles. Choose Genotype only, two threads, Min Reads 1, and Keep Intermediates. Use a fresh report name such as `SIMULATED-MHC-GUI-teaching`. Capture while that actual run is active. The CLI run takes only a few seconds, so the merge progress message may be brief. Never substitute a completed result for running progress.

Two earlier exploratory outputs remain in the live demo to preserve their actual history. `SIMULATED-MHC-teaching` received only R1 from a separate-mate import with recipe none and correctly retained zero full-span reads. `SIMULATED-MHC-paired-teaching` successfully used interleaved pairs but cleaned regenerable intermediates. `SIMULATED-MHC-native-teaching` retains all intermediates from the raw FASTA route. Use `SIMULATED-MHC-bundle-validated` for the GUI-compatible result. The builder reproduces the native raw-FASTA baseline and the annotated-reference route.

## Reference metadata required by the GUI

A plain reference ID such as `Mafa-G_02:31:01:01|OR823640` maps correctly against raw FASTA but does not supply the semantic metadata required when the workflow builds reference visualizations from a `.lungfishref` bundle. The resolver accepts explicit allele annotations, a canonical starred allele in the FASTA description, or recognized legacy IPD identifiers. The initial reference had none of these. Import preserved its sequence and ID but the GUI run failed during workbook preparation. That original reference and failed run remain unchanged.

`prepare-gui-reference.py` generates a separate GenBank reference with identical IDs and sequences. It adds explicit gene, genomic DNA molecule type, and canonical allele qualifiers, such as `Mafa-G*02:31:01:01`. The canonical separator replaces the underscore used in the bundled reference label. `gui-reference-provenance.json` records this metadata-only transformation and its inputs and outputs. Native import retains these annotations in the reference record store. The builder validates a real native genotype run against the actual annotated `.lungfishref` path before declaring it ready.

To add or verify this route independently after the paired-read bundles exist, run `python3 docs/user-manual/fixtures/demo-project/extend-demo-fixtures.py mhc-gui-reference` from the repository root. The existing raw-FASTA result remains scientifically reproducible, while the annotated bundle supplies the additional metadata expected by the GUI. The annotated route also needed a product fix. Before LGE 2026.9.44, a genotype run against an annotated `.lungfishref` stopped at "Applying selected haplotype definition", because the step that copies the reference for review copied its record store but not its annotation track store, `annotations/imported_annotations.db`. LGE 2026.9.44 copies the annotation track stores as well, so the annotated route runs in the app and on the command line alike.

The fixture validator checks the immutable generated baseline. For an interactively edited workbook, also follow the manifest revision chain and its revision provenance. Earlier workflow or export records retain the checksum of the workbook at that time. A later change to `current.xlsx` is expected to differ from those historical checksums.
