# Role: PrimalScheme Expert

## Responsibilities

### Primary Duties
- Implement PrimalScheme tiled amplicon design
- Build multiplex primer pool optimization
- Create visual panel layout display
- Design gap analysis and coverage metrics
- Develop panel export formats (BED, TSV)

### Key Deliverables
- PrimalScheme algorithm implementation
- Pool balancing optimizer
- Coverage visualization component
- Inter-pool dimer checking
- ARTIC-compatible export formats

### Decision Authority
- Tiling algorithm parameters
- Pool optimization strategy
- Coverage threshold criteria
- Export format specifications

---

## Technical Scope

### Technologies/Frameworks Owned
- Tiled amplicon algorithms
- Primer pool optimization
- Coverage analysis
- Overlap region calculation

### Component Ownership
```
LungfishCore/
├── PrimalScheme/
│   ├── TilingEngine.swift            # PRIMARY OWNER
│   ├── PoolOptimizer.swift           # PRIMARY OWNER
│   ├── CoverageAnalyzer.swift        # PRIMARY OWNER
│   ├── OverlapCalculator.swift       # PRIMARY OWNER
│   └── PanelExporter.swift           # PRIMARY OWNER
LungfishApp/
├── Views/
│   ├── PrimalScheme/
│   │   ├── PanelDesignView.swift     # PRIMARY OWNER
│   │   ├── TilingVisualization.swift # PRIMARY OWNER
│   │   ├── PoolBalanceView.swift     # PRIMARY OWNER
│   │   └── CoverageMapView.swift     # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| Primer Design Lead | Primer3 integration |
| PCR Simulation Specialist | Amplicon validation |
| Sequence Viewer Specialist | Primer position display |
| Workflow Integration Lead | ARTIC pipeline export |

---

## Key Decisions to Make

### Architectural Choices

1. **Tiling Strategy**
   - Fixed amplicon size vs. adaptive
   - Recommendation: Adaptive with target size preference

2. **Pool Assignment**
   - Greedy vs. optimal assignment
   - Recommendation: Greedy with local optimization

3. **Overlap Handling**
   - Minimum overlap vs. flexible
   - Recommendation: Configurable minimum (default 50bp)

4. **Variant Avoidance**
   - Static variant sites vs. VCF integration
   - Recommendation: Optional VCF input for variant masking

### PrimalScheme Parameters
```swift
public struct PrimalSchemeOptions: Codable {
    // Amplicon design
    public var targetAmpliconSize: Int = 400
    public var ampliconSizeRange: ClosedRange<Int> = 350...500
    public var minOverlap: Int = 50

    // Pool configuration
    public var poolCount: Int = 2
    public var maxPrimersPerPool: Int = 50

    // Primer constraints (inherits from Primer3Options)
    public var primerOptions: Primer3Options = Primer3Options()

    // Variant handling
    public var avoidVariantSites: Bool = true
    public var variantVCF: URL?
    public var minVariantDistance: Int = 5  // bp from primer 3' end

    // Coverage requirements
    public var minCoverage: Double = 0.98  // 98% of target region
    public var allowGaps: Bool = true
    public var maxGapSize: Int = 50

