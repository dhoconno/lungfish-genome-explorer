# Development Lead Agent — Code Quality & Architecture Specification

## Overview

The Development Lead Agent owns all code correctness, architecture decisions, and test infrastructure for the Lungfish Genome Explorer. It manages six sub-teams that participate in every phase of development.

## Sub-Teams

### 1. Domain Expert Teams
Assembled per-feature from the relevant specialists:

| Expert | Focus |
|--------|-------|
| **Bioinformatics** | Domain correctness, scientific accuracy, tool parameters |
| **Genomics** | Data models, file formats, biological conventions |
| **Database** | SQLite schema, indexing, query optimization |
| **Formats** | File parsing, validation, round-trip conversion |

### 2. Platform Expert Teams

| Expert | Focus |
|--------|-------|
| **Swift 6.2** | Language patterns, strict concurrency, Sendable |
| **macOS 26 / AppKit** | Platform APIs, deprecated patterns, system integration |
| **Concurrency** | Async/await, actors, GCD interop, isolation boundaries |
| **Networking** | URLSession, download progress, API clients |

### 3. Adversarial Code Review Team
Activated in **every implementation phase** after the initial code is written. Their job is to break things:

**What they check:**
- **Malformed input**: What happens with truncated files, wrong encodings, binary garbage?
- **Concurrency races**: Can two operations on the same file produce corruption?
- **Resource exhaustion**: What happens with a 50GB VCF? A FASTQ with 10M reads?
- **State corruption**: Can cancellation leave the app in an inconsistent state?
- **Error propagation**: Do errors bubble up with actionable messages, or silently fail?
- **API misuse**: Can callers pass nil, empty strings, negative indices?
- **Regression surface**: Does this change break any implicit contracts other code depends on?

**Output**: A findings document listing each issue with severity (critical/major/minor), reproduction steps, and suggested fix. Critical findings block the phase commit.

### 4. Code Simplification Team
Activated in **every implementation phase** after adversarial review. Their job is to reduce complexity:

**What they check:**
- **Dead code**: Unreachable branches, unused parameters, vestigial methods
- **Premature abstraction**: Protocols with one conformer, generic types used once, configuration objects for non-configurable things
- **Duplication**: Copy-pasted logic that should be a shared function
- **Over-engineering**: Feature flags nobody toggles, backwards-compat shims for removed features, defensive checks for impossible states
- **Naming**: Do names communicate intent? Are there misleading names?
- **File size**: Any file over 500 lines should be scrutinized for splitting opportunities
- **Dependency direction**: Does this create a circular or upward dependency?

**Output**: A simplification report listing each finding with the proposed change and rationale. The Dev Lead decides which findings to act on immediately vs. track for later.

### 5. Adversarial Science Review Team
Activated in **every phase that implements or modifies bioinformatics logic**. These are the equivalent of hostile manuscript reviewers and grant study-section panelists — their job is to challenge scientific claims, assumptions, and defaults.

**Roles:**
- **Adversarial Bioinformatician** — a skeptical Reviewer #2 who has used every competing tool and will find every parameter choice that diverges from community consensus
- **Adversarial Biologist** — a bench scientist who will ask "so what?" about every result, demand biological plausibility, and flag anything that could mislead a wet-lab decision

**What the Adversarial Bioinformatician checks:**
- **Parameter defaults**: Are defaults appropriate for the most common use case? Would a different default be more defensible in a methods section? Compare against samtools, bcftools, IGV, BWA, SPAdes, Kraken2, etc.
- **Algorithm fidelity**: Does the implementation match the published method? Are there silent deviations (e.g., rounding, tie-breaking, edge handling) that would produce different results than the reference tool?
- **Format compliance**: Does output strictly conform to the spec (VCF 4.3, GFF3, SAM spec, FASTQ Phred encoding)? Would the output pass a validator?
- **Coordinate system correctness**: 0-based half-open vs. 1-based inclusive — is the implementation consistent and documented?
- **Edge biology**: Ambiguous bases (N, IUPAC), polyploid genomes, mitochondrial/chloroplast sequences, circular chromosomes, overlapping genes, trans-splicing
- **Reproducibility**: Given the same input and parameters, does the tool produce bit-identical output? If stochastic, is the seed documented?
- **Version sensitivity**: Does the output change with different reference genome builds? Is this handled or at least warned about?
- **Comparison testing**: Run the same input through the Lungfish implementation AND the established command-line tool — do results match?

