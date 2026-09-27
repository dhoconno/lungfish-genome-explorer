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

All paths below are relative to `~/Desktop/lge-docs/LGE Manual Demo.lungfish`, the screenshot project that `../demo-project/` builds for contributors. Readers get the same inputs, already imported, in the MHC Genotyping demo project that **Help > Demo Projects…** downloads.

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

## Haplotype definition set (MCM teaching set)

`mhc-simulated-mcm-teaching.lungfishhaplotypedef.json` is a small haplotype
definition set so the genotyping chapters can run deterministic haplotyping
on this fixture instead of pointing at the lab's unpublished Williams data.
It is limited to the three alleles the simulated reference contains, which is
the honest ceiling for this fixture. It is not a definition of the MCM M1 to
M7 haplotypes. A real definition set for an assay lists, for every region,
every haplotype's diagnostic alleles, and the bundled `MCM MHC miSeq`
reference the app ships carries 189 records across five regions for that
purpose.

Each allele is assigned to the haplotype its own public INSDC record names in
its `/haplotype` qualifier (records cached under `public-records/`):

| Allele in the reference | Public record | `/haplotype` | `/isolate` | Region in the set |
|---|---|---|---|---|
| Mafa-G_02:31:01:01 | OR823640 | M4 | cy0695 | MHC-A |
| Mafa-DRB_W001:03:01:01 | OR823568 | M7 | cy0390 | MHC-DR |
| Mafa-DPA1_07:02:01:01 | OR823525 | M1 | cy0325 | MHC-DP |

All three records were submitted on 2023-11-15 by Karl, Prall, Wiseman and
O'Connor (University of Wisconsin-Madison) under the title "Mauritian
cynomolgus macaque major histocompatibility complex (MHC) region pangenome",
which the records mark as unpublished. Two honesty notes. First, OR823640
describes Mafa-G as a pseudogene and names the allele `Mafa-G*02_M4nov01`;
the bundled reference and this fixture keep the IPD-style label
`Mafa-G_02:31:01:01`. Second, Mafa-G lies in the MHC-A region of the macaque
MHC, which is why the set files it under `MHC-A`, the same grouping the
bundled reference uses (`haplotype_groups=MHC-A`).

The M1 to M7 haplotype names themselves are published. Cite:

```bibtex
@article{wiseman2007mcm,
  author  = {Wiseman, Roger W. and Wojcechowskyj, Jason A. and Greene, Justin M.
             and Blasky, Alex J. and Gopon, Tobias and Soma, Taeko
             and Friedrich, Thomas C. and O'Connor, Shelby L. and O'Connor, David H.},
  title   = {Simian immunodeficiency virus SIVmac239 infection of major
             histocompatibility complex-identical cynomolgus macaques from Mauritius},
  journal = {Journal of Virology},
  year    = {2007},
  volume  = {81},
  number  = {1},
  pages   = {349--361},
  doi     = {10.1128/JVI.01841-06}
}
@article{oconnor2007mcmclassii,
  author  = {O'Connor, Shelby L. and Blasky, Alex J. and Pendley, Chad J.
             and Becker, Ericka A. and Wiseman, Roger W. and Karl, Julie A.
             and Hughes, Austin L. and O'Connor, David H.},
  title   = {Comprehensive characterization of MHC class II haplotypes in
             Mauritian cynomolgus macaques},
  journal = {Immunogenetics},
  year    = {2007},
  volume  = {59},
  number  = {6},
  pages   = {449--462},
  doi     = {10.1007/s00251-007-0209-7}
}
@article{budde2010mcmclassi,
  author  = {Budde, Melisa L. and Wiseman, Roger W. and Karl, Julie A.
             and Hanczaruk, Bozena and Simen, Birgitte B. and O'Connor, David H.},
  title   = {Characterization of Mauritian cynomolgus macaque major
             histocompatibility complex class I haplotypes by high-resolution
             pyrosequencing},
  journal = {Immunogenetics},
  year    = {2010},
  volume  = {62},
  number  = {11-12},
  pages   = {773--780},
  doi     = {10.1007/s00251-010-0481-9}
}
@article{wiseman2013haplessly,
  author  = {Wiseman, Roger W. and Karl, Julie A. and Bohn, Patrick S.
             and Nimityongskul, Francesca A. and Starrett, Gabriel J. and O'Connor, David H.},
  title   = {Haplessly hoping: macaque major histocompatibility complex made easy},
  journal = {ILAR Journal},
  year    = {2013},
  volume  = {54},
  number  = {2},
  pages   = {196--210},
  doi     = {10.1093/ilar/ilt036}
}
@article{karl2023mcmhaplotype,
  author  = {Karl, Julie A. and Prall, Trent M. and Bussan, Hailey E.
             and Varghese, Joshua M. and Pal, Aparna and Wiseman, Roger W.
             and O'Connor, David H.},
  title   = {Complete sequencing of a cynomolgus macaque major histocompatibility
             complex haplotype},
  journal = {Genome Research},
  year    = {2023},
  volume  = {33},
  number  = {3},
  pages   = {448--462},
  doi     = {10.1101/gr.277429.122}
}
```

Wiseman 2007 defines the common MCM haplotypes by microsatellites,
O'Connor 2007 the class II alleles on them, Budde 2010 the class I
transcripts of the seven most frequent haplotypes, Wiseman 2013 reviews the
M1 to M7 nomenclature, and Karl 2023 sequences the complete M3 haplotype.
The three INSDC records above are the direct source of each allele's
haplotype assignment; the papers are the source of the haplotype names.

### How the set is consumed

The genotyping dialog and pipeline read definitions only from
`.lungfishmhcref` reference bundles, never from the bare JSON. The demo-project
build imports the JSON (`lungfish-cli haplotypes import`), turns it into a
bundle with `lungfish-cli haplotypes bundle-create --reference-fasta
SIMULATED-MHC-reference.fasta`, and installs it (`haplotypes bundle-install`)
as `Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref` in
the MHC Genotyping demo project. Choose that bundle as the reference in the
miSeq genotyping dialog and pick Deterministic haplotyping.

The lane's results brief records the real runs. With Minimum supporting reads
at 1 both samples call `M4 / -` at MHC-A, `M7 / -` at MHC-DR and `M1 / -` at
MHC-DP, the homozygous shape, because the set knows one haplotype per region
and each sample carries its one diagnostic allele. With Minimum supporting
reads at 5, sample A's MHC-DP becomes `ERR: NO HAP` (its DPA1 allele has 4
reads) while sample B keeps `M1 / -`. Those are the only two outcomes this
fixture can show, and chapters should say so.

The fixture validator checks the immutable generated baseline. For an interactively edited workbook, also follow the manifest revision chain and its revision provenance. Earlier workflow or export records retain the checksum of the workbook at that time. A later change to `current.xlsx` is expected to differ from those historical checksums.
