# MHC Candidate GenBank Consequence Comments Design

## Scope

This change applies only to the forward full-length ONT MHC `Candidate Alleles GenBank` artifact. It does not change candidate classification, provisional naming, JSON/SQLite schemas, viewport behavior, Excel layout, BAM artifacts, or any vestigial workbook/genotyping workflow.

The renderer will use the already selected closest reference visualization, candidate sequence, reciprocal alignment start/orientation/CIGAR, and lifted reference features. It will not reread a BAM.

## Required comments

Every candidate with a selected annotated closest reference will contain these stable summary `COMMENT` fields:

1. `Lungfish exon 2/3 nonsynonymous changes:`
2. `Lungfish CDS nonsynonymous changes:`
3. `Lungfish CDS synonymous changes:`
4. `Lungfish intronic changes:`

The summaries refer to deterministic detail identifiers (`CDS-NS-1`, `CDS-SYN-1`, `INTRON-1`, and `INTRON-FILL-1`). Detail comments enumerate the reference-oriented nucleotide change, 1-based reference and stored-candidate coordinates, exon/intron number when available, 1-based CDS nucleotide/codon/amino-acid position where applicable, and predicted product effect.

Each summary must distinguish:

- `none detected in complete annotated region`;
- `none detected in aligned portion (partial coverage)`; and
- `unavailable` or `unresolved`, with a reason.

## Change derivation

The existing CIGAR projection becomes the single source of aligned change events. It will retain:

- substitutions, using `X` and also direct base comparison for `M`;
- query insertions;
- reference deletions; and
- skipped/unassessed `N` regions.

Alleles are reported in closest-reference orientation. Reverse-query alignments compare the reverse complement of the candidate to the reference while mapping positions back to the stored GenBank `ORIGIN`. All reported coordinates are 1-based and the record includes a coordinate-convention comment.

## Coding consequences

The primary annotated CDS is interpreted in transcript order using feature strand, `codon_start`, and `transl_table`. Unsupported or ambiguous CDS semantics are unresolved rather than silently treated as standard.

Substitutions in the same codon are grouped and applied together before translating the alternate codon. A codon is synonymous only when the complete observed alternate codon translates to the same amino acid. Otherwise the detail reports missense, stop-gained, or stop-lost impact. Ambiguous codons/translations receive a `CDS-UNRESOLVED-*` detail and are not counted as synonymous or nonsynonymous.

Ordinary coding insertions/deletions are protein-altering. Net length divisible by three is reported as frame-preserving; other net lengths are frame-disrupting. Complex adjacent events are described conservatively using the recomputed whole-candidate translation status, length, and internal-stop information rather than overclaiming a precise HGVS consequence.

Exon number qualifiers take precedence. If absent, exon numbers are inferred in 5-prime-to-3-prime transcript order. The exon 2/3 summary is a subset of the all-CDS nonsynonymous details and names the relevant detail identifiers.

## Intronic consequences and cDNA extensions

For genomic references, explicit intron features take precedence. Otherwise introns are inferred only from gaps between transcript-ordered exons within the annotated gene. Intronic substitutions and indels are enumerated with position and intron number. Their direct CDS translation effect is reported as none, while splice/regulatory impact is explicitly not assessed.

For cDNA references, an internal query insertion at least `minimumIntronGapBases` that is used as an inferred intron fill is `INTRON-FILL`, not a coding insertion. Its reference boundary, stored candidate range, and length are reported, along with the statement that the closest cDNA contains no homologous intron sequence and splice impact is not assessed. Ordinary short CDS indels remain coding changes. A cDNA intron fill adjacent to an ordinary deletion reports both events independently.

Non-CDS exonic/UTR changes are not mislabeled as intronic. Unplaceable aligned changes are reported as unresolved/unclassified rather than omitted.

## Partial and missing annotation

Missing 5-prime CDS coverage, partial GenBank locations, unknown strand, skipped CIGAR regions, unsupported translation tables, or ambiguous CDS groups prevent definitive `none`, synonymous, or nonsynonymous conclusions for the affected region. Nucleotide changes are still enumerated where possible with unresolved protein effect.

Candidates without a selected annotated reference receive all four stable summaries as unavailable. Un-nameable GenBank records remain unchanged except that the shared render transformation records the same provenance options.

## Provenance

The candidate and un-nameable GenBank render provenance records:

- change source: selected closest-reference sequence, one-based start, CIGAR, and candidate sequence; no BAM reread;
- one-based reference/candidate/CDS/exon/intron/amino-acid coordinate convention;
- grouped same-codon substitution and strand/codon-start/translation-table rules;
- ordinary coding-indel frame rule;
- cDNA intron-fill exclusion from CDS changes; and
- unresolved-never-coerced ambiguity policy.

Existing input/output descriptors, checksums, sizes, argv, runtime identity, exit status, and timing remain required.

## Acceptance criteria

- Forward genomic fixtures enumerate exon-2/3 missense, other CDS missense, synonymous CDS, and intronic changes correctly.
- Multiple substitutions in one codon are classified from their combined alternate codon.
- Reverse alignment and reverse-strand CDS coordinates/alleles/translations are correct.
- Frame-preserving and frame-disrupting coding indels are distinguished.
- cDNA intron fills do not become coding indels, including when adjacent to an ordinary deletion.
- Partial/ambiguous records never emit false definitive `none` or false synonymous/nonsynonymous claims.
- GenBank output is deterministic and round-trips through the reader/writer.
- Published candidate artifacts and provenance contain the new comments/rules.
- No BAM reread, schema change, legacy workflow change, or unrelated UI change is introduced.
