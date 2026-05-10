# Declarative Recipe Engine

**Date**: 2026-04-04
**Branch**: `fastq-vsp2-optimization`
**Status**: Design

## Goal

Replace the hard-coded `ProcessingRecipe` / `FASTQBatchImporter.applyRecipe()` system with a declarative, JSON-based recipe engine that supports platform-aware recipe filtering, typed step executors, automatic file-format routing, and fastp fusion optimization. Implement the VSP2 recipe as the first recipe in the new format using the optimized tools identified by benchmarking (fastp, deacon).

## Non-Goals

- GUI recipe editor (future)
- GUI import dialog redesign (future — wire existing dialog to new config)
- Migration of other built-in recipes (WGS, amplicon, HiFi, targeted) — documented for a future session
- Custom-tool escape hatch step type
- Recipe sharing/export

## Architecture Overview

```
Platform Selection → Recipe Filtering → Import Config → Recipe Engine → Bundle Finalization
```

1. **Platform** is selected (auto-detected or manual) — determines available recipes and finalization defaults
2. **Recipe** is selected from the filtered list (or none for raw import)
3. **ImportConfig** is assembled from platform defaults + recipe defaults + user overrides
4. **RecipeEngine** validates the recipe, plans format conversions, optionally fuses consecutive fastp steps, and executes each step via its registered `RecipeStepExecutor`
5. **Bundle finalization** (clumpify k-mer sort + quality binning + compression) runs after the recipe, controlled by ImportConfig

## Sequencing Platform Model

```swift
enum SequencingPlatform: String, Codable, CaseIterable, Sendable {
    case illumina
    case ont
    case pacbio
    case ultima
}
```

Each platform defines defaults for the import configuration:

| Platform | Display Name | Default Pairing | Optimize Storage | Quality Binning | Compression |
|----------|-------------|-----------------|-----------------|----------------|-------------|
| illumina | Illumina | paired | true | illumina4 | balanced |
| ont | Oxford Nanopore | single | false | none | balanced |
| pacbio | PacBio HiFi | single | false | none | balanced |
| ultima | Ultima Genomics | paired | true | illumina4 | balanced |

**Auto-detection** from FASTQ headers (best-effort, user can always override):
- Illumina: header matches `@INSTRUMENT:RUN:FLOWCELL:LANE:TILE:X:Y` pattern
- ONT: header contains `runid=` or instrument ID starting with known ONT prefixes
- PacBio: header contains `zmw` or `/ccs` suffix
- Ultima: header matches Ultima-specific format

Auto-detection reads the first record from R1 and attempts to match. Falls back to `nil` (user must select).

**CLI**: `--platform illumina|ont|pacbio|ultima` — defaults to auto-detect if omitted.

## Recipe Format (JSON)

```json
{
  "formatVersion": 1,
  "id": "vsp2-target-enrichment",
  "name": "VSP2 Target Enrichment",
  "description": "Optimized for VSP2 short-insert viral enrichment: dedup, trim, scrub human, merge, length filter.",
  "author": "Lungfish Built-in",
  "tags": ["illumina", "vsp2", "viral", "paired-end", "target-enrichment"],
  "platforms": ["illumina"],
  "requiredInput": "paired",
  "qualityBinning": "illumina4",
  "steps": [
    {
      "type": "fastp-dedup",
      "label": "Remove PCR duplicates"
    },
    {
      "type": "fastp-trim",
      "label": "Adapter + quality trim",
      "params": {
        "detectAdapter": true,
        "quality": 15,
        "window": 5,
        "cutMode": "right"
      }
    },
    {
      "type": "deacon-scrub",
      "label": "Remove human reads",
      "params": {
        "database": "deacon"
      }
    },
    {
      "type": "fastp-merge",
      "label": "Merge overlapping pairs",
      "params": {
        "minOverlap": 15
      }
    },
    {
      "type": "seqkit-length-filter",
      "label": "Remove short reads",
      "params": {
        "minLength": 50
      }
    }
  ]
}
```

