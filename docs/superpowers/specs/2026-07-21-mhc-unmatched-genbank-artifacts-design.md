# Full-length MHC unmatched-cluster GenBank artifacts

## Scope

Fresh full-length ONT MHC analyses will publish two deterministic, multi-record GenBank companions:

- `candidate_alleles.gb` for named `_nov` and `_ext` clusters.
- `unnameable_unmatched_clusters.gb` for clusters that cannot receive a provisional allele name.

This is limited to the full-length MHC analysis surface. The files are scientific output artifacts, not UI-generated exports. Existing reference-allele visualization artifacts remain unchanged.

## Record identity and traceability

Each record uses the stable cluster ID as its accession/record identity so it can be joined directly to the candidate JSON and deduplicated unmatched FASTA. The definition contains the provisional allele name and classification, or the un-nameable reason.

Every record includes a whole-sequence `source` feature and comments containing:

- stable cluster ID and sequence checksum;
- support class, sorted supporting sample IDs, independent sample count, occurrence count, and total cluster reads;
- selected closest reference raw ID and allele label when available;
- reciprocal alignment start, CIGAR, and orientation;
- analysis name and source Lungfish project bundle name;
- the liftover/translation policy used to derive the record.

The project comment stores the project bundle name rather than an absolute path. Reproducibility provenance retains the exact input/output paths.

## Annotation liftover

The selected reciprocal minimap2 alignment maps an unmatched-cluster query to the closest reference target. Reference features are projected through its CIGAR using 0-based, half-open coordinates:

- `M`, `=`, and `X` consume reference and query and produce mapped blocks.
- `D` and `N` consume reference only.
- `I` consumes query only.
- `S` consumes query without mapping it to the reference.
- `H` consumes neither.

Reverse mappings convert projected coordinates back to the stored candidate orientation and reverse feature strand. Gene, exon, CDS, mRNA, and intron features are lifted when their reference intervals intersect mapped blocks. Candidate sequence that fills a long cDNA gap is represented in the projected gene span and as inferred intron sequence; it is excluded from joined CDS translation. Short insertions inside coding regions remain part of the coding interval.

Malformed or out-of-bounds projections fail artifact generation rather than silently emitting incorrect annotations. An un-nameable record without a selected alignment remains a valid source-only record with an explicit annotation-unavailable comment.

## Translation and exon structure

The candidate CDS translation is recomputed from the lifted candidate intervals; a reference `/translation` is never copied. The source strand and codon start are honored. A terminal stop is omitted from the displayed translation, while internal stops or invalid frames are recorded as translation warnings.

For cDNA references, long query insertions that satisfy the configured intron threshold split the lifted transcript into inferred exon intervals. Exon numbering and the resulting exon count, including a possible terminal eighth exon, come from the projected transcript structure rather than a fixed expected count. If the selected alignment does not completely and unambiguously support this inference, the GenBank comment states that exon-count inference was withheld.

## Manifest, loading, and provenance

The candidate artifact manifest remains schema 1 and gains optional `candidate_genbank` and `unnameable_genbank` references. Their paths, sizes, checksums, and regular-file containment are validated when a bundle loads, but their bytes do not count against the parsed JSON/FASTA memory budget because the viewport does not eagerly parse them.

The candidate writer publishes the GenBank companions in the same staging generation as JSON, FASTA, BAM, and BAI. Each transformation records workflow/app version, reproducible argv, resolved thresholds and coordinate rules, source reference bundle, candidate JSON/FASTA inputs, project identity, output checksums/sizes, runtime identity, exit status, wall time, and stderr on failure.

## Viewport relationship

The current graphical pane continues to use the bounded closest-reference visualization plus candidate sequence and selected alignment. The present Ionis display failure is caused by its 567 MB schema-1 candidate JSON exceeding the 256 MiB loader budget, not by missing reference graphics. A fresh schema-2 run, plus schema-2 loader/UI support, restores candidate rows and graphics. Candidate GenBank files are available as durable artifacts even before the viewport gains a candidate-annotated GenBank renderer.

