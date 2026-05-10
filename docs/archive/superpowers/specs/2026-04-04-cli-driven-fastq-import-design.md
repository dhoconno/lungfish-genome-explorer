# CLI-Driven FASTQ Import with Import Center Tab

**Date**: 2026-04-04
**Branch**: `fastq-vsp2-optimization`
**Status**: Design

## Goal

Replace the GUI's direct FASTQBatchImporter call with a CLI subprocess approach: the GUI spawns `lungfish-cli import fastq` and reads structured JSON log events for Operations Panel display. Add a "Sequencing Reads" tab to the Import Center for file/folder/hierarchy selection with recipe configuration.

## Invariant: All Temp Files in Project `.tmp/`

All intermediate and temporary files produced during FASTQ import MUST be written to `<project>.lungfish/.tmp/` via `ProjectTempDirectory.create(prefix:in:)`. This applies to:

- The CLI's `FASTQBatchImporter` workspace (recipe step outputs, format conversions, compressed intermediates)
- Any decompression, interleaving, or concatenation buffers
- Fused fastp output, deacon output, seqkit output between steps

No temp files may be written to the system `/tmp/`, the input volume, or any location outside the project's `.tmp/` directory. The project directory is always on the user's chosen storage (typically local SSD), ensuring fast I/O regardless of where the input FASTQ files reside (network drives, external USB, etc.).

The `.tmp/` directory is cleaned up automatically via `defer` blocks after each sample completes or fails. `ProjectTempDirectory.cleanStale(in:olderThan:)` can reclaim orphaned temp files from crashed imports.

## Non-Goals

- Redesigning the Operations Panel UI
- Adding new recipe types (only VSP2 exists in new format)
- Modifying the CLI's import logic (only adding recursive directory support and `--recursive` flag)

## Architecture

```
User selects files/folder in Import Center
    │
    ▼
FASTQImportConfigSheet (platform, recipe, storage, compression)
    │
    ▼
FASTQIngestionService.ingestAndBundle()
    │  converts FASTQImportConfiguration → CLI arguments
    ▼
CLIImportRunner.run(arguments:)
    │  spawns: lungfish-cli import fastq <args> --format json
    │  reads stdout (AsyncStream<String>)
    │  decodes each line as ImportLogEvent JSON
    ▼
OperationCenter.shared
    │  .start() → .update() → .log() → .complete()/.fail()
    ▼
Operations Panel displays progress + step log
```

## Input Flexibility Requirements

The system must handle all of these input scenarios:

| Input | CLI Form | Behavior |
|-------|----------|----------|
| Single file | `lungfish-cli import fastq reads.fq.gz` | Import as single-end |
| Paired files | `lungfish-cli import fastq R1.fq.gz R2.fq.gz` | Auto-pair by naming convention |
| Many files | `lungfish-cli import fastq *.fq.gz` | Auto-pair all, import each pair |
| Directory (flat) | `lungfish-cli import fastq /run/` | Scan directory, auto-pair |
| Directory (recursive) | `lungfish-cli import fastq /run/ --recursive` | Scan all subdirectories, auto-pair per subdirectory |
| Folder hierarchy | `lungfish-cli import fastq /sequencing_run/ --recursive` | Preserve folder structure under `Imports/` |

### Recursive Directory Scanning

When `--recursive` is specified (or the GUI always passes it for folder input):

1. Walk the directory tree depth-first
2. At each leaf directory containing FASTQ files, detect pairs
3. Preserve the relative path structure under `Imports/`:

```
Input:
/sequencing_run/
  plate1/
    Sample1_R1.fq.gz, Sample1_R2.fq.gz
  plate2/
    Sample2_R1.fq.gz, Sample2_R2.fq.gz

Output in project:
MyProject.lungfish/
  Imports/
    sequencing_run/
      plate1/
        Sample1.lungfishfastq/
      plate2/
        Sample2.lungfishfastq/
```

The relative path from the input root to each FASTQ file's parent directory is preserved as subdirectories under `Imports/`.

### Changes to FASTQBatchImporter

Add `detectPairsFromDirectoryRecursive(_:)` that:
1. Uses `FileManager.enumerator()` (no `.skipsSubdirectoryDescendants`)
2. Groups FASTQ files by their parent directory
3. Detects pairs within each directory group
4. Returns `[SamplePair]` with a new `relativePath: String?` field indicating subdirectory placement

The `SamplePair` struct gains:
```swift
public struct SamplePair: Sendable {
    public let sampleName: String
    public let r1: URL
    public let r2: URL?
    public let relativePath: String?  // nil = root of Imports/
}
```

The batch importer's bundle creation uses `relativePath` to create subdirectories under `Imports/`.