**Field definitions:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `formatVersion` | Int | Yes | Schema version for forward compatibility. Currently `1`. |
| `id` | String | Yes | Machine-readable identifier (kebab-case). Must be unique. |
| `name` | String | Yes | Human-readable name shown in UI and CLI. |
| `description` | String | No | One-line description. |
| `author` | String | No | Creator attribution. |
| `tags` | [String] | No | Searchable tags for filtering/organization. |
| `platforms` | [String] | Yes | Which platforms this recipe supports. Values: `"illumina"`, `"ont"`, `"pacbio"`, `"ultima"`. |
| `requiredInput` | String | Yes | `"paired"`, `"single"`, or `"any"`. |
| `qualityBinning` | String | No | Suggested binning: `"illumina4"`, `"eightLevel"`, `"none"`. Overridable at import time. Defaults to platform default if omitted. |
| `steps` | [Step] | Yes | Ordered processing steps. |
| `steps[].type` | String | Yes | Registered step executor ID (e.g., `"fastp-dedup"`). |
| `steps[].label` | String | No | Human-readable label for UI/logs. Defaults to step type display name. |
| `steps[].params` | Object | No | Type-specific parameters. Each step type defines its parameter schema. |

**File location:**
- Built-in recipes: `Sources/LungfishWorkflow/Resources/Recipes/*.recipe.json`
- User recipes: `~/Library/Application Support/Lungfish/recipes/*.recipe.json`

## Step Type Registry

### Protocol

```swift
protocol RecipeStepExecutor: Sendable {
    /// Unique type identifier matching the recipe JSON "type" field.
    static var typeID: String { get }

    /// Human-readable name for UI/logs when no label is provided.
    static var displayName: String { get }

    /// What input format this step accepts.
    var inputFormat: FileFormat { get }

    /// What output format this step produces.
    var outputFormat: FileFormat { get }

    /// Initialize from recipe JSON params dictionary.
    init(params: [String: Any]) throws

    /// Execute the step, returning output file(s).
    func execute(input: StepInput, context: StepContext) async throws -> StepOutput
}
```

### Supporting Types

```swift
enum FileFormat: String, Codable, Sendable {
    case pairedR1R2   // separate R1.fq.gz + R2.fq.gz
    case interleaved  // single interleaved FASTQ
    case merged       // post-merge: merged.fq.gz + unmerged_R1.fq.gz + unmerged_R2.fq.gz
    case single       // single-end reads
}

struct StepInput: Sendable {
    let r1: URL            // primary file (R1, interleaved, merged, or single)
    let r2: URL?           // R2 for pairedR1R2; unmerged_R1 for merged format
    let r3: URL?           // unmerged_R2 for merged format; nil otherwise
    let format: FileFormat
}

struct StepOutput: Sendable {
    let r1: URL
    let r2: URL?
    let r3: URL?
    let format: FileFormat
    let readCount: Int?   // if known (from tool output parsing)
}

struct StepContext: Sendable {
    let workspace: URL
    let threads: Int
    let sampleName: String
    let runner: NativeToolRunner
    let databaseRegistry: DatabaseRegistry
    let progress: @Sendable (Double, String) -> Void
}
```

### Built-in Step Types for VSP2

| Type ID | Struct | Input Format | Output Format | Tool | Key Params |
|---------|--------|-------------|---------------|------|------------|
| `fastp-dedup` | `FastpDedupStep` | pairedR1R2 | pairedR1R2 | fastp | (none — just `--dedup`) |
| `fastp-trim` | `FastpTrimStep` | pairedR1R2 | pairedR1R2 | fastp | `detectAdapter`, `quality`, `window`, `cutMode` |
| `deacon-scrub` | `DeaconScrubStep` | pairedR1R2 | pairedR1R2 | deacon | `database` |
| `fastp-merge` | `FastpMergeStep` | pairedR1R2 | merged | fastp | `minOverlap` |
| `seqkit-length-filter` | `SeqkitLengthFilterStep` | any | same as input | seqkit | `minLength`, `maxLength` |

### Step Parameter Schemas

**fastp-dedup**: No parameters. Always runs `fastp --dedup -A -G -Q -L` (all non-dedup operations disabled).

**fastp-trim**:
| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `detectAdapter` | bool | true | Auto-detect adapters for PE |
| `quality` | int | 20 | Quality threshold for trimming |
| `window` | int | 4 | Sliding window size |
| `cutMode` | string | "right" | `"right"`, `"front"`, `"tail"`, `"both"` |

