# MHC Allele Display Ordering Design

## Scope

Apply one presentation-only ordering contract to full-length ONT MHC genotypes in:

- the `display_name` rows of the `Unified Genotype Pivot` worksheet;
- the `Provisional Allele Name` rows of the `Unmatched Alleles` worksheet;
- the unified known/candidate genotype matrix in the Lungfish viewport; and
- explicit workbook updates, so regenerated workbooks retain the same order.

This change does not alter allele classification, naming, scientific artifacts, schemas, or provenance.

## Ordering Contract

Parse a Mafa allele display name into the locus text before the first `*` and the allele text after it. Rank named rows in this order:

1. Numbered `Mafa-A` loci (`Mafa-A1*`, `Mafa-A2*`, `Mafa-A3*`, and so on), ordered by locus number.
2. `Mafa-B*`.
3. Numbered or suffixed `Mafa-B` loci (`Mafa-B02ps*`, `Mafa-B14*`, `Mafa-B16*`, `Mafa-B22*`, and so on), ordered naturally by locus text.
4. `Mafa-I*`.
5. `Mafa-F*`.
6. `Mafa-G*`.
7. `Mafa-AG*`.
8. `Mafa-J*`.
9. `Mafa-K*`.
10. Any other named locus, ordered naturally by the complete display name.
11. Rows without a provisional display name.

Within a locus group, compare the complete display name with numeric-aware natural ordering. When two distinct sequences have the same display name, use stable cluster ID and then the existing deterministic row identity as tie-breakers. Blank provisional names sort by stable cluster ID.

The parser must match the exact locus token before `*`; for example, `G` and `AG` are distinct groups.

## Architecture

Add a small shared Swift display-order utility in the genotype data layer used by both `LungfishWorkflow` and `LungfishGenotypeUI`. It returns a comparison result for two display names and accepts deterministic fallback identifiers.

Use that utility in initial workbook projection and the viewport's default allele sort. Preserve user-selected viewport column sorting, but use the biological display order whenever the allele/display-name column is the active sort, including its default state.

The explicit workbook-update path runs in an embedded Python script. Mirror the same documented sort-key contract there and test it against the Swift ordering fixtures. Do not add schema fields solely for sorting.

## Error and Fallback Behavior

Malformed, non-Mafa, or otherwise unrecognized nonblank names are treated as unspecified loci and placed after the requested Mafa groups. They are never dropped. Empty names are placed last. All comparisons remain deterministic through natural-name and stable-ID tie-breakers.

## Tests

Add test-first coverage for:

- the complete requested cross-locus order;
- `Mafa-B*` before numbered/suffixed B loci;
- natural numeric order within A, B, and allele-number groups;
- exact separation of `G` and `AG`;
- unspecified and blank names at the bottom;
- duplicate provisional names remaining as separate stable-ID rows;
- initial Unified and Unmatched worksheet ordering;
- explicit workbook-update ordering; and
- viewport default and allele-column ordering.

Run the focused workflow, workbook-update, and viewport suites, then rebuild and relaunch `Lungfish Debug`.
