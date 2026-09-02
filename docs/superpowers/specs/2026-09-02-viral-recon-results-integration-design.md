# Viral Recon results integration

Date: 2026-09-02
Status: approved for planning
Scope: track A of two. Track B (wizard simplification) is a separate design.

## Problem

Viral Recon now runs end to end on Apple Silicon, but its results are invisible to
the application. A finished run leaves a raw nf-core output directory on disk and
nothing else. There is no entry in the sidebar, nothing to open in the viewport,
and no Inspector description of what was produced.

The user's report was that the sorted BAM cannot be visualised. That symptom is
real but the cause is not the BAM. The file at

    Analyses/viralrecon-results-64f27f1c/variants/bowtie2/SRR11140748_1.sorted.bam

passes `samtools quickcheck`, is indexed, and carries 420,513 reads mapped to
MN908947.3. The viewport cannot open it because the viewport does not open loose
BAM files at all. It binds to a `.lungfishref` reference bundle whose manifest
registers alignments and variants. A minimap2 run produces exactly that. Viral
Recon produces none of it.

The run manifest already declares `resultSurfaces` of `referenceBundles`,
`mappingBundles`, `variantTracks` and `reports`. Nothing consumes that
declaration. The intent was encoded and never wired.

## Constraint discovered during design

The pipeline does not publish the reference it aligned against. The published
parameters for the cited run record:

    genome  MN908947.3
    fasta   https://github.com/nf-core/test-datasets/raw/viralrecon/genome/
            MN908947.3/GCA_009858895.3_ASM985889v3_genomic.200409.fna.gz
    gff     (same prefix)/GCA_009858895.3_ASM985889v3_genomic.200409.gff.gz

Both are remote URLs resolved inside the pipeline. The results directory contains
no reference FASTA, only the consensus. The single reference bundle in the test
project is `NC_045512`, which is the same genome under a different accession and
therefore carries sequence identifiers that do not match the `MN908947.3` in the
BAM and VCF.

The resolution is to stop letting the pipeline choose the reference. Lungfish owns
it instead, and passes it in.

Viral Recon is a SARS-CoV-2 tool. Every bundled primer scheme declares
`organism` as severe acute respiratory syndrome coronavirus 2 and names
MN908947.3 as its canonical accession. There is no configuration in which some
other genome is correct, because the primer schemes would not apply to it.

The reference is therefore hard-coded, not chosen and not searched for. Viral
Recon uses MN908947.3, defined as a single constant rather than a wizard default
string, which is how the accession is expressed today.

Acquisition has exactly two outcomes:

1. `Downloads/MN908947.3.lungfishref` exists in the project. Use it.
2. It does not. Download it from NCBI GenBank through the existing fetch path,
   which retrieves sequence plus GFF3 annotations and builds a `.lungfishref`
   with indices, then use it.

That bundle is handed to the pipeline explicitly rather than letting `--genome`
resolve to a remote URL, and it is the same bundle the results are published
into.

There is deliberately no matching of the requested reference against other
bundles in the project. The scheme manifests record NC_045512.2 as biologically
equivalent, and it is the same genome, but equivalence is not interchangeability:
a bundle built from NC_045512.2 carries that identifier in its FASTA header while
the primer BED is written against MN908947.3, so the trimming step would find
nothing to match and the run would produce a quietly wrong result. Substitution
is not attempted. A project holding only the NC_045512.2 form gets the download.

Three consequences follow, and they shape the whole design.

First, the reference is a first-class Lungfish artifact before the pipeline runs,
so ingest never has to scavenge it from a Nextflow cache afterwards.

Second, the same bundle serves as pipeline input and as the results viewer bundle.
There is no copying, no second source of truth, and no possibility of the viewer
showing a different reference from the one reads were aligned to.

Third, back-filling existing result directories remains out of scope. Those runs
resolved their reference remotely and it is no longer on disk. This matches the
decision already taken: new runs only.

## Co-equal outputs

The consensus sequence, the alignment with its within-host variation, and the
variant calls are three views of one sample. None is the headline. The design
therefore promotes none of them above the others and does not scatter them into
different project folders.

Verified coordinates for the cited run:

