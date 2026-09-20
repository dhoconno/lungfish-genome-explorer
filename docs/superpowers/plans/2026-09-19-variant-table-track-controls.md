# Variant Table and Track Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every variant Calls column supports useful sorting/filtering, and Inspector → View enumerates variant tracks with persistent checkboxes that hide/show their Calls rows, genotype rows, and viewport content together.

**Architecture:** Extend existing column menus/value extraction and reuse the table sort comparator after filtering. Represent visibility as bundle-owned hidden track IDs, distribute it through the existing window-scoped Inspector/controller route, and intersect it with existing drawer/render filters. Filter query database handles before row limits, while retaining the full track inventory for checkbox recovery.

**Tech Stack:** Swift, AppKit NSTableView/NSMenu, SwiftUI Inspector, XCTest, existing SQLite VariantDatabase and Codable BundleViewState.

**Spec:** User issue 2 in the current task: all relevant variant fields sortable/filterable including Variant Track; enumerate entire tracks with show/hide checkboxes in Inspector View. Parent clarification: hiding applies to viewport, genotypes, and table together. This plan records that bounded design; no separate design file was supplied.

## Global Constraints

- Astra analysis/planning only; implement with a lesser model; delegate all compilation/test execution to Sol Medium as explicitly requested by the user.
- Do not alter user scientific datasets or provenance. These are presentation changes; temporary test fixtures only. Any added scientific export/import behavior would require the full AGENTS.md provenance contract and is outside scope.
- Track identity is track ID, never track name, row ID alone, or list position. Two tracks may have the same name and overlapping row IDs.
- No process-wide UserDefaults visibility state. Keep live state isolated by window and bundle; persist in existing bundle view-state sidecar.
- Preserve unknown-column sizing menus and existing Genotypes/sample/annotation menus. Coordinate dynamic INFO discovery with the separate iVar work: this plan owns actions/evaluation, not INFO discovery or parsing.

## Confirmed Causes and Existing Behavior

- `AnnotationTableDrawerView.swift:2718` omits `track_name`, `caller_settings`, and `coding_feature` in `variantFilterKey`; `variantColumnValue` omits the same fields. The early guard in `buildVariantColumnHeaderContextMenu` prevents even sizing items for these columns.
- `+Columns.swift:312` defines all 15 Calls fixed columns with sort keys, and `+TableView.swift:256` already sorts them on header click. This is not missing basic click sorting. Explicit ascending/descending context-menu actions are missing.
- `setVariantBaseResults` and `applyVariantColumnFiltersFromBase` replace displayed rows without reapplying the active sort. A header can continue to indicate sorting after a query/filter rebuild returned database order.
- `AnnotationSectionViewModel` has variant type visibility and text, but no track inventory/visibility. Its variant notification is currently global, unlike annotation callbacks wired by `InspectorViewController` through `windowScopedUserInfo`.
- `SequenceViewerView.filteredVisibleVariantAnnotations` combines type/text and table render keys. `filteredVisibleGenotypeData` currently returns the complete genotype cache when local keys are nil. Track filtering must work on both paths independently of table-open state.
- Annotation track display controls are a useful identity/UI precedent (`AnnotationTrackDisplayState`, drawer `setAnnotationTrackVisible`, renderer/tooltips), but currently affect viewport only and are not an adequate complete implementation for this request.
- Query context is assembled in `+Filtering.swift:587` from all `index.variantDatabaseHandles`. Filtering rows only after that point can let hidden tracks consume row caps.
- `BundleViewState` has no track visibility field. Bundle restore/save/reset and Inspector synchronization live in `ViewerViewController+BundleDisplay.swift`; initial type discovery also occurs in `MainWindowController.swift:346`.

## Review Focus

1. Duplicate track names/overlapping row IDs: only the selected track disappears, including genotype rendering (Tasks 2–3).
2. All tracks hidden: empty tables/viewer remain empty after async refresh; controls still list every track (Tasks 2–3).
3. New/removed tracks and legacy saved state: new tracks default visible, stale hidden IDs disappear, old JSON still loads (Task 2).
4. Two windows/bundle switches during async work: no state leakage and no stale result resurrects tracks (Task 3).
5. Null numeric INFO values and filter rebuilds: missing comparisons do not masquerade as numeric matches; sort order remains consistent (Task 1).