## CLIImportRunner

New actor in `LungfishApp/Services/`:

```swift
actor CLIImportRunner {
    /// Resolves the lungfish-cli binary path.
    func cliBinaryPath() -> URL?

    /// Spawns lungfish-cli import fastq with the given arguments.
    /// Maps JSON log events to OperationCenter for real-time UI updates.
    func run(
        arguments: [String],
        operationID: UUID,
        onBundleCreated: @Sendable (URL) -> Void,
        onError: @Sendable (Error) -> Void
    ) async
}
```

### Binary Resolution

The `lungfish-cli` binary lives at:
- In the app bundle: `<AppBundle>/Contents/MacOS/lungfish-cli` (needs to be included in the Xcode build or SPM product)
- In development: `.build/debug/lungfish-cli`
- Fallback: search PATH

### JSON Event Parsing

The CLI already emits JSON events to stdout when `-v` is used. Each line is one JSON object:

```json
{"event":"importStart","sampleCount":1,"timestamp":"..."}
{"event":"sampleStart","sample":"Sample1","index":0,"total":1,"r1":"R1.fq.gz","r2":"R2.fq.gz","timestamp":"..."}
{"event":"stepStart","sample":"Sample1","step":"Remove PCR duplicates + Adapter + quality trim","stepIndex":1,"totalSteps":5,"timestamp":"..."}
{"event":"stepComplete","sample":"Sample1","step":"Remove PCR duplicates + Adapter + quality trim","durationSeconds":112.4,"timestamp":"..."}
{"event":"sampleComplete","sample":"Sample1","bundle":"Sample1.lungfishfastq","durationSeconds":230.5,"originalBytes":4320897082,"finalBytes":1056497969,"timestamp":"..."}
{"event":"importComplete","completed":1,"skipped":0,"failed":0,"totalDurationSeconds":230.8,"timestamp":"..."}
```

CLIImportRunner reads each line, decodes to `ImportLogEvent`, and maps:

| Event | OperationCenter Action |
|-------|----------------------|
| `importStart` | `.start()` (already called before spawn) |
| `sampleStart` | `.update(detail: "Importing Sample1...")` |
| `stepStart` | `.update(progress: fraction, detail: stepName)` + `.log(stepName)` |
| `stepComplete` | `.log("stepName completed (Ns)")` |
| `sampleComplete` | `.log("Bundle created")` + trigger `onBundleCreated` callback |
| `sampleFailed` | `.fail(detail: errorMessage)` + trigger `onError` callback |
| `importComplete` | `.complete(detail: "N imported, N skipped, N failed")` |

### Cancellation

When the user clicks Cancel in the Operations Panel:
1. `OperationCenter`'s `onCancel` callback fires
2. CLIImportRunner sends `SIGTERM` to the child process via `ProcessManager`
3. The CLI receives the signal and cleans up temp files
4. CLIImportRunner reads remaining stderr, reports failure

### Error Handling

- If the CLI binary is not found: report error immediately, don't spawn
- If the CLI exits with non-zero: read stderr, report to OperationCenter as failure
- If JSON parsing fails on a line: log a warning but continue (some lines may be non-JSON progress text)
- If the CLI hangs: timeout after 2 hours per sample (configurable)

## FASTQIngestionService Update

Replace the current `runIngestAndBundle()` body (which calls `FASTQBatchImporter` directly) with `CLIImportRunner`:

```swift
private static func runIngestAndBundle(
    pair: FASTQFilePair,
    projectDirectory: URL,
    bundleName: String,
    importConfig: FASTQImportConfiguration,
    operationID opID: UUID,
    completion: @escaping @MainActor (Result<URL, Error>) -> Void
) async {
    let runner = CLIImportRunner()
    let args = buildCLIArguments(
        pair: pair,
        projectDirectory: projectDirectory,
        importConfig: importConfig
    )

    await runner.run(
        arguments: args,
        operationID: opID,
        onBundleCreated: { bundleURL in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(.success(bundleURL)) }
            }
        },
        onError: { error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(.failure(error)) }
            }
        }
    )
}
```

### Argument Building

```swift
private static func buildCLIArguments(
    pair: FASTQFilePair,
    projectDirectory: URL,
    importConfig: FASTQImportConfiguration
) -> [String] {
    var args = ["import", "fastq"]
    args.append(pair.r1.path)
    if let r2 = pair.r2 { args.append(r2.path) }
    args += ["--project", projectDirectory.path]
    args += ["--platform", mapPlatform(importConfig.confirmedPlatform)]
    if let recipe = resolveRecipeName(importConfig) {
        args += ["--recipe", recipe]
    }
    args += ["--quality-binning", importConfig.qualityBinning.rawValue]
    if importConfig.skipClumpify { args.append("--no-optimize-storage") }
    args += ["--compression", "balanced"]  // or from config
    args += ["--format", "json"]
    args.append("-v")
    return args
}
```