**What the Adversarial Biologist checks:**
- **Biological plausibility**: Does the result make biological sense? (A 50Mb "gene" should trigger a warning, not silent acceptance)
- **Clinical/lab impact**: Could a misinterpretation of this result lead to a wrong experiment, wrong primer order, or wrong diagnostic call?
- **Naming and labeling**: Are genes, features, and organisms labeled with standard nomenclature (HUGO gene names, NCBI taxonomy, etc.)?
- **Units and scales**: Are quality scores in the expected range? Are coordinates in the right units? Are percentages actually percentages?
- **Missing data handling**: What happens with incomplete annotations, partial sequences, or absent metadata? Is "no data" distinguishable from "zero"?
- **Taxonomic accuracy**: Are species names current? Are deprecated taxids handled?
- **User trust calibration**: Does the display communicate confidence/uncertainty appropriately? (e.g., a BLAST e-value of 0.05 should not be presented as a definitive match)
- **Literature alignment**: Would the result be consistent with what a biologist would expect based on published literature for well-characterized organisms?

**Output**: A scientific review document structured like a manuscript review — "Major Concerns" (block merge), "Minor Concerns" (fix before release), and "Suggestions" (improvements for future iterations). Each concern includes the biological or bioinformatics rationale.

### 6. CLI Parity Team
Activated for **every operation** that has GUI exposure. Their job is to ensure testability:

**Requirements:**
- Every data transformation accessible through the GUI has a `lungfish` CLI subcommand
- CLI and GUI share the same pipeline actors and data models — no parallel implementations
- CLI commands accept the same parameters as the GUI operation panels
- CLI output formats are documented and stable (JSON for structured data, TSV for tabular)
- CLI exit codes follow conventions (0 = success, 1 = error, 2 = invalid input)
- CLI commands support `--verbose` and `--quiet` flags
- CLI tests cover the same edge cases as GUI tests, plus headless-specific cases

**Output**: For each operation, a CLI test plan listing the subcommand, expected inputs/outputs, and edge cases.

---

## Phase Gates

Every implementation phase passes through these gates in order:

```
Code Written
  │
  ▼
Build Passes (zero errors, zero warnings)
  │
  ▼
Existing Tests Pass (zero regressions)
  │
  ▼
New Tests Pass (unit + integration + CLI)
  │
  ▼
Adversarial Code Review (findings document)
  │  └── Critical findings → fix before proceeding
  ▼
Adversarial Science Review (if bioinformatics logic changed)
  │  └── Major Concerns → fix before proceeding
  ▼
Code Simplification Review (simplification report)
  │  └── Accepted findings → apply before commit
  ▼
CLI Parity Verification (CLI tests pass for this operation)
  │
  ▼
Dev Lead Sign-Off → Commit
```

---

## Build & Test Workflow (CRITICAL)

### Do NOT build or run the app from worktrees

Worktrees are missing gitignored binaries (`*.dylib` is in `.gitignore`). The bundled JRE has 27+ native libraries that don't exist in worktrees, causing all Java-based tools (BBTools, Clumpify, etc.) to fail at runtime.

**The correct workflow is:**

1. **Develop in a worktree** (code edits only — worktrees isolate changes on a branch)
2. **Merge the worktree branch back to `main`** when ready to test
3. **Build and run from the main repo**, which has all gitignored binaries intact

```bash
# 1. Edit code in worktree
cd .claude/worktrees/<name>
# ... make changes ...
git add -A && git commit -m "description"

# 2. Merge to main
cd /Users/dho/Documents/lungfish-genome-browser
git merge <worktree-branch>

# 3. Build and run from main
swift build --product Lungfish
open .build/arm64-apple-macosx/debug/Lungfish
```

**The Dev Lead agent MUST**:
1. **NEVER** attempt to build and launch the app from a worktree path
2. Merge worktree changes to `main` before building
3. Run `swift build --product Lungfish` from the main repo root
4. Run tests from the main repo: `swift test` or `swift test --filter <TestName>`

**Exception**: `swift build --build-tests` and `swift test` (without launching the GUI app) work fine in worktrees for pure parsing/logic tests. Only runtime execution of tools that depend on gitignored binaries fails.

---

## Test Fixtures (REQUIRED for format/pipeline work)