### Task 1: Complete column controls and retain sorting

**Files:**
- Modify `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift` (key mapping, menu, values, result application).
- Modify `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+TableView.swift` (extract reusable Calls sorting from existing comparator).
- Read `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+Columns.swift` and `+Genotypes.swift` (existing sort menu pattern).
- Extend `Tests/LungfishAppTests/AnnotationTableDrawerVariantTests.swift` and `AnnotationTableContextMenuTests.swift`.

**Interfaces:** Keep `variantColumnValue(_:key:) -> String` and `applyVariantColumnFilters(to:)`. Introduce `sortDisplayedVariantCallsIfNeeded()` using `tableView.sortDescriptors.first` and the existing Calls comparator; invoke only when `.variants` / `.calls`. Menu action `sortVariantColumnAscending(_:)` / `sortVariantColumnDescending(_:)` receives column identifier and assigns the column's sort descriptor prototype with the requested direction.

- [ ] Add behavioral tests iterating `variantColumnDefs`: assert each identifier maps to its declared key; build its header menu and assert ascending, descending, and suitable text/numeric filters exist. Repeat for a manually configured numeric `info_` column. Exercise actual menu actions rather than checking source text.

```swift
for (identifier, _, _, _, key) in AnnotationTableDrawerView.variantColumnDefs {
    XCTAssertEqual(drawer.variantFilterKey(forColumnIdentifier: identifier.rawValue), key)
}
XCTAssertEqual(drawer.variantColumnValue(row, key: "track_name"), "Caller A")
drawer.variantColumnFilterClauses = [.init(key: "track_name", op: "=", value: "Caller A")]
XCTAssertEqual(drawer.applyVariantColumnFilters(to: [row, other]).map(\.trackId), [row.trackId])
```

Use existing SearchResult fixtures; supply explicit different track IDs and names, caller settings via the test search index, and coding feature qualifiers already supported by `variantCodingFeatureText`.

- [ ] Have Sol Medium run the targeted classes and retain failure evidence before edits.
- [ ] Resolve keys from `variantColumnDefs` rather than adding another incomplete switch; keep `info_` support. Put sizing entries before the key guard. Add two sort items patterned on existing Genotypes actions. Keep all existing numeric/text predicates and add Is Empty/Is Not Empty and Clear Variant Column Filters entries for parity with annotation menus.

```swift
if let definition = Self.variantColumnDefs.first(where: { $0.0.rawValue == columnId }) {
    return definition.4
}
return columnId.hasPrefix("info_") ? columnId : nil
```

Add value cases with the same rendered semantics:

```swift
case "track_name":
    return row.trackName ?? searchIndex?.variantTrackName(for: row.trackId) ?? row.trackId
case "caller_settings":
    return searchIndex?.variantCallerSettings(for: row.trackId) ?? "Not recorded"
case "coding_feature":
    return variantCodingFeatureText(for: row)
```

- [ ] Extract and reuse the existing Calls comparator on header actions, base query completion, and local filter apply/clear, before reload/genotype rebuilding/count updates. Preserve existing sample and annotation sort behavior. Use displayed value resolution for track name so sort and filter match. Add deterministic tie-breaking by track ID, variant row ID, chromosome/start/name without changing primary sort direction semantics.
- [ ] For known numeric INFO keys use numeric equality as well as inequalities; malformed/missing numeric values fail nonempty numeric comparisons rather than falling through to lexical ordering. Empty/nonempty operations must still work. Preserve string equality for nonnumeric INFO such as flags or comma-separated values; do not invent aggregation semantics.
- [ ] Test numeric `2` versus `10`, numeric equality `2.0` versus `2`, missing/invalid numeric values, string INFO, ascending/descending track names, and sort retention through `setVariantBaseResults` and clearing filters. Run both targeted classes via Sol Medium. Commit only this task's files.

### Task 2: Define persistent Inspector track visibility

**Files:**
- Modify `Sources/LungfishCore/Bundles/BundleViewState.swift` and `Tests/LungfishCoreTests/BundleViewStateTests.swift`.
- Modify `Sources/LungfishApp/Views/Inspector/Sections/AnnotationSection.swift`.
- Modify `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`.
- Modify `Sources/LungfishCore/Models/Notifications.swift` (hidden track key).
- Create `Tests/LungfishAppTests/VariantTrackVisibilityTests.swift`.
- Extend `Tests/LungfishAppTests/InspectorNotificationScopingTests.swift`.