    // Quality thresholds
    public var maxDimerDeltaG: Double = -9.0  // kcal/mol
    public var maxHairpinDeltaG: Double = -2.0
}
```

---

## Success Criteria

### Performance Targets
- Panel design (10kb region): < 30 seconds
- Pool optimization: < 5 seconds
- Coverage analysis: < 1 second
- Dimer checking (full panel): < 10 seconds

### Quality Metrics
- Coverage ≥ target (default 98%)
- No overlapping primers within same pool
- Inter-pool dimers below threshold
- Balanced primer counts across pools

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 4 | Tiling engine | Week 10 |
| 5 | Pool optimizer | Week 11 |
| 5 | Coverage analyzer | Week 12 |
| 5 | Panel visualization | Week 13 |
| 6 | ARTIC export | Week 14 |

---

## Reference Materials

### PrimalScheme Documentation
- [PrimalScheme GitHub](https://github.com/aresti/primalscheme)
- [PrimalScheme Paper](https://doi.org/10.1101/2020.11.02.365494)

### ARTIC Network
- [ARTIC Protocol](https://artic.network/ncov-2019)
- [ARTIC Primer Schemes](https://github.com/artic-network/primer-schemes)

### Algorithm References
- Tiled amplicon PCR methodology
- Multiplex PCR optimization strategies

---

## Technical Specifications

### Tiling Engine
```swift
public struct TilingEngine {
    public struct TilingResult {
        public let amplicons: [TiledAmplicon]
        public let coverage: Double
        public let gaps: [GenomicRegion]
        public let overlaps: [OverlapRegion]
    }

    public struct TiledAmplicon {
        public let index: Int
        public let pool: Int
        public let region: GenomicRegion
        public let primers: PrimerPair
        public let overlap: OverlapRegion?
    }

    public func tile(
        target: GenomicRegion,
        reference: Sequence,
        options: PrimalSchemeOptions
    ) async throws -> TilingResult {
        var amplicons: [TiledAmplicon] = []
        var currentPosition = target.start

        // Phase 1: Generate candidate amplicons
        while currentPosition < target.end {
            let candidateRegion = GenomicRegion(
                chromosome: target.chromosome,
                start: currentPosition,
                end: min(currentPosition + options.targetAmpliconSize, target.end)
            )

            // Design primers for this region
            let primers = try await designPrimers(
                for: candidateRegion,
                reference: reference,
                options: options
            )

            if let bestPair = primers.first {
                let amplicon = TiledAmplicon(
                    index: amplicons.count,
                    pool: amplicons.count % options.poolCount,
                    region: candidateRegion,
                    primers: bestPair,
                    overlap: nil
                )
                amplicons.append(amplicon)

                // Move position, accounting for overlap
                currentPosition = candidateRegion.end - options.minOverlap
            } else {
                // Handle gap - try shorter amplicon or mark gap
                currentPosition += 50  // Skip problematic region
            }
        }

        // Phase 2: Optimize pool assignments
        let optimized = optimizePools(amplicons: amplicons, options: options)

        // Phase 3: Calculate coverage and gaps
        let coverage = calculateCoverage(amplicons: optimized, target: target)
        let gaps = findGaps(amplicons: optimized, target: target)
        let overlaps = calculateOverlaps(amplicons: optimized)

        return TilingResult(
            amplicons: optimized,
            coverage: coverage,
            gaps: gaps,
            overlaps: overlaps
        )
    }
}
```

### Pool Optimizer
```swift
public struct PoolOptimizer {
    public struct OptimizationResult {
        public let pools: [[TiledAmplicon]]
        public let interactions: [InterPoolInteraction]
        public let score: Double
    }

    public struct InterPoolInteraction {
        public let amplicon1: Int
        public let amplicon2: Int
        public let type: InteractionType
        public let severity: Double

        public enum InteractionType {
            case overlap          // Same genomic region
            case primerDimer      // Primers form dimers
            case competitiveBinding  // Similar binding sites
        }
    }

