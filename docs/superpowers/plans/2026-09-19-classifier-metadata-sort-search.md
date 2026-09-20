# Classifier Metadata Sort and Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Make EsViritu's displayed sample metadata sortable and searchable, including selectable metadata search fields.

**Architecture:** Keep metadata in `SampleMetadataStore`; resolve each row's sample through the same identity used to render cells. Handle dynamic metadata keys before built-in sorting. Extend the existing native search field with a native scope menu populated from actual displayed columns, while preserving existing free-text and column-filter behavior.

**Tech Stack:** Swift, AppKit, XCTest, LungfishKit, LungfishEsVirituUI.

**Spec:** User's issue 3: metadata imported into EsViritu displays but ascending/descending sort fails and search field choices omit displayed metadata. This plan records the investigated behavior and narrow intended design.

## Global Constraints

- Astra performs analysis/planning; implementation uses a lesser model; all Swift compilation, builds, and test execution go to Sol Medium.
- Do not modify `/Volumes/iWES_WNPRC/32615/32615.lungfish` during automated verification. Use in-memory or temporary synthetic fixtures.
- Preserve existing edits and unrelated plans. No schema migrations, imports, scientific file rewrites, or provenance changes are needed for these presentation fixes.
- Every new scientific import/transform/export workflow must carry full existing provenance requirements; do not change such workflows in this task.

## Evidence and Root Causes

Read-only inspection of the reported analysis found both `metadata/sample_metadata.csv` and `metadata/sample_metadata.tsv`, each with 57 records and 30 headers. These include `collection_date`, `sampling_location_abbrev`, `sampling_location_full`, `host`, and `pool_name`. Dates and locations vary; equal metadata values cannot explain all reported sort failures. SQLite was opened read-only/immutable to inspect table names only.

1. `Sources/LungfishKit/MetadataColumnController.swift:285-300` installs `metadata_<exact header>` columns with working `NSSortDescriptor` prototypes. The header action itself has a key.
2. `Sources/LungfishEsVirituUI/ViralDetectionTableView.swift:747-807` handles only built-in keys in `sortItems`. A metadata key reaches `default`, which unconditionally sorts by reads descending, ignoring both metadata and requested direction.
3. `Sources/LungfishKit/BatchTableView.swift:607-612,789-799` sends every sort key directly to a subclass comparator. `BatchEsVirituTableView.compareRows` handles built-in keys only and returns false for metadata. Both filter-time re-sorting and header sorting require correction.
4. `ViralDetectionTableView.applyFilter`, lines 680-705, searches sample/name/taxonomy/assembly/contig text but never sample metadata. `BatchEsVirituTableView.rowMatchesFilter`, lines 84-87, searches only virus name and family.
5. Neither EsViritu view has a field-choice interface today: they instantiate ordinary `NSSearchField`s without a search scope menu. Repository-wide search found no `SearchBarView` type. Therefore omission from an existing EsViritu field picker cannot be reproduced from this source; adding metadata scopes to the existing native field is the narrow way to satisfy the requested interface. Do not change sidebar universal search or variant query builders.
6. Metadata header column filters already work through `assemblyMatchesColumnFilter` and `BatchTableView.columnFilterValue`. Reuse their identity convention and keep those filters conjunctive with free-text/scope search.

## Review Focus

- Equal and missing metadata values must not violate strict sort ordering or arbitrarily scramble selected rows.
- Numeric-looking values (2, 10, 100) and ISO date text should order usefully; mixed columns must use one consistent ordering.
- Metadata headers containing spaces, underscores, or built-in names must retain exact independent identifiers.
- Importing/replacing metadata or hiding the selected search field must refresh search scope without a stale invisible restriction.
- Duplicate assembly names across samples must search/sort on the correct sample and preserve identity selection.

## Task 1: Sort Metadata Through the Existing Row Pipeline

**Modify:**
- `Sources/LungfishKit/MetadataColumnController.swift`: shared value/comparison helpers.
- `Sources/LungfishKit/BatchTableView.swift`: internal comparator used at both sorting sites.
- `Sources/LungfishEsVirituUI/ViralDetectionTableView.swift`: metadata branch in `sortItems`.

**Tests:** `Tests/LungfishKitTests/BatchTableViewTests.swift`, new `Tests/LungfishEsVirituUITests/EsVirituMetadataSortSearchTests.swift`.

- [ ] Add synthetic records with samples A/B/C/D, `Group` values Zebra/alpha/alpha/missing and `Count` values 10/2/100/missing. Keep fixture baseline order known and different from read-count order. Use the existing `TestBatchTableView` fixture and existing EsViritu smoke-test `ViralAssembly` construction patterns; never import the external example.
- [ ] Drive actual descriptors through `tableView.sortDescriptors = [NSSortDescriptor(key: "metadata_Group", ascending: true)]` and the outline equivalent. Assert A/B/C identities by displayed rows, both directions, equality stability, missing placement, and that changing a text filter retains metadata ordering. Have Sol Medium run the focused command below; capture the failing expectations before implementation.
- [ ] Add public main-actor helpers on `MetadataColumnController`:

```swift
public func value(columnID: String, sampleID: String?) -> String?
public func comparison(columnID: String, lhsSampleID: String?, rhsSampleID: String?) -> ComparisonResult?
```

