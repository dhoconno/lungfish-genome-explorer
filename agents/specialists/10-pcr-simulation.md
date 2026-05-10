# Role: PCR Simulation Specialist

## Responsibilities

### Primary Duties
- Implement in-silico PCR simulation
- Build amplicon prediction from primer pairs
- Create specificity checking against references
- Design multiplex PCR optimization
- Develop gel electrophoresis visualization

### Key Deliverables
- In-silico PCR algorithm
- Amplicon prediction with mismatch tolerance
- Off-target binding detection
- Multiplex reaction simulation
- Virtual gel visualization

### Decision Authority
- PCR algorithm implementation
- Mismatch tolerance parameters
- Gel visualization design
- Multiplex scoring criteria

---

## Technical Scope

### Technologies/Frameworks Owned
- In-silico PCR algorithms
- Primer binding site search
- Amplicon extraction
- Gel simulation/visualization

### Component Ownership
```
LungfishCore/
├── PCR/
│   ├── InSilicoPCR.swift              # PRIMARY OWNER
│   ├── AmpliconPredictor.swift        # PRIMARY OWNER
│   ├── BindingSiteSearch.swift        # PRIMARY OWNER
│   ├── SpecificityChecker.swift       # PRIMARY OWNER
│   └── MultiplexOptimizer.swift       # PRIMARY OWNER
LungfishApp/
├── Views/
│   ├── PCR/
│   │   ├── PCRSimulationView.swift    # PRIMARY OWNER
│   │   ├── AmpliconListView.swift     # PRIMARY OWNER
│   │   └── VirtualGelView.swift       # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| Primer Design Lead | Primer pair input |
| PrimalScheme Expert | Multiplex reactions |
| Sequence Viewer Specialist | Amplicon visualization |
| File Format Expert | Reference sequence access |

---

## Key Decisions to Make

### Architectural Choices

1. **Binding Site Search**
   - Exact match vs. fuzzy matching
   - Recommendation: Fuzzy with configurable mismatch tolerance

2. **Mismatch Handling**
   - Position-weighted penalties (3' end more critical)
   - Recommendation: Weighted scoring with 3' penalty multiplier

3. **Multiplex Simulation**
   - Independent vs. competitive amplification model
   - Recommendation: Simple independent model with interaction warnings

4. **Gel Visualization**
   - Static image vs. interactive
   - Recommendation: Interactive with adjustable parameters

### PCR Parameters
```swift
public struct PCRSimulationOptions {
    // Binding constraints
    public var maxMismatches: Int = 3
    public var max3PrimeMismatches: Int = 1
    public var minBindingLength: Int = 15

    // Amplicon constraints
    public var minAmpliconSize: Int = 50
    public var maxAmpliconSize: Int = 10000

    // Conditions
    public var annealingTemp: Double = 55.0
    public var extensionTime: Double = 60.0  // seconds
    public var cycles: Int = 30

    // Specificity
    public var checkAllChromosomes: Bool = true
    public var reportOffTargets: Bool = true
}
```

---

## Success Criteria

### Performance Targets
- Primer binding search (10Mb genome): < 5 seconds
- Amplicon prediction: < 1 second per pair
- Multiplex simulation (10 pairs): < 10 seconds
- Gel rendering: < 100ms

### Quality Metrics
- Binding site detection: > 99% sensitivity
- Amplicon size accuracy: ±0 bp
- Off-target detection: Complete for reference
- Multiplex interaction detection: All dimers > threshold

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 4 | Binding site search | Week 9 |
| 4 | Amplicon predictor | Week 10 |
| 5 | Specificity checker | Week 11 |
| 5 | Virtual gel view | Week 12 |
| 6 | Multiplex optimizer | Week 14 |

---

## Reference Materials

### Algorithm References
- isPCR (UCSC) - in-silico PCR algorithm
- Primer-BLAST methodology

### Geneious References
- In-silico PCR functionality
- Gel visualization

---

## Technical Specifications

### In-Silico PCR
```swift
public struct InSilicoPCR {
    public struct Result {
        public let amplicons: [Amplicon]
        public let offTargets: [OffTarget]
        public let warnings: [String]
    }

    public struct Amplicon {
        public let chromosome: String
        public let start: Int
        public let end: Int
        public let forwardPrimer: PrimerBinding
        public let reversePrimer: PrimerBinding
        public let sequence: Sequence
        public let size: Int
    }

    public struct PrimerBinding {
        public let position: Int
        public let strand: Strand
        public let mismatches: Int
        public let mismatchPositions: [Int]
        public let bindingEnergy: Double
    }