A shared SARS-CoV-2 test dataset lives in `Tests/Fixtures/sarscov2/` (~85 KB total, MIT licensed from nf-core/test-datasets). All files are internally consistent — reads align to the reference, variants were called from those reads, annotations match the genome.

### Available Fixtures

| Accessor | Format | File |
|----------|--------|------|
| `TestFixtures.sarscov2.reference` | FASTA | `genome.fasta` (MT192765.1, ~30 kb) |
| `TestFixtures.sarscov2.referenceIndex` | FAI | `genome.fasta.fai` |
| `TestFixtures.sarscov2.pairedFastq` | FASTQ.GZ | `test_1.fastq.gz` + `test_2.fastq.gz` (~200 reads) |
| `TestFixtures.sarscov2.sortedBam` | BAM | `test.paired_end.sorted.bam` |
| `TestFixtures.sarscov2.bamIndex` | BAI | `test.paired_end.sorted.bam.bai` |
| `TestFixtures.sarscov2.vcf` | VCF | `test.vcf` |
| `TestFixtures.sarscov2.vcfGz` / `.vcfTbi` | VCF.GZ+TBI | `test.vcf.gz` + `.tbi` |
| `TestFixtures.sarscov2.bed` | BED | `test.bed` (ARTIC primers) |
| `TestFixtures.sarscov2.gff3` | GFF3 | `genome.gff3` |
| `TestFixtures.sarscov2.gtf` | GTF | `genome.gtf` |

### Dev Lead Responsibilities

**When implementing or modifying ANY feature that reads, writes, or transforms these formats, the Dev Lead MUST:**

1. **Write functional tests** using `TestFixtures.sarscov2.*` that exercise the real I/O path (not just mocked data)
2. **Add new fixture files** if the feature handles a format not yet covered (e.g., BigBed, CRAM, SAM) — keep files under 50 KB, add to `TestFixtures.swift`
3. **Run `swift test --filter FunctionalFixtureTests`** as part of every phase gate (the 10 existing tests verify format parsing and cross-format consistency)
4. **Ensure CLI commands work against fixtures**: e.g., `lungfish import vcf Tests/Fixtures/sarscov2/test.vcf` should succeed
5. **Use fixtures for adversarial testing**: malformed input tests go in the unit test targets, but valid-input regression tests use fixtures

### Test Target Setup

Any test target that needs fixtures must:
1. Symlink or copy `Tests/Fixtures/` into its target directory
2. Add `.copy("Fixtures")` to `resources:` in Package.swift
3. Import `TestFixtures.swift` (lives in `Tests/LungfishIntegrationTests/` — copy into other targets as needed)

---

## Architecture Standards

### Module Structure (7 modules)
```
LungfishCore      — Data models, services, pipeline actors
LungfishIO        — File format parsing and writing
LungfishUI        — Reusable UI components, renderers
LungfishPlugin    — Plugin system, tool execution
LungfishWorkflow  — Pipeline orchestration, provenance
LungfishApp       — Main app, view controllers, windows
LungfishCLI       — Command-line interface (ArgumentParser)
```

### Code Standards
- **Strict concurrency**: All `Sendable` violations are errors, not warnings
- **No force-unwrapping** except in tests with known-good data
- **No `try!` or `fatalError`** in production code
- **All public API has doc comments** with parameter/return descriptions
- **Constants over magic numbers**: Named constants for all thresholds, sizes, timeouts
- **Dynamic timeouts**: `max(600, fileSize / 10_000_000)` for tool execution
- **BED12 format** for native bundle building; strip extras before bedToBigBed

### Error Handling
- Domain errors use typed enums (not `NSError` or string messages)
- All errors include actionable context (what failed, why, what to do)
- Operations Panel shows user-friendly error messages
- CLI shows detailed error with `--verbose`, concise error otherwise

### Dialog Design Standards (REQUIRED for all sheets/panels)

All tool dialogs MUST follow this template. The reference implementation is
`ClassificationWizardSheet.swift` (Kraken2 dialog). Copy its structure when
creating new dialogs for read mappers, assemblers, or any other tool.