`nil` comparison means a nonmetadata key; `.orderedSame` means equal values. Decode only the literal `metadata_` prefix. Resolve the exact store header and use `sampleID ?? currentSampleId`, matching cell rendering. Use Foundation text comparison with `[.caseInsensitive, .numeric]` to keep mixed strings a consistent total ordering and natural number/date text useful. Treat missing as empty, so it comes first ascending and last descending. Do not invent pairwise Double parsing that can make mixed-value ordering nontransitive.

- [ ] Add one internal `BatchTableView` comparator that consults this helper first and otherwise calls the existing overridable `compareRows`. Replace both existing sort closures with it. Do not require every subclass to learn metadata keys.
- [ ] In `ViralDetectionTableView.sortItems`, branch on metadata keys before the built-in switch, compare via the helper with `sampleID(for: assembly)`, and use `currentSortAscending ? comparison == .orderedAscending : comparison == .orderedDescending`. Preserve existing selection restoration and hierarchy. Do not reverse `!lessThan` for descending; ties must return false.
- [ ] Sol Medium reruns focused tests. Include a duplicate assembly name in two different samples and select one before sort; selection must remain attached to that sample's identity. Keep unrelated built-in comparator cleanup outside this task.

## Task 2: Add Displayed Metadata to Search Values and Scope Choices

**Modify:** `MetadataColumnController.swift`, `BatchTableView.swift`, `ViralDetectionTableView.swift`.

**Tests:** same files as Task 1, plus `Tests/LungfishKitTests/MetadataColumnPersistenceTests.swift` only if visibility callback coverage belongs there.

**Interfaces:**
- `MetadataColumnController` exposes `public var onColumnsOrStoreChanged: (() -> Void)?` and `public var displayedMetadataColumns: [(id: String, title: String)]`.
- Each table keeps `private var selectedMetadataSearchColumnID: String?`; nil means existing all-fields search plus displayed metadata.
- Each table implements `rebuildSearchScopeMenu()` and an Objective-C menu action using `representedObject` for the exact metadata identifier.

- [ ] Add regression tests exercising native `searchField.searchMenuTemplate` items: after metadata becomes visible the menu must contain that header and its exact ID; after hiding/removing it the choice disappears. Include headers `Collection Date`, `sample`, and `lab_name`. Verify no duplicate scope entries after repeated store updates.
- [ ] Add filtering tests with a metadata-only query (e.g. `NorthCampus` absent from virus/sample text). All-fields search must find the associated sample; selecting a specific metadata field must limit matching to that field, while the default scope continues matching built-in virus names. Verify both outline and batch paths and conjunctive existing `ColumnFilter` behavior.
- [ ] Implement `displayedMetadataColumns` from the installed table's actual columns, filtering `metadata_` identifiers and `!isHidden`, in display order. This avoids stale `visibleColumns` assumptions after zero-width hiding, persistence restore, and column changes.
- [ ] Emit `onColumnsOrStoreChanged` after store update/column refresh and after visibility or layout-restoration changes have completed; keep callbacks outside an active visibility mutation to avoid recursion. The owning table rebuilds its search menu and reapplies the current filter/sort. Prevent redundant callbacks within nested refresh operations. Do not call the callback from a cell render.
- [ ] Build `NSSearchField.searchMenuTemplate` with `All Fields` and displayed metadata fields. This uses the existing AppKit search button rather than adding a new layout row or query language. Menu actions update the chosen identifier/checkmark and reapply existing filter pipeline. If selected field disappears, reset to All Fields immediately and reapply. Preserve query text and debounce behavior.
- [ ] In All Fields mode, preserve each view's existing built-in predicate and OR it with case-insensitive substring matching of displayed metadata values resolved by sample. In a selected metadata scope evaluate only that metadata value. Empty query passes all rows. Keep existing per-column filters as a separate AND stage. Do not match another sample's metadata or the metadata header itself as a value.
- [ ] Wire callbacks after the search field/table exist and before metadata is loaded. Check `EsVirituResultViewController.sampleMetadataStore` and `applyBatchSampleFilter` flows: they already call `metadataColumns.update`, so they should require no extra import hooks.
- [ ] Sol Medium runs focused tests, including changing metadata with an active search and metadata sort, selected-field removal, scope selection with an existing query, duplicate samples/assemblies, and nil metadata store. Verify existing `BatchTableViewTests` debounce and identity-selection tests continue passing.

## Verification Commands and Manual Acceptance

Only Sol Medium runs compilation/test commands:

```sh
swift test --filter 'BatchTableViewTests|EsVirituMetadataSortSearchTests|MetadataColumnPersistenceTests|EsVirituResultViewControllerSmokeTests'
```

The implementer should ask the designated build agent to execute this once for the failing regressions and once after implementation; do not start concurrent SwiftPM builds. Any compile failures are repaired by the implementer, then retried by Sol Medium.

Manual acceptance after an already-authorized application build: open a synthetic multi-sample EsViritu result, display collection date and location metadata, sort both directions via the header menu, type a metadata-only location query, select a metadata search scope, and hide that field. Verify correct rows, unchanged selection identity where still visible, and reset to All Fields after hiding. The external example can be inspected visually only without importing/editing/exporting it.

## Planning Verification

This investigation performed read-only source inspection, directory listing, metadata header/row-count inspection, and read-only SQLite schema inspection. It did not reproduce through a running GUI, compile, run Swift tests, or modify user scientific data. The observed source paths deterministically account for metadata sort failures and metadata text search omissions; native scope UI is the proposed small enhancement required by the user request.