**deacon-scrub**:
| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `database` | string | "deacon" | Database ID resolved via DatabaseRegistry |

**fastp-merge**:
| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `minOverlap` | int | 15 | Minimum overlap length for merging |

**seqkit-length-filter**:
| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `minLength` | int | 0 | Minimum read length |
| `maxLength` | int? | nil | Maximum read length (nil = no max) |

## Fastp Fusion Optimization

When consecutive recipe steps all use fastp and operate on pairedR1R2 → pairedR1R2, the engine fuses them into a single fastp invocation. This eliminates intermediate read/write cycles.

**How it works:** Each fastp step type conforms to a `FastpFusible` protocol:

```swift
protocol FastpFusible: RecipeStepExecutor {
    /// Returns the fastp CLI arguments this step contributes.
    func fastpArgs() -> [String]
}
```

The engine scans the step list for consecutive `FastpFusible` steps with compatible formats. When found, it collects all `fastpArgs()` into a single fastp invocation.

**Example — VSP2 steps 1+2 fuse:**

`fastp-dedup` contributes: `["--dedup"]`
`fastp-trim` contributes: `["--detect_adapter_for_pe", "-q", "15", "-W", "5", "--cut_right"]`

Fused command: `fastp -i R1 -I R2 -o out.R1 -O out.R2 --dedup --detect_adapter_for_pe -q 15 -W 5 --cut_right`

**Non-fusible boundary:** `deacon-scrub` is not fastp, so the fusion stops. Steps 1+2 fuse, steps 3-5 run individually.

**When fusion is NOT applied:**
- Step formats differ (e.g., one produces `mixed`)
- Steps use different tools
- Only one consecutive fastp step (no benefit)

## Recipe Engine (Orchestrator)

```swift
final class RecipeEngine: Sendable {
    /// Execute a recipe on input files, returning the processed output URL.
    func execute(
        recipe: Recipe,
        input: StepInput,
        config: ImportConfig,
        context: StepContext
    ) async throws -> StepOutput
}
```

**Execution phases:**

1. **Validate**: Check all step types are registered, input format matches `requiredInput`, format chain is compatible (each step's output format is convertible to the next step's input format).

2. **Plan**: Build an execution plan — identify format conversions needed between steps, identify fusible fastp sequences, assign temp file names.

3. **Execute**: Iterate the plan. For each entry:
   - If format conversion needed, insert a reformat.sh call
   - If fused fastp group, run single fastp with merged args
   - Otherwise, run the step executor
   - Report progress: `(stepIndex / totalSteps, stepLabel)`
   - Clean up intermediate files from previous step

4. **Return**: Final StepOutput with the processed file(s).

**Format conversion rules:**

| From | To | Conversion |
|------|----|-----------|
| pairedR1R2 | interleaved | reformat.sh `in=R1 in2=R2 out=interleaved.fq` |
| interleaved | pairedR1R2 | reformat.sh `in=interleaved.fq out=R1 out2=R2` |
| merged | single | Concatenate: `cat merged.fq.gz unmerged_R1.fq.gz unmerged_R2.fq.gz > combined.fq.gz` |
| single | pairedR1R2 | Error — cannot create pairs from single reads |

The `merged` format carries three files (merged reads, unmerged R1, unmerged R2). Steps that accept `single` or `any` can consume merged output after concatenation. Steps that require `pairedR1R2` cannot follow a merge step (the pairs have been consumed).

## Import Config

```swift
struct ImportConfig: Sendable {
    let platform: SequencingPlatform
    let recipe: Recipe?
    let qualityBinning: QualityBinning
    let optimizeStorage: Bool
    let compressionLevel: CompressionLevel
    let threads: Int
    let logDirectory: URL?
    let forceReimport: Bool
}

enum QualityBinning: String, Codable, Sendable {
    case illumina4   // quantize=0,8,13,22,27,32,37
    case eightLevel  // quantize=2
    case none
}

enum CompressionLevel: String, Codable, Sendable {
    case fast       // zl=1, pigz -1
    case balanced   // zl=4, pigz -4 (default)
    case maximum    // zl=9, pigz -9

    var zlValue: Int {
        switch self {
        case .fast: return 1
        case .balanced: return 4
        case .maximum: return 9
        }
    }
}
```