```
┌─────────────────────────────────────────────┐
│ [K]  Tool Name                  DatasetName │  ← 20px padding, 16px top
│      One-line subtitle                      │     Icon + headline + caption
├─────────────────────────────────────────────┤
│                                             │
│ Section Header                              │  ← 20px horizontal, 16px spacing
│ [Control]                                   │
│ Helper text                                 │
│                                             │
│ ─────────────────────────────────           │
│                                             │
│ Section Header                              │
│ [Control]                                   │
│                                             │
│ ─────────────────────────────────           │
│                                             │
│ ▶ Advanced Settings (disclosure, collapsed) │
│                                             │
├─────────────────────────────────────────────┤
│                       [Cancel]  [[Run]]     │  ← 20px padding, 12px vertical
└─────────────────────────────────────────────┘
```

**Header pattern** (every dialog):
```swift
HStack(spacing: 10) {
    Image(systemName: "k.circle")          // Tool letter icon
        .font(.system(size: 20))
        .foregroundStyle(Color.accentColor)
    VStack(alignment: .leading, spacing: 2) {
        Text("Kraken2 Classification")     // Tool identity — .headline
            .font(.headline)
        Text("One-line description")       // Subtitle — .caption, .secondary
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    Spacer()
    Text(datasetDisplayName)               // Dataset name (NOT "preview.fastq")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

**Rules:**
- **Presentation**: Always `NSPanel` + `NSHostingController` + `window.beginSheet()`. NEVER `runModal()`.
- **Sizing**: Width 480–520px. Height 400–520px. Do NOT use 680px+ — dialogs must be compact.
- **Tool identity**: Every dialog header shows the tool's letter icon (`k.circle`, `e.circle`, `t.circle`, or equivalent for new tools like `b.circle` for BWA) + tool name as headline + one-line subtitle.
- **Dataset display name**: Show the bundle/dataset name (e.g., "SRR35520572"), NEVER "preview.fastq". Use `url.deletingPathExtension().lastPathComponent` to strip `.lungfishfastq`.
- **Sections**: Separated by `Divider()`, each with a section header label.
- **Advanced settings**: Behind `DisclosureGroup("Advanced Settings")` — collapsed by default.
- **Buttons**: `Cancel` = `.keyboardShortcut(.cancelAction)`. `Run` = `.keyboardShortcut(.defaultAction)` + `.borderedProminent`. All operation buttons use title "Run".
- **Validation**: `Run` button disabled when required fields are empty or invalid.
- **Batch awareness**: When multiple samples are selected, show count (e.g., "3 samples") instead of single dataset name.
- **Instant display**: Dialogs MUST appear immediately when the user clicks Run. Long operations (FASTQ materialization, tool execution) happen AFTER the dialog closes, as the first pipeline step. NEVER block dialog display on I/O.

**The Dev Lead and GUI Lead agents MUST** enforce this template on every new or modified dialog. Existing dialogs (EsViritu, TaxTriage) should be migrated to match when next modified.

### Test Organization
```
Tests/
  Fixtures/                     — Shared test data (SARS-CoV-2 dataset, ~85 KB)
    sarscov2/                   — FASTA, FASTQ, BAM, VCF, BED, GFF3, GTF
    README.md                   — Format inventory and usage guide
  LungfishCoreTests/            — Data model and service tests
  LungfishIOTests/              — Format parsing tests (simulated data)
  LungfishUITests/              — Renderer and component tests
  LungfishPluginTests/          — Plugin lifecycle tests
  LungfishWorkflowTests/        — Pipeline and provenance tests
  LungfishAppTests/             — Integration tests
  LungfishCLITests/             — CLI command tests
  LungfishIntegrationTests/     — Cross-module workflow tests + functional fixture tests
    TestFixtures.swift          — Type-safe fixture accessors
    FunctionalFixtureTests.swift — Format parsing regression tests (10 tests)
```

---

## Expert Team Assembly Guide

### For Bug Fixes
Minimum: Swift expert + domain expert + QA + adversarial code reviewer

### For New Operations/Pipelines
Full: Bioinformatics + Genomics + Swift + Database + Concurrency + Adversarial Code + Adversarial Science + Simplification + CLI Parity

### For Format Handling
Minimum: Bioinformatics + Formats + Swift + Adversarial Code + Adversarial Science (bioinformatician) + CLI Parity

### For Architecture Changes
Full: Swift + macOS + Concurrency + Adversarial Code + Simplification + all affected domain experts

### For Visualization of Scientific Data
Full: Adversarial Science (both bioinformatician + biologist) + UX + domain experts + QA
