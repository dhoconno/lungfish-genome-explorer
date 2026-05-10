# Role: Sequence Assembly Specialist

## Responsibilities

### Primary Duties
- Integrate SPAdes and MEGAHIT assemblers
- Design parameter UI with sensible defaults
- Implement assembly quality metrics
- Create contig visualization components
- Define plugin interface for additional assemblers

### Key Deliverables
- SPAdes wrapper with full parameter support
- MEGAHIT wrapper with full parameter support
- Assembly quality assessment (N50, L50, etc.)
- Contig statistics dashboard
- Assembler plugin protocol

### Decision Authority
- Default parameter values
- Assembly mode presets
- Quality metric thresholds
- Plugin API design

---

## Technical Scope

### Technologies/Frameworks Owned
- Process management for external tools
- Container integration for assemblers
- Assembly graph representation
- Quality metrics calculation

### Component Ownership
```
LungfishCore/
├── Assembly/
│   ├── Assembler.swift                # PRIMARY OWNER - Protocol
│   ├── SPAdesAssembler.swift          # PRIMARY OWNER
│   ├── MEGAHITAssembler.swift         # PRIMARY OWNER
│   ├── AssemblyOptions.swift          # PRIMARY OWNER
│   ├── AssemblyResult.swift           # PRIMARY OWNER
│   └── AssemblyMetrics.swift          # PRIMARY OWNER
LungfishApp/
├── Views/
│   ├── Assembly/
│   │   ├── AssemblyOptionsView.swift  # PRIMARY OWNER
│   │   ├── AssemblyProgressView.swift # PRIMARY OWNER
│   │   └── ContigStatsView.swift      # PRIMARY OWNER
LungfishPlugin/
├── Protocols/
│   └── AssemblerPlugin.swift          # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| Bioinformatics Architect | Contig data models |
| Workflow Integration Lead | Container execution |
| Plugin Architect | Assembler plugin protocol |
| UI/UX Lead | Parameter UI design |

---

## Key Decisions to Make

### Architectural Choices

1. **Assembler Installation**
   - Bundled binaries vs. Docker containers vs. user-installed
   - Recommendation: Docker primary, native fallback for ARM64 builds

2. **Parameter Presets**
   - Define preset configurations for common use cases
   - Recommendation: Draft (fast), Careful (accurate), Meta (metagenomics)

3. **Progress Monitoring**
   - Log parsing vs. checkpoint files vs. estimated progress
   - Recommendation: Log parsing with stage detection

4. **Output Handling**
   - Import all outputs vs. select contigs only
   - Recommendation: Import contigs with optional scaffolds and graphs

### SPAdes Parameter Reference
```swift
struct SPAdesOptions: Codable {
    // K-mer sizes
    var kmerSizes: [Int] = []  // Empty = auto-detect
    var autoKmer: Bool = true

    // Modes
    var carefulMode: Bool = true        // --careful
    var metaMode: Bool = false          // --meta
    var plasmidMode: Bool = false       // --plasmid
    var rnaMode: Bool = false           // --rna
    var isolateMode: Bool = false       // --isolate
    var onlyAssembler: Bool = false     // --only-assembler

    // Coverage
    var coverageCutoff: CoverageCutoff = .auto

    // Resources
    var threads: Int = ProcessInfo.processInfo.activeProcessorCount
    var memoryLimitGB: Int = 16

    // Output
    var outputDirectory: URL?
}

enum CoverageCutoff: Codable {
    case auto
    case off
    case value(Double)
}
```

### MEGAHIT Parameter Reference
```swift
struct MEGAHITOptions: Codable {
    // K-mer range
    var kMin: Int = 21
    var kMax: Int = 141
    var kStep: Int = 12

    // Filtering
    var minContigLen: Int = 200
    var minCount: Int = 2

    // Cleaning
    var precutEnabled: Bool = true
    var precutKmer: Int = 21
    var precutTarget: Int = 4

    // Resources
    var threads: Int = ProcessInfo.processInfo.activeProcessorCount
    var memoryFraction: Double = 0.9

