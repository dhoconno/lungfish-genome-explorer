# Variant Row Selection Implementation Plan

**Goal:** Selecting Calls or Genotypes rows highlights them without moving/reloading the viewport; double-click remains explicit navigation.

**Diagnosis (Astra):** `AnnotationTableDrawerView+TableView.swift.tableViewSelectionDidChange` sends `didSelectAnnotation` for a single variant selection. `ViewerViewController+AnnotationDrawer.swift` handles that delegate by centering a 3000 bp region and scheduling a 120 ms recenter check. Region-follow then requeries/reloads the drawer. The same delegate is already called by `tableViewDoubleClicked`. This conflates selection with activation and interrupts multi-selection. No scientific data/provenance changes are needed.

**Scope:** Preserve the prior session's uncommitted fixes. Change only variant selection behavior. Annotation tab retains its existing selection navigation; Samples retains no navigation. Do not redesign queries, sorting or view-state persistence.

## Implementation

- [ ] Add behavioral tests with a recording drawer delegate. Configure variant Calls rows, including two tracks sharing row IDs. Select one row then extend selection to two: delegate navigation count stays zero; native selectedRowIndexes preserves selections. Repeat Genotypes single selection. Verify annotation selection still calls its delegate and Samples does not.
- [ ] Sol Medium runs these new tests before production edit and records failure evidence.
- [ ] In `tableViewSelectionDidChange`, keep suppression guard and restrict navigation to `.annotations`. Remove now-unreachable genotype navigation branch. Native NSTableView selection remains untouched. Update misleading double-click comment (Genotypes DOES navigate).
- [ ] Preserve explicit double-click navigation. Test via a minimal internal row-activation helper used by the actual double-click action if clickedRow cannot be driven reliably; validate bounds and full track+row identity for Genotypes. Do not change single-click annotation navigation or navigation delegate.
- [ ] Add regression coverage that applying variant local filters/sorting with a single selected row never emits a navigation callback. Avoid adding identity-preservation framework unless actual test evidence requires it for this bug.
- [ ] Sol Medium runs focused new tests plus AnnotationTableDrawerVariantTests, AnnotationTableContextMenuTests, VariantTrackVisibilityTests, VariantGenotypeTrackIdentityTests using Xcode27/Swift6.4 `--build-system swiftbuild` and existing test linker options. Root reviews diff.
- [ ] Sol Medium runs `python3 scripts/release/release.py debug`, verifies exact app version/path/signature and reports build logs. Do not launch or overwrite a running user app, mutate example data, publish or commit.

**Acceptance:** Single and multi-selection stay highlighted without viewport navigation/reload; double-click still navigates to the correct selected variant track. Existing focused tests stay green; new Debug app ready for local testing.

## Integration refinement

The existing navigation delegate also updates selectedAnnotation and posts the scoped variantSelected Inspector event. Preserve these on single selection by adding default no-op delegate `annotationDrawer(_:didHighlightVariant:)`. Calls/Genotypes single selection invokes highlight, not navigation. Viewer routes both delegates through one helper with navigate Bool: only true clears fetch errors, recenters/delays navigation, or zooms mapping; both update selection/Inspector/redraw. Tests assert zero navigation callbacks plus appropriate highlight callback. Multi-selection remains native table selection (no forced navigation). This avoids regressing Inspector details while removing bounce.
