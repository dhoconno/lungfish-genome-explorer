# CLI System Proposal for Lungfish Genome Explorer

**Document ID:** DESIGN-004-CLI-SYSTEM
**Date:** 2026-02-03
**Status:** Expert Review Complete - Awaiting Decision
**Authors:** Architecture Team, CLI/UX Design Team, Implementation Team

---

## Executive Summary

This document evaluates the proposal to add a Command-Line Interface (CLI) to the Lungfish Genome Explorer. After comprehensive analysis by expert teams, the recommendation is **strongly favorable** due to the exceptional existing architecture that makes CLI implementation primarily an integration task rather than a refactoring project.

**Key Finding:** The `LungfishWorkflow` module already has **zero GUI coupling** and is fully headless-capable with actor-based state management, AsyncStream for output, and Sendable progress callbacks.

**Estimated Effort:** 2-3 weeks (reduced from 4-6 weeks due to excellent architecture)

**Container Runtime:** Apple Containerization framework exclusively (macOS 26+). All standard OCI/Docker images work natively with Apple Containers - no Docker Desktop or external dependencies required.

---

## 1. Current State Analysis

### 1.1 Existing CLI Infrastructure

| Component | Status |
|-----------|--------|
| ArgumentParser v1.3.0 | Declared as dependency but **unused** |
| CLI launch arguments | Only `--test-folder` and `--skip-welcome` exist |
| Entry point | Pure AppKit GUI (`NSApplication.run()`) |
| Headless mode | Not available |

### 1.2 Architecture Readiness Assessment

| Module | GUI Coupling | CLI Readiness | Notes |
|--------|--------------|---------------|-------|
| **LungfishCore** | None | Fully headless | Models, DocumentCapability |
| **LungfishIO** | None | Fully headless | All format readers/writers |
| **LungfishWorkflow** | None | Fully headless | Container, workflow execution |
| **LungfishPlugin** | None | Fully headless | Analysis plugins |
| **LungfishUI** | AppKit/Metal | GUI-only | Visualization only |
| **LungfishApp** | AppKit | GUI-only | UI controllers |

### 1.3 Key Architectural Strengths

1. **Protocol-Based Design**
   - `ContainerRuntimeProtocol` - Abstract container interface
   - `WorkflowRunner` - Abstract workflow execution
   - `ProcessManaging` - Abstract process spawning

2. **Actor-Based Concurrency**
   - `ProcessManager` actor for subprocess management
   - `WorkflowStateMachine` for state transitions
   - Thread-safe without explicit locks

3. **Sendable Throughout**
   - `WorkflowProgressUpdate` - Progress callbacks
   - `WorkflowResult` - Execution results
   - All enums and value types

4. **AsyncStream for Output**
   - Real-time stdout/stderr streaming
   - Non-blocking progress reporting
   - GUI-agnostic output handling

---

## 2. Pros and Cons Analysis

### 2.1 PROS: Benefits of CLI Support

#### Scriptability and Automation
- **Pipeline Integration**: Integrate Lungfish into existing bioinformatics pipelines (Nextflow, Snakemake, custom scripts)
- **Batch Processing**: Process hundreds of files without manual GUI interaction
- **Reproducible Workflows**: Command-line invocations are inherently more reproducible
- **CI/CD Integration**: Automated testing and validation in continuous integration

#### Debugging Capabilities
- **Real-time Output Streaming**: Existing `ProcessHandle.standardOutput/standardError` AsyncStreams provide immediate feedback
- **Verbose Logging**: The `os.log` infrastructure enables detailed execution traces
- **Progress Callbacks**: `WorkflowProgressUpdate` structs are pure data - easily serializable to stdout
- **Exit Code Semantics**: Existing `WorkflowResult.exitCode` translates directly to shell exit codes