    public func optimize(
        amplicons: [TiledAmplicon],
        poolCount: Int,
        options: PrimalSchemeOptions
    ) -> OptimizationResult {
        var pools: [[TiledAmplicon]] = Array(repeating: [], count: poolCount)
        var interactions: [InterPoolInteraction] = []

        // Sort by position for consistent assignment
        let sorted = amplicons.sorted { $0.region.start < $1.region.start }

        // Assign to pools using alternating pattern
        for (index, amplicon) in sorted.enumerated() {
            let poolIndex = index % poolCount
            pools[poolIndex].append(amplicon)
        }

        // Check for conflicts within pools
        for poolIndex in 0..<poolCount {
            let poolAmplicons = pools[poolIndex]
            for i in 0..<poolAmplicons.count {
                for j in (i+1)..<poolAmplicons.count {
                    if let interaction = checkInteraction(
                        poolAmplicons[i],
                        poolAmplicons[j],
                        threshold: options.maxDimerDeltaG
                    ) {
                        interactions.append(interaction)
                    }
                }
            }
        }

        // Local optimization to resolve conflicts
        if !interactions.isEmpty {
            pools = resolveConflicts(pools: pools, interactions: interactions)
        }

        return OptimizationResult(
            pools: pools,
            interactions: interactions,
            score: calculatePoolScore(pools: pools)
        )
    }
}
```

### Panel Exporter
```swift
public struct PanelExporter {
    public enum ExportFormat {
        case bed           // Primer positions only
        case tsvFull       // Complete primer information
        case artic         // ARTIC-compatible format
        case json          // Machine-readable
    }

    public func export(
        result: TilingEngine.TilingResult,
        format: ExportFormat,
        to url: URL
    ) throws {
        switch format {
        case .bed:
            try exportBED(result: result, to: url)
        case .tsvFull:
            try exportTSV(result: result, to: url)
        case .artic:
            try exportARTIC(result: result, to: url)
        case .json:
            try exportJSON(result: result, to: url)
        }
    }

    private func exportARTIC(result: TilingEngine.TilingResult, to url: URL) throws {
        // ARTIC format: name, pool, sequence, length
        var lines: [String] = []
        lines.append("name\tpool\tseq\tlength")

        for amplicon in result.amplicons {
            let fwdName = "\(amplicon.region.chromosome)_\(amplicon.index)_LEFT"
            let revName = "\(amplicon.region.chromosome)_\(amplicon.index)_RIGHT"

            lines.append("\(fwdName)\t\(amplicon.pool + 1)\t\(amplicon.primers.forward)\t\(amplicon.primers.forward.count)")
            lines.append("\(revName)\t\(amplicon.pool + 1)\t\(amplicon.primers.reverse)\t\(amplicon.primers.reverse.count)")
        }

        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
```

### Coverage Visualization
```swift
public struct CoverageMapView: View {
    public let result: TilingEngine.TilingResult
    public let target: GenomicRegion
    @State private var selectedAmplicon: Int?

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Coverage track
            GeometryReader { geometry in
                Canvas { context, size in
                    let scale = size.width / CGFloat(target.length)

                    // Draw amplicons by pool
                    for (poolIndex, color) in zip(0..<2, [Color.blue, Color.orange]) {
                        let poolAmplicons = result.amplicons.filter { $0.pool == poolIndex }
                        let y = CGFloat(poolIndex) * 30 + 10

                        for amplicon in poolAmplicons {
                            let x = CGFloat(amplicon.region.start - target.start) * scale
                            let width = CGFloat(amplicon.region.length) * scale
                            let rect = CGRect(x: x, y: y, width: width, height: 20)

                            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(0.7)))
                        }
                    }

                    // Draw gaps
                    for gap in result.gaps {
                        let x = CGFloat(gap.start - target.start) * scale
                        let width = CGFloat(gap.length) * scale
                        let rect = CGRect(x: x, y: 35, width: width, height: 10)
                        context.fill(Path(rect), with: .color(.red.opacity(0.5)))
                    }
                }
            }
            .frame(height: 80)

            // Statistics
            HStack {
                StatLabel(title: "Coverage", value: String(format: "%.1f%%", result.coverage * 100))
                StatLabel(title: "Amplicons", value: "\(result.amplicons.count)")
                StatLabel(title: "Gaps", value: "\(result.gaps.count)")
                StatLabel(title: "Pool 1", value: "\(result.amplicons.filter { $0.pool == 0 }.count)")
                StatLabel(title: "Pool 2", value: "\(result.amplicons.filter { $0.pool == 1 }.count)")
            }
        }
    }
}
```
