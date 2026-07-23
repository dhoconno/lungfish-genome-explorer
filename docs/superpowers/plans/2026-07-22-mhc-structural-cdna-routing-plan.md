# Structural cDNA Routing Implementation Plan

## 1. Lock the shared structural policy with tests

- Add focused CIGAR/coverage tests for cohort and reciprocal orientations.
- Cover internal cDNA, splice `N`, terminal flanks, partial cDNA, small indels, reverse strand, and exact genomic controls.
- Implement a compact shared structural classifier rather than duplicating thresholds.

## 2. Correct production known-genotype routing

- Materialize the annotated reference catalog before the final cohort BAM is parsed.
- Pass molecule class and cluster length into the production streaming parser.
- Replace the cDNA binary zero-SNP gate with structural known/extension/ineligible classification.
- Keep exact genomic handling stable and leave the standalone vestigial parser untouched.

## 3. Preserve full oriented candidates and compact interpretations

- Preserve the complete oriented consensus through normalization, deduplication, reciprocal mapping, and candidate identity.
- Retain closest interval trim only as metadata.
- Extend compact target summaries to retain all compatible cDNA structural interpretations without BAM locators.
- Add regressions for reverse-complement identity and deterministic deduplication.

## 4. Resolve candidates with joint evidence

- Route unmatched and structural-cDNA clusters into candidate classification.
- Retain every compatible cDNA in `extensionOf`.
- Use unambiguous genomic evidence for locus, closest-reference comparison, feature liftover, and consequence analysis.
- Apply deterministic ambiguity handling and preserve exact genomic known calls.
- Advance the new-bundle candidate schema while retaining backward decoding.

## 5. Propagate the result through current artifacts

- Add `extensionOf` and selected genomic interpretation to candidate JSON and provenance.
- Add extension and genomic-reference comments to candidate GenBank.
- Preserve full-length and UTR-trimmed nucleotide columns in the two-sheet workbook and add `Extension Of`.
- Expose the compact joint interpretation in the current detail facts rail and artifact manifest.
- Update validators and explicit workbook-update handling for the new schema.

## 6. Review and verify

- Run focused production parser, classifier, artifact, workbook, viewport, manifest, and provenance suites.
- Run the combined forward full-length ONT MHC suite.
- Build a fresh `Lungfish Debug` bundle.
- Run the four-sample exemplar through the newly bundled CLI and inspect `_ext` candidates, sorted/indexed BAMs, JSON, FASTA, GenBank, Excel values/types, manifest, and provenance.
- Quit all Lungfish processes and launch only the newly built debug app.