#### Pipeline Integration
- **nf-core Compatibility**: `NFCorePipeline` and `NFCoreRegistry` already exist
- **Container Support**: Native Apple Containerization framework (macOS 26+) for OCI images
- **Workflow Export**: `NextflowExporter` and `SnakemakeExporter` can generate pipeline definitions

#### Testing Benefits
- **Headless Testing**: Unit and integration tests run without GUI dependency
- **Faster Test Cycles**: CLI tests execute faster than GUI automation
- **Mock-friendly Architecture**: `ProcessManaging` protocol enables test doubles

#### User Accessibility
- **SSH/Remote Access**: Run analysis on remote HPC clusters without X11
- **Screen/tmux Sessions**: Long-running analyses survive disconnection
- **Documentation**: CLI usage examples are easier to document and share

#### Resource Efficiency
- **Lower Memory Footprint**: No AppKit/UI framework overhead
- **No GPU for Rendering**: Headless execution avoids Metal/Core Graphics
- **Container-Friendly**: CLI tools integrate with Apple Containerization for OCI images

### 2.2 CONS: Challenges and Risks

#### Development Effort
- New executable target required in Package.swift
- Argument Parser integration needs command structure design
- Output formatting (human-readable and JSON) design needed
- Progress display for terminal requires additional implementation

#### Maintenance Burden
- **Feature Parity Tracking**: Every new GUI feature raises "should this be in CLI?"
- **Documentation Duplication**: CLI requires separate documentation
- **Two Entry Points**: Bug fixes may need application in both paths
- **Version Synchronization**: CLI and GUI releases should stay in sync

#### Feature Parity Issues
- **Visualization**: Sequence visualization has no direct CLI equivalent
- **Interactive Features**: Selection, annotation editing have no CLI equivalent
- **Some workflows are GUI-first**: Assembly configuration, database browsers

#### User Confusion Potential
- **Discovery Problem**: Users may not know CLI exists with .app install
- **Inconsistent Behavior**: Subtle differences could confuse users
- **Learning Curve**: Users must learn both interfaces

---

## 3. Proposed Command Structure

### 3.1 Command Tree

```
lungfish
├── convert          # Format conversion operations
│   ├── fasta        # Convert to FASTA
│   ├── genbank      # Convert to GenBank
│   ├── gff3         # Convert to GFF3
│   └── detect       # Auto-detect format
│
├── workflow         # Workflow execution
│   ├── run          # Execute a workflow
│   ├── list         # List available workflows
│   ├── validate     # Validate workflow definition
│   └── status       # Check workflow status
│
├── fetch            # Remote database operations
│   ├── ncbi         # Fetch from NCBI GenBank
│   ├── search       # Search NCBI databases
│   └── batch        # Batch download accessions
│
├── analyze          # Analysis and statistics
│   ├── stats        # Sequence statistics
│   ├── validate     # Validate files
│   └── index        # Generate index files
│
└── debug            # Debugging and troubleshooting
    ├── container    # Apple Container runtime diagnostics
    ├── workflow-log # Parse and display workflow logs
    ├── env          # Environment check
    └── trace        # Execution trace analysis
```

### 3.2 Global Options

```
--output, -o     Output file (default: stdout)
--format         Output format: text, json, tsv (default: text)
--verbose, -v    Increase verbosity (can be repeated)
--quiet, -q      Suppress non-essential output
--progress       Show progress bar
--no-progress    Disable progress bar
--debug          Enable debug output
--log-file       Write logs to file
--threads, -t    Number of threads (default: auto)
--no-color       Disable colored output
```

### 3.3 Example Invocations

```bash
# Format conversion
lungfish convert fasta input.gb -o output.fa

# Workflow execution with real-time progress (uses Apple Containerization)
lungfish workflow run ./pipeline.nf \
  --param reads=./data/*.fastq.gz \
  --cpus 8 --memory 32.GB

# NCBI fetch
lungfish fetch ncbi NC_002549 --format genbank -o ebola.gb

# Sequence statistics (JSON for scripting)
lungfish analyze stats genome.fasta --format json | jq '.gcContent'

# Environment check for debugging
lungfish debug env --check-tools

# Parse workflow logs for errors
lungfish debug workflow-log ./work --errors-only
```

