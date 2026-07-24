# MHC Allele Display Ordering Design

## Scope

Apply one presentation-only ordering contract to full-length ONT MHC genotypes in:

- the `display_name` rows of the `Unified Genotype Pivot` worksheet;
- the `Provisional Allele Name` rows of the `Unmatched Alleles` worksheet;
- the unified known/candidate genotype matrix in the Lungfish viewport; and
- explicit workbook updates, so regenerated workbooks retain the same order.

This change does not alter allele classification, naming, scientific artifacts, schemas, or provenance.

## Ordering Contract

Parse an allele display name in the general form `<species-prefix>-<locus>*<allele>` into independent species-prefix, locus, and allele components. The species prefix does not affect the biological group rank: `Mafa-*`, `Mamu-*`, and other species prefixes follow the same locus rules. Rank named rows in this order:

1. Numbered `A` loci (`A1*`, `A2*`, `A3*`, and so on), ordered by locus number.
2. `B*`.
3. Numbered or suffixed `B` loci (`B02ps*`, `B14*`, `B16*`, `B22*`, and so on), ordered naturally by locus text.
4. `I*`.
5. `F*`.
6. `G*`.
7. `AG*`.
8. `J*`.
9. `K*`.
10. Any other named locus, ordered naturally by the complete display name.
11. Rows without a provisional display name.

Within a locus group, compare the locus and allele components with a locale-independent ASCII-natural ordering. Split expected MHC identifiers into ASCII digit and non-digit chunks; compare numeric chunks by overflow-free magnitude and non-digit chunks by ASCII-lowercased scalar order. This makes Swift viewport/initial-workbook ordering and Python explicit-update ordering identical, including expression suffixes and generated `_nov`/`_ext` suffixes. Species prefix is used only after locus and allele when different species prefixes appear in one result. When two distinct sequences have the same display name, use stable cluster ID and then exact scalar fallbacks as deterministic tie-breakers. Blank provisional names sort by stable cluster ID.

The parser must match the exact locus token between the species-prefix separator and `*`; for example, `G` and `AG` are distinct groups. It must not contain hard-coded `Mafa` or `Mamu` behavior.

Numbered A/B loci use ASCII digits, and optional B-locus suffixes use ASCII letters. Non-ASCII names are retained as unspecified loci rather than being assigned different biological ranks by different runtime libraries.

## Architecture

Add a small shared Swift display-order utility in the genotype data layer used by both `LungfishWorkflow` and `LungfishGenotypeUI`. It returns a comparison result for two display names and accepts deterministic fallback identifiers.

Use that utility in initial workbook projection and the viewport's default allele sort. Preserve user-selected viewport column sorting, but use the biological display order whenever the allele/display-name column is the active sort, including its default state.

The explicit workbook-update path runs in an embedded Python script. Mirror the same documented sort-key contract there and test it against the Swift ordering fixtures. Do not add schema fields solely for sorting.

## Error and Fallback Behavior

Malformed or otherwise unrecognized nonblank names are treated as unspecified loci and placed after the requested locus groups. They are never dropped. Empty names are placed last. All comparisons remain deterministic through natural-name and stable-ID tie-breakers.

## Tests

Add test-first coverage for:

- the complete requested cross-locus order;
- the same ordering fixtures under at least `Mafa-` and `Mamu-` prefixes;
- `B*` before numbered/suffixed B loci;
- natural numeric order within A, B, and allele-number groups;
- identical Swift/Python order for expression suffixes and `_nov`/`_ext` names;
- exact separation of `G` and `AG`;
- unspecified and blank names at the bottom;
- duplicate provisional names remaining as separate stable-ID rows;
- initial Unified and Unmatched worksheet ordering;
- explicit workbook-update ordering; and
- viewport default and allele-column ordering.

Run the focused workflow, workbook-update, and viewport suites, then rebuild and relaunch `Lungfish Debug`.