**Interfaces:** Add `BundleViewState.hiddenVariantTrackIDs: Set<String>` default `[]`, initializer default, explicit CodingKeys/decodeIfPresent fallback/encoding as appropriate to current custom Codable. Add `VariantTrackVisibilityItem: Identifiable, Equatable` with `id: String`, `name: String`. Add VM properties `availableVariantTracks`, `hiddenVariantTrackIDs`, callback `onVariantFilterChanged: (() -> Void)?`, methods `setAvailableVariantTracks(_ tracks: [VariantTrackVisibilityItem])` and `setVariantTrackVisible(trackID: String, visible: Bool)`.

- [ ] Add fixture tests for legacy JSON lacking the key, roundtrip a nonempty hidden set, all IDs hidden, default reset, reconciliation with removed IDs, and addition of a new visible track. Example state invariant:

```swift
vm.availableVariantTracks = [.init(id: "a", name: "Caller"), .init(id: "b", name: "Caller")]
vm.setVariantTrackVisible(trackID: "a", visible: false)
XCTAssertEqual(vm.hiddenVariantTrackIDs, ["a"])
vm.setAvailableVariantTracks([.init(id: "a", name: "Caller"), .init(id: "c", name: "New")])
XCTAssertEqual(vm.hiddenVariantTrackIDs, ["a"])
```

- [ ] Sol Medium executes failures. Implement hidden-set reconciliation as intersection with full current track inventory. Never infer initialization from an empty visible set. Preserve hidden choices on same-bundle inventory refresh; bundle replacement installs the saved set explicitly, and no-bundle reset empties inventory and hidden IDs.
- [ ] Add a Variant Tracks checkbox group inside existing variant controls in AnnotationSection (already placed in Inspector View). `ForEach` keyed by ID; binding reads `!hiddenVariantTrackIDs.contains(track.id)` and calls the visibility method. Duplicate names receive a secondary ID label/help. Keep full inventory displayed even when all are hidden; preserve choices when Show Variants globally disables display. Optional All/None buttons use the same notification once per action.
- [ ] Wire `onVariantFilterChanged` in `setupViewModelCallbacks` to a controller helper that posts the complete existing variant payload plus hidden IDs through `windowScopedUserInfo`. VM uses callback when attached, existing fallback only when unattached. Add scoped notification tests proving another window rejects the event and the owning window receives IDs. Do not create another global observer path.
- [ ] Reset hidden IDs to `[]` in VM reset and persist state using existing save mechanism in Task 3. Sol Medium runs targeted state/Inspector tests; commit task files.

### Task 3: Apply visibility across query, viewer, genotype, and bundle lifecycle

**Files:**
- Modify `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`.
- Modify `Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift` and `ViewerViewController+AnnotationDrawer.swift`.
- Modify `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift` and `+Filtering.swift`.
- Modify `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`.
- Inspect/wire `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift` alongside existing type discovery.
- Extend `Tests/LungfishAppTests/VariantTrackVisibilityTests.swift`, `VariantGenotypeTrackIdentityTests.swift`, `AnnotationTableDrawerVariantTests.swift`.

**Interfaces:** Viewer and drawer each expose `setHiddenVariantTrackIDs(_ ids: Set<String>)`. Controller owns propagation using the current bundle inventory. Drawer stores its hidden set and query cache key includes sorted hidden IDs (or setter reliably invalidates every query cache). Full track inventory comes from bundle variant track metadata/index handles, never currently displayed rows.