### 3.4 Exit Code Standards

| Code | Constant | Description |
|------|----------|-------------|
| 0 | `EXIT_SUCCESS` | Successful completion |
| 1 | `EXIT_FAILURE` | General error |
| 2 | `EXIT_USAGE` | Invalid command line usage |
| 3 | `EXIT_INPUT_ERROR` | Input file error |
| 4 | `EXIT_OUTPUT_ERROR` | Output file error |
| 5 | `EXIT_FORMAT_ERROR` | File format validation error |
| 64 | `EXIT_WORKFLOW_ERROR` | Workflow execution failed |
| 65 | `EXIT_CONTAINER_ERROR` | Container runtime error |
| 66 | `EXIT_NETWORK_ERROR` | Network/fetch error |
| 124 | `EXIT_TIMEOUT` | Operation timed out |
| 125 | `EXIT_CANCELLED` | Operation cancelled (Ctrl+C) |

---

## 4. Implementation Roadmap

### Phase 1: Foundation (3-4 days)
**Complexity:** Medium

**Create:**
- `Sources/LungfishCLI/main.swift` - Entry point
- `Sources/LungfishCLI/LungfishCLI.swift` - Root command
- `Sources/LungfishCLI/Options/GlobalOptions.swift` - Shared options
- `Sources/LungfishCLI/Output/CLIOutput.swift` - Output protocol
- `Sources/LungfishCLI/Output/TerminalFormatter.swift` - ANSI formatting

**Deliverables:**
- Working `lungfish` executable with `--help`, `--version`
- Global options infrastructure
- Output formatting infrastructure
- Test target with basic tests

### Phase 2: Format Operations (4-5 days)
**Complexity:** Medium

**Create:**
- `Sources/LungfishCLI/Commands/ConvertCommand.swift`
- `Sources/LungfishCLI/Commands/ValidateCommand.swift`
- `Sources/LungfishCLI/Commands/StatsCommand.swift`
- `Sources/LungfishCLI/Helpers/FormatDetector.swift`
- `Sources/LungfishCLI/Helpers/ProgressReporter.swift`

**Deliverables:**
- `lungfish convert` with multi-format support
- `lungfish analyze validate` with error reporting
- `lungfish analyze stats` with tabular/JSON output
- Progress reporting for large files

### Phase 3: Workflow Integration (5-7 days)
**Complexity:** High

**Create:**
- `Sources/LungfishCLI/Commands/RunCommand.swift`
- `Sources/LungfishCLI/Commands/ContainersCommand.swift`
- `Sources/LungfishCLI/Helpers/WorkflowProgressRenderer.swift`
- `Sources/LungfishCLI/Helpers/ParameterParser.swift`

**Deliverables:**
- `lungfish workflow run` with full execution via Apple Containerization
- Real-time progress display with ANSI updates
- `lungfish containers check` - verify Apple Container runtime availability
- Parameter passing via CLI and JSON files
- Resume capability, timeout support

### Phase 4: Debug & Advanced (2-3 days)
**Complexity:** Low-Medium

**Create:**
- `Sources/LungfishCLI/Commands/ToolsCommand.swift`
- `Sources/LungfishCLI/Commands/DebugCommand.swift`
- `Sources/LungfishCLI/Helpers/ToolChecker.swift`
- `Sources/LungfishCLI/Output/JSONOutput.swift`

**Deliverables:**
- `lungfish debug env` for environment checking
- Debug mode with detailed logging
- Consistent JSON output across all commands
- Structured error reporting

---

## 5. Package.swift Changes

