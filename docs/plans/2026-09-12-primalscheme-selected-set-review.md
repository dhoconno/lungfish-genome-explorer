# PrimalScheme selected-set semantics

## Finding

The LGE viewport and ordering worksheet read the final `primer.bed`. They do not read the discovery candidate collections. PrimalScheme selects a pair of forward and reverse **sequence groups** for an amplicon; a selected group can contain several distinct oligos. All exported members belong to the selected scheme. There is no separately exported ranking that identifies one preferred LEFT/RIGHT oligo combination and marks the others as backups.

Upstream identifies `primer.bed` as the primary output for ordering and describes converting its records into pool-organized order sheets: [PrimalScheme output documentation](https://primalscheme.com/#primary-output-files).

The implementation audit used the exact LGE fork revision `00eaa252446f01cabfeae71e10306a68cdb941d6`:

- [Selected pool export](https://github.com/dhoconno/primalscheme3-lge/blob/00eaa252446f01cabfeae71e10306a68cdb941d6/primalscheme3/core/multiplex.py#L427) flattens primer-pair objects already added to pools.
- [Primer-pair serialization](https://github.com/dhoconno/primalscheme3-lge/blob/00eaa252446f01cabfeae71e10306a68cdb941d6/primalscheme3/core/classes.py#L154) writes all forward and reverse group members. Sequence suffixes enumerate oligos; they do not rank quality or establish LEFT-to-RIGHT pairs. The native sequence containers sort sequences lexicographically: [primalschemers v0.1.13](https://github.com/ChrisgKent/primalschemers/blob/v0.1.13/src/kmer.rs#L185).
- [Scheme selection](https://github.com/dhoconno/primalscheme3-lge/blob/00eaa252446f01cabfeae71e10306a68cdb941d6/primalscheme3/scheme/classes.py#L140) ranks candidate group pairs before adding accepted objects to pools.
- The diagnostic `plot.html` thermopassing-sites panel includes broader discovery counts. Its selected amplicon panel is a separate data collection: [report data](https://github.com/dhoconno/primalscheme3-lge/blob/00eaa252446f01cabfeae71e10306a68cdb941d6/primalscheme3/core/create_report_data.py#L240). LGE retains that native diagnostic with the other files; its scientific viewport uses the final BED.

## Retained MHC output audit

Two independent reviewers traced native selection/export and LGE import/membership/order generation. Six retained analysis bundles had exact native BED-to-order-sheet correspondence, with all displayed records linked to the correct amplicon, reference and pool.

| Bundle | Possible amplicons logged during discovery | Selected amplicons | Exported oligos |
| --- | ---: | ---: | ---: |
| human-three-msas | 669,567 | 141 | 282 |
| human-A-managed | 34,162 | 19 | 38 |
| human-A-narrow | 14,072 | 20 | 40 |
| human-A-wide | 34,162 | 19 | 38 |
| human-DP-wide | 635,405 | 120 | 240 |
| macaque-DQ-wide | 222,368 | 68 | 198 |

The retained macaque bundle contains 42 amplicons with multiple variants. Amplicon `3454672e_3` contains two LEFT and two RIGHT records. Saved sequence comparisons match LEFT_1 with RIGHT_2 for one Mafa-DQA1 allele and LEFT_2 with RIGHT_1 for the other. Selecting only suffix `_1` would discard exact-match members for these allele combinations. These observations concern sequence matching, not experimentally established amplification performance.

The retained native bundles have at most two RIGHT records per amplicon, so the user's particular six-RIGHT result was not identified in this audit. A synthetic six-RIGHT display fixture verifies that all members remain visible, selectable and associated with their saved amplicon. Native exports allow larger groups through the same serialization path.

## Presentation decision

Keep every final BED record and preserve the ordering CSV bytes. Re-ranking or dropping oligos would create a different design unsupported by PrimalScheme's saved output. A label-only explanation would leave the focused amplicon's set difficult to distinguish from the pool-wide list, so the bounded correction also groups members by direction.

The Results list is labeled **Selected scheme oligos**, with its scope explicitly covering all selected amplicons in the chosen pools. The focused amplicon shows a **Selected primer set** with forward/LEFT, reverse/RIGHT and any other retained members grouped and counted. Numbered suffixes are explained as identifiers, not ranks or matched pairs. Primer3 retains its independent candidate-pair presentation. Existing copy, alignment, extraction, ordering and Inspector interactions remain in use.

This change is read-only presentation. It does not rewrite scientific bundles, alter native calculations, add assay recommendations, or change provenance and ordering artifacts.

## Verification

The six-RIGHT regression failed first on the four missing presentation labels, then passed with the production changes. The focused viewer, selection, clipboard, context-menu, Primer3 and ordering-sheet suite passed **51 tests with zero failures and zero skips**. Native MHC loading checks compare every displayed name and sequence with the saved BED in its original order. Existing ordering-sheet tests retain native sequence orientation, separate variants, pool grouping and escaping.

Offscreen AppKit renders at 650- and 1,000-point widths were inspected for the synthetic seven-oligo set and a retained native macaque MHC amplicon. Direction headings, counts, sequences, pool labels and reference spans remain readable. The native fixture and synthetic display fixture are identified separately. Final independent bioinformatics review found no actionable semantic issues.

Local evidence: `.build/primal-selected-set-red.log`, `.build/primal-selected-set-green.log`, and `.build/primal-selected-set-visual/`. These are development diagnostics, not new scientific analysis outputs.
