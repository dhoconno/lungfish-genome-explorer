# PrimalScheme Inspector display controls

## Scope and scientific contract

New graphical PrimalScheme runs use zero minimum primer-variant frequency. Existing saved analyses and explicit CLI controls remain reproducible. The final native output is the selected scheme; even zero-cutoff discovery is not an exhaustive superset of designs obtainable with other settings. Frequency, size, thermodynamic, interaction and pool-layout changes still require engine execution.

Use the existing Inspector View tab for reversible display controls over saved selected oligos: pools (scoped by result), forward/reverse strands, individual oligos, amplicon spans and matching-base dots. A separately labeled optional MSA compatibility filter uses the existing conservative positional comparison: zero-mismatch rows divided by fully assessable rows at the stored site. Report unknown/unassessable rows separately and retain them by default. This metric is neither the native sequence-frequency cutoff nor cumulative allele coverage.

Display settings are shared by this viewport and its Inspector, remembered per analysis in the current window. They never rewrite verified scientific bundles. Source membership, geometric coverage, full ordering CSV and existing associated-primer/whole-pool exports remain complete. Filter only rendering, not the source arrays used for membership or exports. The focused amplicon identifies hidden members; toggles never silently select a different scientific scheme.

## Implementation

1. Add shared display settings/session, scoped preference cache, and cancellable background compatibility summaries. Keep counts per primer, not a retained primers-by-rows matrix. Unavailable measurements never masquerade as zero.
2. Inject the same session into installed viewer and verified Inspector with existing installation/URL guards. Offer View only for parsed PrimalScheme outputs.
3. Implement Inspector toggles, counts, reset, compatibility status and explicit saved-run/design-setting distinction.
4. Apply visibility to Overview marks, Results rows, focused variant rows and Binding annotations/choices. Preserve full source records in all context actions and label saved coverage/full ordering scope. Update Binding annotation identity when filters change. Retain Binding capability even when all primers are hidden.
5. Remove graphical frequency input; record the resolved zero default and display-only review policy in provenance.
6. Verify scoped pool/primer identity, compatibility denominators and unknowns, cancellation/stale load, hide-all/reset, Inspector/viewer synchronization, unchanged source/export data and Primer3 behavior. Inspect offscreen native MHC renders and build portable Debug.

## Review

Bioinformatics review confirmed the saved-result versus redesign boundary and rejected using native `pc` values as frequencies without denominators. UI/architecture review selected the standard View tab, shared window state and rendering predicates to preserve source membership. Implementation proceeds under the user's standing authorization for autonomous work.

## Verification

The focused suite passed 91 tests with zero failures and zero skips, including retained human/macaque MHC analyses, optional offscreen renders and full-set export checks. The native macaque fixture exercised background compatibility calculation, invalidation of pending work, per-window preference restoration, hide-all/reset, preserved Binding capability and unchanged BED/CSV/provenance bytes. Synthetic tests cover unassessed denominators, scheme-scoped pool keys, reciprocal membership and Inspector bindings. New graphical requests keep frequency zero across customized settings, grouping and terminal-policy choices.

Review identified and corrected failure/retry disconnection and hidden-primer substitution. Explicit hidden-on-entry requests now preserve their saved identity and show an unavailable state, never another primer. Context-menu alignment actions include only displayed primer IDs while copy/export actions retain complete source membership. Final engineering and bioinformatics reviews found no remaining blockers. UI review inspected the 320-point Inspector and a native macaque Results/Inspector composition with active filters.

Development evidence: `.build/primer-inspector-final.log` and `.build/primer-inspector-visual/`. These diagnostics do not modify scientific bundles. Native calculations and ordering output were not regenerated for this presentation change.
