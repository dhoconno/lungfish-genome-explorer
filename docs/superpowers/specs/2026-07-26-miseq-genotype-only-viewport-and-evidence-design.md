# miSeq Genotype-Only Viewport and Evidence Design

## Objective

Use the existing native genotype matrix and Inspector for genotype-only miSeq
amplicon MHC results, publish the BAM/BAI that directly support the reported
genotypes, and identify observed `_nov` reference matches as **Provisional
exon 2** sequences.

The workflow's mapping, filtering, genotype-calling, workbook, and optional
haplotyping recipes remain unchanged. Publication is gated on the pipeline's
resolved `.illuminaPaired` mode, so ONT barcode-demultiplex and ONT
sample-bundle cleanup behavior remains unchanged. This feature only makes
existing scientific outputs durable, adds derived review artifacts, and
presents those artifacts through shared result-view code.

## Result-mode boundary

A result with native calls and no loaded haplotype analysis continues to open
in the shared genotype-only matrix. It receives the filtering, search,
row/column visibility, content text sizing, comments, false-positive and
false-negative review, selection details, and current-workbook behavior already
implemented by `GenotypeResultViewController`.

A result with a haplotype analysis keeps its existing viewport and Inspector
presentation. The only visible addition for a haplotyped miSeq result is the
requested Genotyping Evidence BAM and BAI in its artifact list.

No miSeq result receives the full-length candidate-allele, cDNA-extension, or
reciprocal-evidence interfaces.

## Durable genotyping evidence

The filtered `*.retained.demuxed.bam` and its BAI are the authoritative
genotyping evidence because they contain the alignments that passed the
workflow's existing filters and produced the reported per-sample read counts.
They become durable bundle outputs instead of regenerable intermediates.

`genotype-result.json` gains a generic optional alignment-artifact declaration.
Each member records its bundle-relative path, SHA-256 checksum, and byte size.
The declaration contains a Genotyping Evidence pair for miSeq and no Reciprocal
Evidence pair. Existing full-length nested evidence declarations remain
backward compatible and are projected through the same loaded URL model.

The workflow provenance envelope records the retained BAM and BAI as outputs,
including checksums and sizes. Mapping BAMs and per-sample mapping intermediates
remain regenerable and are removed as before.

If provisional publication fails before provenance can be committed, the
pipeline transactionally removes its generated BAM/BAI, genotype summaries,
provisional files, workbook outputs, reference snapshot, and partial
provenance/manifest files. The transaction remains open through final manifest
commit, so a failed command cannot leave unprovenanced scientific payloads
masquerading as a result bundle.

Regenerable mapping-intermediate cleanup runs only after that commit and is
best-effort. A housekeeping failure may leave an intermediate for later
cleanup, but cannot roll back or damage the completed, provenanced result.

After a GUI-launched workflow completes, Operation Center discovers these
outputs through the validated bundle manifest and result loader. It reports the
retained BAM/BAI and optional provisional JSON/FASTA, while continuing to omit
mapping intermediates. Declared artifacts that fail path, size, or checksum
validation fail operation completion instead of silently disappearing from the
output list.

## Provisional exon 2 sequences

An observed genotype is provisional when its exact run-recorded genotype
identifier contains `_nov`, case-insensitively. Lungfish does not query,
resolve, rename, or reconcile this identifier against an allele database.
Historical aliases and independently installed database versions do not affect
the designation.

After the existing genotype CSV is produced, a publication step reads only the
observed `_nov` identifiers and their exact records from the reference FASTA
used by that run. When provisional calls exist, it writes:

- `artifacts/sequences/observed-provisional-exon2.json`
- `artifacts/sequences/observed-provisional-exon2.fasta`

The JSON document stores the original genotype identifier, inferred locus,
FASTA record identity, exact sequence length and SHA-256, and per-sample read
support. The FASTA uses the original identifier and exact run reference
sequence. Both files, and the reference FASTA and genotype CSV that produced
them, are recorded in provenance. A provisional identifier that cannot be
resolved in the run's reference FASTA is a publication error rather than an
occasion to substitute another allele name.

The loader validates paths, regular-file status, sizes, checksums, JSON/FASTA
agreement, unique identifiers, sequence lengths, sequence checksums, and the
requirement that every catalog entry corresponds to an observed call.

## Viewport presentation

In genotype-only miSeq results:

- The allele identity cell receives a subtle amber treatment.
- Its tooltip and accessibility description include “Provisional exon 2”.
- The matrix legend includes an amber provisional-exon-2 key.
- Search indexes the original `_nov` identifier and the designation.
- Selecting the row or a supported cell shows the original identifier, locus,
  sequence length, observed samples, per-sample read support, comments, and the
  exact sequence using the existing sequence-detail renderer.
- The detail pane states that the sequence is a short exon 2 provisional
  reference match and is not an IPD-qualified novel-allele designation.

Read-count cells retain their existing evidence colors and annotation chrome.
The amber treatment is confined to allele identity presentation so it cannot
be mistaken for read support, false-positive status, false-negative status, or
a user highlight.

## Inspector and workbook behavior

The Inspector lists Genotyping Evidence BAM/BAI and, when present, the observed
Provisional Exon 2 JSON/FASTA. It does not list Reciprocal Evidence for miSeq.
Genotype-only View and Annotation controls remain those of the shared
controller. Haplotype-only controls remain unchanged.

Comments and false-positive/false-negative annotations continue to use the
existing annotation sidecar, audit log, and current-workbook publication path.
Provisional designation is immutable run evidence, not a user annotation, and
therefore is not written into the annotation audit log.

Workbook revisions and AI-haplotyping manifest revisions preserve both
scientific-artifact declarations. When a genotype-only result becomes
haplotyped, its provisional sequence files remain durable bundle evidence but
are not added to the haplotyped viewport or Inspector; Genotyping Evidence
BAM/BAI remain visible as required.

## Performance and compatibility

Bundle loading remains off the main actor. Artifact validation is a single
linear pass and the viewport stores provisional membership and sequence
records in keyed dictionaries. Matrix filtering, scrolling, selection, and
redraw do not parse FASTA or scan artifacts.

Validated BAM/BAI digests are cached in memory by device, inode, byte size,
modification/change timestamps, and declared SHA-256. Operation Center and the
immediately opened viewport therefore share integrity work for unchanged
evidence, while a same-size mutation invalidates the cache and is rechecked.

All new manifest fields are optional. Older miSeq bundles continue to load and
use the native genotype-only matrix when they contain calls, but cannot offer a
sequence view or BAM artifact link that was not published at run time.