```swift
// Add to products array:
.executable(
    name: "lungfish-cli",
    targets: ["LungfishCLI"]
)

// Add to targets array:
.executableTarget(
    name: "LungfishCLI",
    dependencies: [
        "LungfishCore",
        "LungfishIO",
        "LungfishWorkflow",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ],
    path: "Sources/LungfishCLI"
),

.testTarget(
    name: "LungfishCLITests",
    dependencies: ["LungfishCLI"],
    path: "Tests/LungfishCLITests"
),
```

---

## 6. Changes to Existing Modules

**Critical Finding:** The architecture is exceptionally well-designed. Only minimal additions needed:

| Module | Changes Required |
|--------|------------------|
| **LungfishCore** | None |
| **LungfishIO** | None (readers/writers already async/Sendable) |
| **LungfishWorkflow** | Minor: public tool version checking method |
| **LungfishPlugin** | None |
| **Package.swift** | Add LungfishCLI target |

---

## 7. Risk Assessment

### Technical Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| AsyncStream complexity in terminal | Low | Medium | Existing patterns work well |
| Cross-platform issues | Medium | High | Keep macOS-first initially |
| Memory with large files | Low | High | Streaming readers implemented |
| Progress display complexity | Medium | Low | Use existing libraries |

### Project Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Scope creep | High | Medium | Define MVP, defer visualization |
| Documentation lag | Medium | Medium | Write docs alongside code |
| User adoption | Unknown | Medium | Clear use cases, examples |

### Mitigation Strategies

1. **Start minimal**: Convert, validate, stats, single workflow run
2. **Feature flags**: Incomplete features behind `--experimental`
3. **Test from day one**: Headless nature makes this easy
4. **Share code paths**: GUI and CLI call same core methods
5. **Version together**: Ship CLI and GUI updates simultaneously

---

## 8. Effort Estimation

### Build from Scratch vs. Adapt

| Approach | Estimate | Notes |
|----------|----------|-------|
| Build from scratch | 4-6 weeks | Without existing architecture |
| **Adapt existing modules** | **1.5-2.5 weeks** | Excellent architecture reduces 60-70% |

### Timeline by Phase

| Phase | Duration | Dependencies |
|-------|----------|--------------|
| Phase 1: Foundation | 3-4 days | None |
| Phase 2: Format Operations | 4-5 days | Phase 1 |
| Phase 3: Workflow Integration | 5-7 days | Phase 1 |
| Phase 4: Debug & Advanced | 2-3 days | Phases 1-3 |
| **Total** | **14-19 days** | Single developer |

---

## 9. Recommendation

### Verdict: **STRONGLY RECOMMENDED**

The CLI system should be implemented because:

1. **Minimal effort due to excellent architecture** - The LungfishWorkflow module is already fully headless-capable
2. **High value for debugging** - Real-time output streaming already exists via AsyncStream
3. **Enables automation** - Critical for bioinformatics pipelines and batch processing
4. **Low risk** - Protocol-based design allows CLI and GUI to share code paths
5. **User demand** - SSH/HPC access is essential for genomics workflows

### Suggested Initial Scope (MVP)

Focus on highest-value commands first:

1. `lungfish convert` - Format transformation
2. `lungfish analyze stats` - Sequence statistics
3. `lungfish workflow run` - Execute Nextflow/Snakemake
4. `lungfish debug env` - Environment checking

Defer visualization-dependent features.

---

## 10. Critical Files for Implementation

1. **Package.swift** - Add LungfishCLI target
2. **Sources/LungfishWorkflow/WorkflowRunner.swift** - Core workflow protocol
3. **Sources/LungfishWorkflow/ProcessManager.swift** - Process execution actor
4. **Sources/LungfishIO/Formats/FASTAReader.swift** - Pattern for format integration
5. **Sources/LungfishPlugin/BuiltIn/SequenceStatisticsPlugin.swift** - Reusable for stats

---

## Document History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-02-03 | Initial expert analysis and design |

---

*This document was prepared by the Lungfish Architecture Team following comprehensive codebase analysis and expert consultation.*
