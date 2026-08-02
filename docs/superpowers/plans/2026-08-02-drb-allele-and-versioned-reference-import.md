# DRB Allele and Versioned Reference Import Plan

## Outcome

Allow established IPD-MHC DRB `W` allele designations (for example,
`Mamu-DRB*W001:01`) to pass reference validation, preserve version punctuation
in imported reference bundle names, and display annotated allele names rather
than database accession IDs. Validate the supplied shorter DRB amplicon data
before deciding whether a separate partial-reference mode is necessary.

## Scientific constraints

- Keep malformed or unknown allele-name forms rejected. The exception is the
  established uppercase `W` prefix on the first DRB allele field, followed by
  the same numeric/suffix grammar already used for ordinary allele fields.
- Keep the current matching rules unchanged unless the supplied data produces
  no calls or implausibly few calls.
- Do not report a partial sequence as a definitive full-length allele without a
  clear ambiguity model in the viewport and exports.
- Preserve existing workflow provenance and verify it on the real-data run.

## Implementation

1. Add regression tests for annotated and FASTA-header DRB `W` alleles, plus a
   negative test showing an arbitrary alphabetic prefix remains invalid.
2. Extend only the primary allele-field validator to accept `W` followed by a
   valid numeric allele field.
3. Add reference-name tests for versioned `.gb`, compressed `.gb.gz`, and
   versioned FASTA inputs.
4. Change reference import naming to remove one recognized compression suffix
   and one recognized sequence-format suffix, preserving all other dots.
5. Preserve annotated allele names in final calls while retaining source
   accession IDs in row-level evidence.
6. Run the supplied four-sample DRB analysis into a temporary output directory
   and inspect calls, unmatched results, totals, and provenance.
7. Record whether a partial-reference mode is needed. The final strict run assigned
   2,575 of 4,760 input reads (54.1%) and 65.2% of clustered reads, so the
   existing workflow already accommodates reads that do not span the full
   genomic reference. A separate mode was therefore deferred; it would require
   explicit presentation of equally compatible alleles before it could be
   scientifically safe.
8. Obtain independent code/scientific review, resolve findings, and build a
   debug app for testing.
