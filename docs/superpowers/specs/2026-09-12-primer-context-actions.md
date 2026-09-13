# Primer analysis context actions

## Scope and decisions

Extend the saved primer-analysis Overview and Results using native macOS context menus. The clicked primer or amplicon supplies the selection identity, independently of the previous selection. Reuse the existing detail card, MSA binding view, project write gate, native reference format and Operations panel.

The menus expose identity, coordinates, strand, span/length and pool; inspection; sequence/FASTA/coordinate copies; associated-oligo and whole-pool copies; primer FASTA bundle creation; and reference-amplicon bundle extraction. Pool membership is scoped to a native result so two independent schemes' similarly numbered pools cannot merge. Alternative oligos retain independent records. Reverse oligos retain their saved synthesis orientation.

Reference extraction uses the explicit saved forward-reference interval, including primer footprints. It does not infer individual alternative-pair products or per-allele product lengths. Verified linked annotations shift by the interval start. Primer3 internal probes retain `internal_oligo` feature type based on normalized identity. Unavailable primer correspondence cannot silently produce an associated-primer FASTA.

Every saved derivative is a native `.lungfishref` in the originating project's Analyses directory. There is no output chooser. The operation captures project/window identity, validates the current write gate and real directory identity, and stages sequence and annotations together. Final project/operation checks, exclusive publication and Operations completion share one synchronous MainActor turn. Cancellation before that commit, source corruption, a changed project directory, or an existing output prevents publication. Cancellation after completion cannot hide the saved result.

`selection.json` records schema version, analysis/run/record identities, source intervals, original oligo names, sequences, strand, pool, semantics and resolved options. Plain FASTA and BED accompany the indexed native payload. A retained subset of source evidence includes the original manifest and consumed artifacts plus parent provenance and its signature/public-key support files. Derived provenance inventories final saved paths, hashes, sizes, runtime, argv, options, status and elapsed time, retaining actual native indexing argv alongside replay commands referencing final files.

## Existing PrimalScheme frequency option

The pinned fork's `--min-base-freq` filters the frequency of each distinct candidate primer sequence independently. Display its existing value as **Minimum primer-variant frequency (%)**, converting percent to the native fraction and preserving the default zero. Record both the native resolved value and the visible percentage/semantics in provenance.

This is not a cumulative percentage of unmatched rows and does not constrain mismatches to the 5′ end. Counts describe alignment observations rather than read abundance or population allele frequency. The existing missing-ends policy excludes terminally uncovered observations from the candidate denominator. No new discovery algorithm or 5′-specific mismatch policy is introduced here. A requested quota would require an explicit separate policy; it must not be mislabeled as this native filter.

Primary source: [pinned fork candidate discovery](https://github.com/dhoconno/primalscheme3-lge/blob/v3.3.0-lge.1/primalscheme3/core/digestion.py).

## Verification

The focused Swift suite passed 91 tests with no failures on 2026-09-12. It covers menu selection behavior and availability, clipboard records and duplicate names, percentage conversion and invalid values, export source integrity and exclusive publication, reverse orientation, alternative membership, probe identity, native annotation offsets, viewer/routing/Inspector behavior and Operations integration already used by design workflows. Added commit tests cover cancellation before and after publication and a rejected project guard. Signed source evidence remains verifiable after the original analysis is removed.

Opt-in checks used retained human class I, human DP, macaque DQA1 and Primer3 MHC analyses to produce eight native derivatives. All eight passed `lungfish-cli bundle validate --check-integrity`; tests also rehashed final provenance descriptors, read native annotation databases, checked FASTA oligos and verified unchanged source manifests. A separate audit verified all 452 file descriptors in the workflow/native indexing steps. These checks ran no new primer-design engine and downloaded no scientific input. Offscreen AppKit renders covered the design dialog, Overview, Results, MSA binding and Inspector at existing wide/narrow sizes.

Local evidence: `.build/primer-context-tests.log`, `.build/primer-context-native-cli-validation.log`, `.build/primer-context-native-exports/`, and `.build/primer-context-visual/`. Portable Debug packaging is recorded separately in `build/primer-context-debug.log`.