| Output | Sequence | Length |
|---|---|---|
| Sorted BAM | MN908947.3 | 29,903 |
| iVar VCF | MN908947.3 | 29,903 |
| Consensus FASTA | `>SRR11140748_1 MN908947.3` | 29,900 |

The consensus is reference-named but not reference-length. It is three bases
shorter because bcftools applied indels, including `AATT` to `A` at position
20,297. A consensus track laid over the reference by positional index would drift
after the first indel and mis-place every downstream feature. This is the single
most likely way for this work to ship a display that quietly lies, so it is
called out here and given its own test.

## Design

### Sidebar

One run produces one analysis bundle under `Analyses/`, mirroring the shape a
minimap2 run already produces and which `SidebarProjectScanner` already
recognises:

    Analyses/
      Viral Recon 2026-09-02/
        analysis-metadata.json          tool: viralrecon
        viralrecon-result.json          summary + paths, analogous to mapping-result.json
        MN908947.3.lungfishref/         the viewable bundle
        consensus/                      consensus FASTA
        lineage/                        pangolin, nextclade, freyja
        reports/                        multiqc, fastqc, fastp
        results/                        raw nf-core output, untouched

The raw output is preserved rather than moved, so nothing is lost and provenance
remains verifiable against what the pipeline actually wrote.

### Viewport

The `.lungfishref` bundle is the hard-coded MN908947.3 bundle acquired before the
run, and it registers three tracks over one coordinate system:

    MN908947.3  |=========================================|
    consensus   |=====N N N===============================|
    variants    |    ^      ^        ^      ^             |
    alignment   |#########################################|

Alignment and variant registration reuse `MappingViewerBundlePublicationService`,
which already publishes both into a reference bundle manifest and already handles
variant paths, indexes and sidecar databases. This work adds a Viral Recon caller
for that service rather than a second publication path.

The consensus track is derived through a reference-to-consensus coordinate map
built by walking the VCF, not by positional identity. Ns render as gaps.

### Inspector

Files are catalogued by scientific role, not presented as a file tree:

- Consensus: sequence length, N count, percent ambiguous.
- Lineage: Pangolin call, Nextclade clade, Freyja demix abundances.
- Variants: count by type, transition/transversion ratio.
- Quality: MultiQC summary, per-sample FastQC and fastp.
- Provenance: pipeline version, parameters, execution trace.

### Failure handling

Ingest failure must not destroy a successful pipeline run. If the reference cannot
be captured, or bundle construction fails, the run is still reported as completed,
the raw output is left intact, and the bundle is marked unavailable with the
reason surfaced in the Inspector. A visualisation problem is not permitted to
present as a lost analysis.

## Testing

- Ingest against a synthetic nf-core output tree in a temp directory, so the test
  runs without Docker or a live pipeline.
- Coordinate mapping against the real indel from the cited run, `AATT` to `A` at
  20,297, asserting a variant after it lands on the correct consensus base. This
  test exists specifically to catch silent drift.
- Manifest registration asserting the published bundle carries both the alignment
  and the variant track and that the viewport contract is satisfied.
- Ingest failure leaves raw output intact and reports the run as completed.
- Full unit gate before merge.

## Out of scope

- The Viral Recon wizard. Track B, separate design, separate approval.
- Back-filling existing result directories, for the reference-capture reason above.
- Promoting the consensus into `Reference Sequences/`. Revisit once the layered
  view is in use.

## Multi-sample runs

Samples are processed one per run, following the contract other batch tools in
this application already use. `AnalysesFolder.createAnalysisDirectory` with
`isBatch: true` produces `viralrecon-batch-<timestamp>/`, holding one sanitized
subdirectory per sample, exactly as `TaxTriageSerialBatchRunner` does. Each
sample subdirectory carries the single-sample bundle described above, so the
per-sample shape is unchanged and the layered viewport works identically whether
one sample was run or twenty.

`SidebarProjectScanner.buildAnalysisNode` already branches on `isBatch` and
renders a batch node, so the sidebar requires no new node type.

The reference is acquired once for the batch, not once per sample, since every
sample in a Viral Recon run uses the same hard-coded SARS-CoV-2 reference.