    // Output
    var outputDirectory: URL?
    var outputPrefix: String = "megahit"
}
```

---

## Success Criteria

### Performance Targets
- Assembly parameter validation: < 100ms
- Progress update frequency: Every 5 seconds
- Contig import: < 1 second per MB
- Quality metrics calculation: < 5 seconds

### Quality Metrics to Implement

| Metric | Description |
|--------|-------------|
| N50 | Contig length where 50% of assembly is in longer contigs |
| L50 | Number of contigs comprising N50 |
| N90 | Contig length where 90% of assembly is in longer contigs |
| Total Length | Sum of all contig lengths |
| GC Content | Overall GC percentage |
| Max Contig | Length of longest contig |
| # Contigs | Total number of contigs |
| # Contigs >1kb | Contigs over 1000bp |

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 2 | SPAdes wrapper | Week 5 |
| 2 | MEGAHIT wrapper | Week 6 |
| 2 | Parameter UI | Week 6 |
| 3 | Quality metrics | Week 7 |
| 3 | Progress monitoring | Week 8 |
| 4 | Assembler plugin protocol | Week 10 |

---

## Reference Materials

### SPAdes Documentation
- [SPAdes Manual](https://github.com/ablab/spades/blob/main/README.md)
- [SPAdes Options](https://cab.spbu.ru/files/release3.15.5/manual.html)

### MEGAHIT Documentation
- [MEGAHIT GitHub](https://github.com/voutcn/megahit)
- [MEGAHIT Wiki](https://github.com/voutcn/megahit/wiki)

### Geneious References
- Assembly options in Geneious Prime
- Contig statistics display

---

## Technical Specifications

### Assembler Protocol
```swift
public protocol Assembler {
    static var name: String { get }
    static var version: String { get }
    static var isAvailable: Bool { get }

    associatedtype Options: AssemblerOptions

    func run(
        reads: [URL],
        options: Options,
        progress: ProgressReporter
    ) async throws -> AssemblyResult
}

public struct AssemblyResult {
    let contigs: [Contig]
    let scaffolds: [Scaffold]?
    let metrics: AssemblyMetrics
    let logFile: URL
    let outputDirectory: URL
}

public struct Contig: Identifiable {
    let id: UUID
    let name: String
    let sequence: Sequence
    let coverage: Double?
    let length: Int
}

public struct AssemblyMetrics: Codable {
    let n50: Int
    let l50: Int
    let n90: Int
    let totalLength: Int
    let contigCount: Int
    let maxContigLength: Int
    let gcContent: Double
    let assemblyTime: TimeInterval
}
```

### SPAdes Wrapper
```swift
public final class SPAdesAssembler: Assembler {
    public static let name = "SPAdes"
    public static var version: String { detectVersion() }
    public static var isAvailable: Bool { checkAvailability() }

    public func run(
        reads: [URL],
        options: SPAdesOptions,
        progress: ProgressReporter
    ) async throws -> AssemblyResult {
        let args = buildArguments(reads: reads, options: options)

        let container = ContainerConfig(
            runtime: .docker,
            image: "staphb/spades:3.15.5",
            volumes: [
                VolumeMount(host: reads[0].deletingLastPathComponent(), container: "/input"),
                VolumeMount(host: options.outputDirectory!, container: "/output")
            ]
        )

        let process = try await ContainerRunner.run(
            container: container,
            command: ["spades.py"] + args,
            progress: progress
        )

        return try parseOutput(directory: options.outputDirectory!)
    }

    private func buildArguments(reads: [URL], options: SPAdesOptions) -> [String] {
        var args: [String] = []

        // Input files
        if reads.count == 1 {
            args += ["-s", "/input/\(reads[0].lastPathComponent)"]
        } else {
            args += ["-1", "/input/\(reads[0].lastPathComponent)"]
            args += ["-2", "/input/\(reads[1].lastPathComponent)"]
        }

        // K-mer sizes
        if !options.autoKmer {
            args += ["-k", options.kmerSizes.map(String.init).joined(separator: ",")]
        }

        // Modes
        if options.carefulMode { args += ["--careful"] }
        if options.metaMode { args += ["--meta"] }
        if options.plasmidMode { args += ["--plasmid"] }

        // Resources
        args += ["-t", String(options.threads)]
        args += ["-m", String(options.memoryLimitGB)]

        // Output
        args += ["-o", "/output"]

        return args
    }
}
```

### Quality Metrics Calculation
```swift
struct AssemblyMetricsCalculator {
    static func calculate(contigs: [Contig]) -> AssemblyMetrics {
        let sorted = contigs.sorted { $0.length > $1.length }
        let totalLength = sorted.reduce(0) { $0 + $1.length }

        // N50/L50 calculation
        var cumulative = 0
        var n50 = 0
        var l50 = 0
        for (index, contig) in sorted.enumerated() {
            cumulative += contig.length
            if cumulative >= totalLength / 2 && n50 == 0 {
                n50 = contig.length
                l50 = index + 1
            }
        }

        // GC content
        let allBases = contigs.flatMap { $0.sequence.bases }
        let gcCount = allBases.filter { $0 == "G" || $0 == "C" }.count
        let gcContent = Double(gcCount) / Double(allBases.count)

        return AssemblyMetrics(
            n50: n50,
            l50: l50,
            n90: calculateN90(sorted: sorted, totalLength: totalLength),
            totalLength: totalLength,
            contigCount: contigs.count,
            maxContigLength: sorted.first?.length ?? 0,
            gcContent: gcContent,
            assemblyTime: 0  // Set by caller
        )
    }
}
```