    public func run(
        primers: PrimerPair,
        reference: Sequence,
        options: PCRSimulationOptions
    ) -> Result {
        // Find all forward primer binding sites
        let forwardBindings = findBindingSites(
            primer: primers.forward,
            reference: reference,
            strand: .positive,
            options: options
        )

        // Find all reverse primer binding sites
        let reverseBindings = findBindingSites(
            primer: primers.reverse,
            reference: reference,
            strand: .negative,
            options: options
        )

        // Find valid amplicons (forward...reverse pairs)
        var amplicons: [Amplicon] = []
        for fwd in forwardBindings {
            for rev in reverseBindings {
                let size = rev.position - fwd.position + primers.reverse.count
                if size >= options.minAmpliconSize && size <= options.maxAmpliconSize {
                    let seq = reference.subsequence(fwd.position..<rev.position + primers.reverse.count)
                    amplicons.append(Amplicon(
                        chromosome: reference.name,
                        start: fwd.position,
                        end: rev.position + primers.reverse.count,
                        forwardPrimer: fwd,
                        reversePrimer: rev,
                        sequence: seq,
                        size: size
                    ))
                }
            }
        }

        return Result(
            amplicons: amplicons.sorted { $0.size < $1.size },
            offTargets: categorizeOffTargets(amplicons),
            warnings: generateWarnings(amplicons, options: options)
        )
    }

    private func findBindingSites(
        primer: String,
        reference: Sequence,
        strand: Strand,
        options: PCRSimulationOptions
    ) -> [PrimerBinding] {
        var bindings: [PrimerBinding] = []
        let searchSeq = strand == .positive ? primer : reverseComplement(primer)

        // Sliding window search with mismatch tolerance
        for pos in 0..<(reference.length - primer.count) {
            let (mismatches, positions) = countMismatches(
                primer: searchSeq,
                target: reference.subsequence(pos..<pos+primer.count).sequenceString
            )

            // Check 3' end mismatches
            let threePrimeMismatches = positions.filter { $0 >= primer.count - 5 }.count

            if mismatches <= options.maxMismatches &&
               threePrimeMismatches <= options.max3PrimeMismatches {
                bindings.append(PrimerBinding(
                    position: pos,
                    strand: strand,
                    mismatches: mismatches,
                    mismatchPositions: positions,
                    bindingEnergy: calculateBindingEnergy(primer: searchSeq, mismatches: mismatches)
                ))
            }
        }

        return bindings
    }
}
```

### Virtual Gel
```swift
public struct VirtualGel: View {
    public let lanes: [GelLane]
    public let ladder: DNALadder

    @State private var exposureTime: Double = 1.0
    @State private var showSizes: Bool = true

    public var body: some View {
        HStack(spacing: 0) {
            // Ladder lane
            GelLaneView(
                bands: ladder.bands,
                showSizes: showSizes,
                isLadder: true
            )

            // Sample lanes
            ForEach(lanes) { lane in
                GelLaneView(
                    bands: lane.bands,
                    showSizes: showSizes,
                    isLadder: false
                )
            }
        }
        .background(Color.black)
        .overlay(
            VStack {
                Slider(value: $exposureTime, in: 0.5...2.0)
                Toggle("Show sizes", isOn: $showSizes)
            }
            .padding()
        )
    }
}

public struct GelLane: Identifiable {
    public let id: UUID
    public let name: String
    public let bands: [GelBand]
}

public struct GelBand {
    public let size: Int           // bp
    public let intensity: Double   // 0-1
    public let yPosition: CGFloat  // calculated from log(size)

    public static func position(forSize size: Int, gelHeight: CGFloat) -> CGFloat {
        // Log scale positioning
        let minSize = 100.0
        let maxSize = 10000.0
        let logMin = log10(minSize)
        let logMax = log10(maxSize)
        let logSize = log10(Double(size))

        let normalized = (logSize - logMin) / (logMax - logMin)
        return gelHeight * (1 - normalized)  // Invert so small at bottom
    }
}

public struct DNALadder {
    public let name: String
    public let bands: [GelBand]

    public static let kb1 = DNALadder(
        name: "1 kb Ladder",
        bands: [250, 500, 750, 1000, 1500, 2000, 3000, 4000, 5000, 6000, 8000, 10000].map {
            GelBand(size: $0, intensity: $0 == 1000 || $0 == 3000 ? 1.0 : 0.7, yPosition: 0)
        }
    )
}
```

### Multiplex Optimizer
```swift
public struct MultiplexOptimizer {
    public struct OptimizationResult {
        public let pools: [[PrimerPair]]
        public let interactions: [PrimerInteraction]
        public let score: Double
    }

    public struct PrimerInteraction {
        public let primer1: String
        public let primer2: String
        public let type: InteractionType
        public let deltaG: Double

        public enum InteractionType {
            case heterodimerForward
            case heterodimerReverse
            case competitiveBinding
        }
    }

    public func optimize(
        primers: [PrimerPair],
        maxPools: Int = 2,
        maxInteractionDeltaG: Double = -9.0
    ) -> OptimizationResult {
        // Calculate all pairwise interactions
        var interactions: [PrimerInteraction] = []
        for i in 0..<primers.count {
            for j in (i+1)..<primers.count {
                interactions.append(contentsOf: checkInteractions(primers[i], primers[j]))
            }
        }

        // Greedy pool assignment to minimize interactions
        var pools: [[PrimerPair]] = Array(repeating: [], count: maxPools)

        for pair in primers {
            let bestPool = findBestPool(for: pair, pools: pools, interactions: interactions)
            pools[bestPool].append(pair)
        }

        return OptimizationResult(
            pools: pools,
            interactions: interactions.filter { $0.deltaG < maxInteractionDeltaG },
            score: calculatePoolScore(pools: pools, interactions: interactions)
        )
    }
}
```