- [ ] Write tests with two temporary track databases, same display name and same row IDs: hiding one removes its Calls and Genotypes rows and renderer sites only. All-hidden must return zero rows. A visible track whose matches follow a large hidden track still appears under existing query caps. A pending query started before a toggle must not restore hidden results.
- [ ] Sol Medium runs the targeted tests to establish failures.
- [ ] In controller variant-notification handling, intersect received hidden IDs with the current bundle's known IDs, update viewer and drawer, save view state. Use the existing `shouldAcceptScopedNotification` gate. Install bundle-restored hidden IDs before first drawer query; save them in view state and reset them in every viewer clear/nonbundle/reset path.
- [ ] Populate Inspector inventory from the full loaded bundle/index metadata and saved hidden set during bundle Inspector sync; add a current bundle URL/identity guard to deferred sync so stale captured state cannot overwrite a newly selected bundle. Refresh inventory after same-bundle variant import/removal through existing reload lifecycle. Preserve choices through refresh; newly imported track IDs are visible.
- [ ] Drawer setter cancels/invalidates old query generation, clears query cache, immediately filters current base rows, triggers fresh query when appropriate. `applyVariantColumnFilters(to:)` always excludes hidden track IDs even when column clauses are empty. Build `AnnotationVariantQueryContext.databases` from handles excluding hidden IDs; include visibility in query cache identity. Keep track inventory and dynamic INFO discovery based on all loaded tracks, so hidden tracks remain recoverable. Do not reinterpret an empty database list as all databases.

```swift
let visibleHandles = index.variantDatabaseHandles.filter {
    !hiddenVariantTrackIDs.contains($0.trackId)
}
// Supply visibleHandles to AnnotationVariantQueryContext before limits/counts.
```

- [ ] Apply hidden IDs in `filteredVisibleVariantAnnotations` using `variant_track_id`, before other filters. Apply independently in `filteredVisibleGenotypeData` using `sourceTrackId`, including the `localVariantRenderFilterKeys == nil` case. Unknown/untracked legacy items remain visible; never hide by name. Setter invalidates `_cachedFilteredGenotypeData`, filtered variant cache, annotation tile and layout/redraw. Continue to intersect with table keys, preserving nil (unrestricted) versus empty (nothing) semantics. Existing tooltip path consumes filtered annotations; verify it does not offer hidden-track hits.
- [ ] Ensure genotype drawer rebuild uses newly filtered Calls base results and does not reintroduce hidden tracks from cached genotypes. On showing a track, requery/refetch through existing paths so a cache previously scoped to hidden selection does not prevent recovery.
- [ ] Add tests: renderer with no table keys; renderer with intersecting table keys; all tracks hidden then show one; refresh preserving hide-all; duplicate names; two-window event isolation; bundle switch/restoration; blank legacy view state. Sol Medium runs all five affected test classes plus BundleViewStateTests and InspectorNotificationScopingTests with the repository's test runner/environment. Suggested direct targeted command if permitted by root guidance:

```sh
swift test --filter 'AnnotationTableDrawerVariantTests|AnnotationTableContextMenuTests|VariantTrackVisibilityTests|VariantGenotypeTrackIdentityTests|BundleViewStateTests|InspectorNotificationScopingTests'
```

- [ ] Manual GUI acceptance on temporary copied/test data: right-click Variant Track, Caller Settings, Gene / Protein and numeric INFO; sort/filter each; verify sort survives filter clear and viewport refresh. In Inspector View hide one of two tracks and verify Calls, Genotypes, glyphs, tooltips; hide all and restore; close/reopen bundle; compare another window. Report actual checks, never claim GUI verification from source tests. Commit only task files.

## Handoff and Scope Boundaries

No compilation or implementation was performed while writing this plan. Shared-file edits with iVar INFO discovery need sequential integration: preserve its column-discovery/type metadata changes in `+Columns.swift` and any `isNumericInfoKey` improvements; merge this plan's menu/matching behavior afterward. Do not expand into generic table-schema frameworks, persisted sort profiles, new scientific exports, or variant caller changes. Use existing query generations, bundle sidecar persistence, and notification scope helpers.

Coordination received from iVar analyst: `VariantFormatOverlaySnapshot` on AnnotationSearchIndex provides `projectedInfo(trackID:record:existing:)` and `projectedKeysByTrack`. Its plan owns projected-field query paging/filtering/sorting before limits. For those fields, menu sort changes must trigger that query route; this plan's `sortDisplayedVariantCallsIfNeeded()` only preserves the final local order and must not be advertised as a global sort of truncated results. Filter visible database handles first, then let the iVar query stage overlay/filter/sort before its limit. Integrate the shared query-context initializer sequentially. If whole-result sorting remains unsupported for ordinary columns on capped tables, retain existing scope and make scope explicit rather than silently broadening expensive query behavior.
