# Slice B CLI/App Boundary Implementation Note

Date: 2026-05-16
Branch: `codex/wave2-cli-app-boundary`
Base: `codex/wave2-integrated-fixes` at `8d44f77a`

## Scope

Move CLI-used, UI-free import and conversion code from `LungfishApp` into
`LungfishWorkflow` so `LungfishCLI` no longer depends on `LungfishApp`.

Owned moves:

- `Services/ApplicationExports/*` -> `Sources/LungfishWorkflow/ApplicationExports/`
- `Services/Geneious/*` -> `Sources/LungfishWorkflow/Geneious/`
- `Views/Metagenomics/CzIdImportPreview.swift`,
  `CzIdDataConverter.swift`, and `CzIdProjectImportWorkflow.swift` ->
  `Sources/LungfishWorkflow/Metagenomics/CzId/`
- `ReferenceBundleImportService` -> `Sources/LungfishWorkflow/Bundles/`

Follow-on dependency move:

- `ReferenceBundleAnnotationImportService` also moves to
  `Sources/LungfishWorkflow/Bundles/` because `GeneiousImportCollectionService`
  uses it as the default importer for decoded Geneious annotations. Leaving it
  in `LungfishApp` would either keep the CLI/App dependency or drop existing
  Geneious annotation import behavior.

## Approach

This is an ownership move, not a behavior rewrite. Public symbol names and
provenance-writing paths stay unchanged. CLI commands will switch from
`import LungfishApp` to `import LungfishWorkflow`, and `Package.swift` will
drop the `LungfishApp` dependency from `LungfishCLI`.

`ReferenceBundleImportService.shared` is currently `@MainActor`, but the
implementation is UI-free. The workflow-owned service can keep the singleton
for source compatibility while making it available to the CLI through
`LungfishWorkflow`.

## Verification Plan

Baseline tests were run before production moves:

- `swift test --filter ImportCzIdCommandTests`
- `swift test --filter CzIdDataConverterTests`
- `swift test --filter CzIdImportWorkflowTests`

Final verification will run the Slice B required commands:

- `rg -n '^import LungfishApp' Sources/LungfishCLI Tests/LungfishCLITests`
- `swift build --product lungfish-cli`
- `swift test --filter ImportCzIdCommandTests`
- `swift test --filter CzIdDataConverterTests`
- `swift test --filter CzIdImportWorkflowTests`