## Import Center Updates

### New Tab: "Sequencing Reads"

Add to `ImportCenterViewModel.Tab`:
```swift
case sequencingReads
```

Add to `allCards`:
```swift
ImportCardInfo(
    id: "fastq",
    title: "FASTQ Files",
    description: "Import paired-end or single-end sequencing reads",
    iconName: "doc.text.fill",
    tab: .sequencingReads,
    supportedExtensions: ["fastq", "fastq.gz", "fq", "fq.gz"],
    action: .openPanel(allowsDirectories: true)  // NEW: allow both files AND directories
)
```

### File/Folder Selection

The Import Center's NSOpenPanel configuration for the FASTQ card:
- `allowsMultipleSelection = true` — select many files at once
- `canChooseFiles = true` — individual FASTQ files
- `canChooseDirectories = true` — folders (scanned recursively)
- `allowedContentTypes` for .fastq.gz, .fq.gz, .fastq, .fq
- When a directory is selected, always use `--recursive` flag

After selection:
1. If user selected individual files → pass directly as arguments
2. If user selected a directory → pass with `--recursive`
3. If user selected a mix → separate files from directories, import each directory recursively and files as explicit pairs
4. Show `FASTQImportConfigSheet` with auto-detected platform + recipe picker before starting

### Config Sheet Updates

Minor changes to `FASTQImportConfigSheet`:
- Recipe popup now loads from `RecipeRegistryV2.allRecipes(platform:)` instead of old `ProcessingRecipe.builtinRecipes`
- Add compression level picker (3 options: Fast / Balanced / Maximum)
- Rename "Skip Clumpify" → "Optimize storage" with inverted logic (checkbox = ON by default)
- Show file/folder count summary at top: "12 files (6 pairs) from 2 folders"

## CLI Changes

### New `--recursive` flag

```swift
@Flag(
    name: .customLong("recursive"),
    help: "Recursively scan directories for FASTQ files"
)
var recursive: Bool = false
```

When `--recursive` is set and input is a directory:
- Use `detectPairsFromDirectoryRecursive()` instead of `detectPairsFromDirectory()`
- Preserve relative paths in output bundles

### JSON output via existing `--format json`

The CLI already has a global `--format` option (`text`, `json`, `tsv`) via `GlobalOptions.outputFormat`. When `--format json` is passed:
- All `ImportLogEvent` instances are emitted as one JSON object per line to stdout
- No human-readable formatting is applied
- This is the mode the GUI uses when spawning the CLI

The JSON events are the `ImportLogEvent` enum already defined in `FASTQBatchImporter.swift`. The CLI currently only emits them when `-v` is set. Change: emit JSON events unconditionally when `--format json`, regardless of verbosity level.

## File Changes

### New Files

| File | Description |
|------|-------------|
| `LungfishApp/Services/CLIImportRunner.swift` | Actor: spawns lungfish-cli, reads JSON events, maps to OperationCenter |

### Modified Files

| File | Changes |
|------|---------|
| `LungfishWorkflow/Ingestion/FASTQBatchImporter.swift` | Add `detectPairsFromDirectoryRecursive()`, add `relativePath` to `SamplePair`, use `relativePath` in bundle output path |
| `LungfishCLI/Commands/ImportFastqCommand.swift` | Add `--recursive` flag, emit JSON events when `--format json`, handle recursive directory scanning |
| `LungfishApp/Services/FASTQIngestionService.swift` | Replace direct BatchImporter call with CLIImportRunner subprocess |
| `LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift` | Add `.sequencingReads` tab, FASTQ card, dispatch logic |
| `LungfishApp/Views/ImportCenter/ImportCenterView.swift` | Add 5th tab segment |
| `LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift` | Use RecipeRegistryV2 for recipe list, add compression picker, rename clumpify checkbox |

## Testing

### Unit Tests
- `CLIImportRunner`: Feed mock JSON event lines, verify OperationCenter calls
- `detectPairsFromDirectoryRecursive`: Test with nested directory structure, verify relative paths
- `buildCLIArguments`: Verify correct flags for each config combination
- `--recursive` CLI flag parsing

### Integration Tests
- Spawn `lungfish-cli import fastq` on test fixtures, verify JSON output
- Recursive import on a test directory hierarchy, verify bundle placement
- Import Center FASTQ card exists and is visible

### E2E Test
- CLI: `lungfish-cli import fastq /tmp/test-hierarchy/ --recursive --project /tmp/test.lungfish --dry-run` → lists pairs with relative paths
