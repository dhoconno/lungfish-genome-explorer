# Application Export CLI-Backed Imports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Geneious and Application Export Import Center operations execute through `lungfish-cli`, stream progress to Operation Center, and pass end-to-end tests with representative datasets for every supported card.

**Architecture:** Add `lungfish import geneious` and `lungfish import application-export` subcommands that wrap the existing import services and emit JSON progress events for GUI consumption. Add an app-side runner that launches the CLI, parses those events, updates Operation Center, and refreshes/selects the resulting collection. Representative fixture datasets cover each supported card, with CLI end-to-end tests verifying collections, inventories, reports, provenance, native reference bundle output, preserved artifacts, and warnings.

**Tech Stack:** Swift Package Manager, Swift ArgumentParser, XCTest, existing `OperationCenter`, `LungfishCLIRunner`, `ApplicationExportImportCollectionService`, and `GeneiousImportCollectionService`.

---

### Task 1: Failing Tests for CLI Commands and Events

**Files:**
- Modify: `Tests/LungfishCLITests/ApplicationExportImportCommandTests.swift`
- Modify: `Tests/LungfishAppTests/CLIApplicationExportImportRunnerTests.swift`

- [ ] Add CLI parsing and event tests requiring `application-export` and `geneious` import commands.
- [ ] Add runner tests requiring arguments and JSON event parsing for progress/completion/warning state.
- [ ] Run the new tests and confirm they fail because the command/runner does not exist.

### Task 2: CLI Subcommands

**Files:**
- Modify: `Sources/LungfishCLI/Commands/ImportCommand.swift`
- Create: `Sources/LungfishCLI/Commands/ApplicationExportImportSubcommands.swift`
- Modify: `Package.swift`

- [ ] Add `geneious` and `application-export` subcommands to `ImportCommand`.
- [ ] Accept source path, `--project`, optional `--collection-name`, preservation toggles, and `--format json`.
- [ ] Emit JSON lines for `applicationExportImportStart`, `applicationExportProgress`, `applicationExportWarning`, `applicationExportImportComplete`, and `applicationExportImportFailed`.
- [ ] Use the existing import services with an injected reference importer so the CLI path produces native `.lungfishref` bundles and provenance.

### Task 3: GUI CLI Runner and Operation Center Progress

**Files:**
- Create: `Sources/LungfishApp/Services/CLIApplicationExportImportRunner.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`

- [ ] Add CLI argument builders for Geneious and generic Application Export imports.
- [ ] Stream stdout JSON lines from `lungfish-cli`, update Operation Center progress/details/logs, and return the created collection URL.
- [ ] Replace direct service calls in `importGeneiousExportFromURL` and `importApplicationExportFromURL` with the CLI runner.

### Task 4: Representative E2E Fixtures

**Files:**
- Create fixture folders under `Tests/Fixtures/application-exports/`
- Modify: `Tests/LungfishIntegrationTests/ApplicationExportImportE2ETests.swift`

- [ ] Add one small representative source dataset for Geneious and every `ApplicationExportKind`.
- [ ] Include at least one standalone FASTA reference, one recognized-but-preserved artifact, and one program-native or report file per dataset.
- [ ] Verify each CLI import creates a collection, inventory, report, provenance, native reference bundle, preserved artifact, and Operation Center-compatible JSON event sequence.

### Task 5: Verification and Commits

**Files:**
- All changed files.

- [ ] Run focused tests for CLI command parsing, app runner parsing, service tests, import center menu tests, and application export E2E tests.
- [ ] Run `swift test --skip-build`.
- [ ] Commit the plan, tests, implementation, and fixtures in logical commits.
