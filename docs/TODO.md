# Deferred TODOs

This file tracks implementation work that was explicitly deferred so it can be
resumed later without re-discovering the context.

## 2026-04-17: Import Center dataset-level metadata import

- Status: Deferred and intentionally removed from Import Center for now.
- Why it was deferred:
  - The first Import Center metadata pass was not ready for general use.
  - The UI did not make the target dataset explicit enough.
  - The preview/matching experience was too weak for users to trust how CSV/TSV
    metadata would be applied to existing samples in a dataset.

### Current state

- The `Metadata` section is removed from Import Center.
- Dataset-level metadata import still exists in lower-level app code, but it is
  not exposed through Import Center until the workflow is complete enough for
  normal users.

### What the future implementation needs

1. Support both CSV and TSV metadata files.
2. Choose which dataset in the current project receives the metadata file.
3. Preview and matching UI:
   - Show the incoming columns before import.
   - Show how rows will match against the samples already present in the target
     dataset.
   - Make the match key explicit.
   - Give the user a way to resolve ambiguous or missing matches before commit.

### Likely code touchpoints

- `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift`
- `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift`
- `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/App/AppDelegate.swift`
- `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Sidebar/ProjectMetadataExportImport.swift`
- `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishIO/Bundles/VariantDatabase.swift`

### Resume notes

- The Import Center already moved to a welcome-screen-style sidebar layout.
- The abandoned metadata attempt used project-scoped dataset discovery for
  `.lungfishref` bundles with variant tracks. That discovery logic can be
  rebuilt, but the UI should not return until the target picker and preview
  workflow are both in place.
- If this returns to Import Center, add tests for:
  - visible dataset picker scoped to the current project
  - CSV and TSV acceptance
  - preview/match step before import commit
  - import routing to the selected dataset rather than the currently open viewer
    bundle