**Default resolution order:**
1. Explicit user value (CLI flag or GUI selection)
2. Recipe-declared default (`qualityBinning` field in recipe JSON)
3. Platform default (from `SequencingPlatform` enum)

**GUI labels:**

| Internal | GUI Label | GUI Description |
|----------|-----------|-----------------|
| `optimizeStorage` | Optimize storage | Reorder reads for smaller files. Recommended for long-term projects. |
| `compressionLevel` | Compression | Fast (larger files) / Balanced / Maximum (slower import) |
| `qualityBinning` | Quality binning | Reduce quality score precision for smaller files. Recommended for Illumina. |

**CLI flags:**

```
lungfish import fastq /data/ \
    --project ./MyProject.lungfish \
    --platform illumina \
    --recipe vsp2 \
    --quality-binning illumina4 \
    --no-optimize-storage \
    --compression balanced \
    --threads 8 \
    --log-dir ./logs \
    --force
```

`--platform` defaults to auto-detect. `--recipe` defaults to none. Other flags default per platform/recipe.

## Bundle Finalization

After the recipe engine completes (or immediately for raw imports), the bundle finalization step runs:

1. **Clumpify k-mer sort** (if `optimizeStorage` is true):
   - `clumpify.sh in=processed.fq.gz out=sorted.fq.gz reorder groups=auto pigz=t zl={compressionLevel} -Xmx{heapGB}g threads={threads}`
   - Quality binning applied: `quantize={binningScheme}` (if not `none`)

2. **Compress** (if `optimizeStorage` is false):
   - Skip clumpify, just ensure output is gzipped at the configured compression level via pigz

3. **Bundle creation**: Move finalized file(s) into `.lungfishfastq` bundle with metadata

This logic lives in `FASTQBatchImporter` (existing responsibility), not in the recipe engine.

## Deacon Tool Registration

**NativeToolRunner**: Add `deacon` to the `NativeTool` enum. Unlike other bundled tools, deacon is installed via conda into `~/miniforge3/envs/deacon-bench/bin/deacon`. NativeToolRunner needs a resolution path for conda-managed tools.

**Approach**: Add a `condaEnvironment` property to NativeTool for tools that live in conda envs. `NativeToolRunner.toolPath(for:)` checks conda env path first, then bundled tools directory.

**DatabaseRegistry**: Register the deacon panhuman-1 index. Manifest already exists at `~/Library/Application Support/Lungfish/databases/deacon/manifest.json` from the benchmark setup.

## File Changes

### New Files

| File | Module | Description |
|------|--------|-------------|
| `Recipes/Recipe.swift` | LungfishWorkflow | Recipe model, JSON Codable, platform/step definitions |
| `Recipes/RecipeStepExecutor.swift` | LungfishWorkflow | Step protocol, FastpFusible, StepInput/Output/Context, FileFormat |
| `Recipes/RecipeEngine.swift` | LungfishWorkflow | Orchestrator: validate, plan, execute, format conversion |
| `Recipes/RecipeRegistry.swift` | LungfishWorkflow | Load built-in + user recipes, filter by platform |
| `Recipes/Steps/FastpDedupStep.swift` | LungfishWorkflow | fastp --dedup executor |
| `Recipes/Steps/FastpTrimStep.swift` | LungfishWorkflow | fastp adapter/quality trim executor |
| `Recipes/Steps/DeaconScrubStep.swift` | LungfishWorkflow | deacon human read depletion executor |
| `Recipes/Steps/FastpMergeStep.swift` | LungfishWorkflow | fastp --merge executor |
| `Recipes/Steps/SeqkitLengthFilterStep.swift` | LungfishWorkflow | seqkit length filter executor |
| `Recipes/SequencingPlatform.swift` | LungfishWorkflow | Platform enum with defaults and auto-detection |
| `Resources/Recipes/vsp2.recipe.json` | LungfishWorkflow | VSP2 recipe as bundled JSON |

### Modified Files

