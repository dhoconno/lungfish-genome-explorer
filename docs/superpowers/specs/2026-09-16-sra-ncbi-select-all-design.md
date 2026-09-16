# SRA and NCBI Search Result Selection Design

## Goal

Add a reversible bulk-selection control to the shared online database search
results UI so users can select all currently visible/filtered SRA or NCBI
records for downloading and undo an unintended selection.

## Behavior

- The shared Results header displays `Select all` when visible/filtered results
  exist and no records are currently selected.
- `Select all` adds every record in `filteredResults` to the existing
  `selectedRecords` set. It does not select records excluded by the current
  local text or advanced result filters.
- Once one or more records are selected, the control displays `Deselect all`.
- `Deselect all` clears the entire `selectedRecords` set, including records
  hidden by the current result filter. It also clears the legacy
  `selectedRecord` compatibility property.
- `Deselect all` remains available when a filter hides every selected record,
  because the control is driven by selection state rather than only by visible
  rows.
- The control is unavailable while a search or download is in progress. It is
  absent when there are neither visible results nor selected records.
- Existing `Download Selected` behavior is unchanged and consumes the updated
  `selectedRecords` set for both SRA and NCBI results.

## Implementation

`DatabaseBrowserPane` owns the shared Results header for all database sources.
It will expose the toggle there with a stable accessibility identifier. The
selection mutations will live on `DatabaseBrowserViewModel` so the behavior is
testable without rendering SwiftUI:

- `selectAllVisibleResults()` inserts `filteredResults` and synchronizes
  `selectedRecord`.
- `deselectAllResults()` clears both selection properties.
- A computed presentation state chooses the button title and availability.

No changes are needed to the SRA or NCBI search services, pagination, or batch
download implementation.

## Verification

- Add focused view-model tests proving that select-all respects local filters,
  that repeated selection is idempotent, and that deselect-all clears selected
  records that are both visible and hidden by the current filter.
- Add a deterministic UI test that searches the NCBI scenario, selects all,
  verifies the selection count and `Download Selected` action, then deselects
  all and verifies the selection is cleared.
- Run the focused app tests and the supported Debug coordinator. Install the
  verified `Lungfish Debug.app` in `/Applications` without removing unrelated
  applications or user data.