| File | Module | Changes |
|------|--------|---------|
| `Ingestion/FASTQBatchImporter.swift` | LungfishWorkflow | Replace `applyRecipe()` with RecipeEngine call. Update ImportConfig struct. Simplify to: pair detection → recipe engine → bundle finalization. Remove 800+ lines of inline step execution. |
| `Native/NativeToolRunner.swift` | LungfishWorkflow | Add `deacon` to NativeTool enum. Add conda env tool resolution. |
| `Databases/DatabaseRegistry.swift` | LungfishWorkflow | Register deacon database ID if not already handled by manifest auto-discovery. |
| `Commands/ImportFastqCommand.swift` | LungfishCLI | Add `--platform`, `--no-optimize-storage`, `--compression`, `--force` flags. Update recipe resolution to use new RecipeRegistry. |

### Deprecated (to be removed after all recipes migrate)

| File | Module | Notes |
|------|--------|-------|
| `Formats/FASTQ/ProcessingRecipe.swift` | LungfishIO | Old recipe model. Keep `FASTQComparisonResult` and `RecipePlaceholder` for now. Old built-in recipes and `RecipeRegistry` replaced by new system. |

## Testing Strategy (TDD)

All implementation follows strict TDD: write the failing test first, verify it fails, implement the minimum code to pass, verify it passes, commit.

### Unit Tests

**Recipe parsing** (`RecipeParsingTests`):
- Parse valid VSP2 recipe JSON → correct model
- Parse recipe with missing optional fields → defaults applied
- Parse recipe with unknown step type → validation error
- Parse recipe with invalid format version → error
- Round-trip encode/decode preserves all fields

**Platform** (`SequencingPlatformTests`):
- Each platform returns correct defaults
- Auto-detect Illumina header → `.illumina`
- Auto-detect ONT header → `.ont`
- Auto-detect PacBio header → `.pacbio`
- Unrecognizable header → `nil`

**Step executors** (`StepExecutorTests`):
- Each step type initializes from params dictionary
- Each step type produces correct tool arguments for default params
- Each step type produces correct tool arguments for custom params
- Each step declares correct input/output formats
- Invalid params → initialization error

**Fastp fusion** (`FastpFusionTests`):
- Two consecutive fastp steps → fused into single invocation
- Three consecutive fastp steps → all fused
- fastp + non-fastp + fastp → two groups, not fused across non-fastp
- Single fastp step → no fusion
- fastp-merge (output format changes to `merged`) → not fused with preceding fastp steps

**Recipe engine** (`RecipeEngineTests`):
- Valid recipe with compatible format chain → executes all steps
- Step output format != next step input format → auto-converts
- Recipe requires paired but input is single → validation error
- Unknown step type → validation error
- Step execution failure → propagates error with step context

**Format conversion** (`FormatConversionTests`):
- pairedR1R2 → interleaved → reformat.sh called with correct args
- interleaved → pairedR1R2 → reformat.sh called with correct args
- same format → no conversion
- single → pairedR1R2 → error

**Import config** (`ImportConfigTests`):
- Platform defaults applied when no recipe
- Recipe qualityBinning overrides platform default
- Explicit user value overrides recipe default
- CLI flag parsing for all new flags

### Integration Tests

**VSP2 recipe on test fixtures** (`RecipeIntegrationTests`):
- Load vsp2.recipe.json → parse succeeds
- Execute VSP2 recipe on sarscov2 test fixtures → output is valid FASTQ
- Output read count is less than input (steps removed reads)
- Fastp fusion produces same output as non-fused execution

**CLI integration** (`CLIRecipeTests`):
- `lungfish import fastq --recipe vsp2 --dry-run` → shows detected pairs and recipe summary
- `lungfish import fastq --platform illumina --recipe vsp2` → completes without error on test data

## Migration Path

This implementation replaces the old recipe system for VSP2 only. Other built-in recipes (`illuminaWGS`, `ontAmplicon`, `pacbioHiFi`, `targetedAmplicon`) continue to use the old `ProcessingRecipe` / `FASTQBatchImporter.applyRecipe()` code path until they are migrated in a future session.

**Coexistence**: `FASTQBatchImporter` checks if the selected recipe is a new-format `Recipe` (loaded from JSON) or an old-format `ProcessingRecipe`. If new-format, delegates to `RecipeEngine`. If old-format, uses the existing `applyRecipe()` code path. This avoids a big-bang migration.

**Future recipe creation guide**: After VSP2 is proven, write a `docs/recipes/creating-recipes.md` guide documenting the JSON format, available step types, parameter schemas, and examples. This guide enables future sessions to add recipes without understanding the engine internals.
