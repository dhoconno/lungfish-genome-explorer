# Role: Primer Design Lead

## Responsibilities

### Primary Duties
- Integrate Primer3 for primer design
- Implement Tm calculation algorithms
- Build secondary structure prediction
- Create dimer and hairpin detection
- Design primer visualization in sequence viewer

### Key Deliverables
- Primer3 wrapper with full parameter support
- Thermodynamic calculations (Tm, deltaG)
- Secondary structure analysis
- Primer binding site visualization
- Primer database/library management

### Decision Authority
- Primer3 parameter defaults
- Tm calculation method selection
- Visualization design for primers
- Primer quality scoring criteria

---

## Technical Scope

### Technologies/Frameworks Owned
- Primer3 integration
- Nearest-neighbor thermodynamics
- DNA secondary structure algorithms
- Primer binding site detection

### Component Ownership
```
LungfishCore/
├── Primers/
│   ├── Primer3Wrapper.swift           # PRIMARY OWNER
│   ├── PrimerOptions.swift            # PRIMARY OWNER
│   ├── PrimerResult.swift             # PRIMARY OWNER
│   ├── TmCalculator.swift             # PRIMARY OWNER
│   ├── SecondaryStructure.swift       # PRIMARY OWNER
│   └── DimerChecker.swift             # PRIMARY OWNER
LungfishApp/
├── Views/
│   ├── Primers/
│   │   ├── PrimerDesignView.swift     # PRIMARY OWNER
│   │   ├── PrimerOptionsPanel.swift   # PRIMARY OWNER
│   │   └── PrimerResultsTable.swift   # PRIMARY OWNER
LungfishUI/
├── Annotations/
│   └── PrimerAnnotation.swift         # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| Bioinformatics Architect | Primer data models |
| Sequence Viewer Specialist | Primer binding visualization |
| PCR Simulation Specialist | Amplicon prediction |
| PrimalScheme Expert | Multiplex primer design |

---

## Key Decisions to Make

### Architectural Choices

1. **Primer3 Integration**
   - Command-line wrapper vs. library binding
   - Recommendation: Command-line wrapper for maintainability

2. **Tm Calculation Method**
   - Basic (Wallace rule) vs. nearest-neighbor vs. SantaLucia
   - Recommendation: SantaLucia nearest-neighbor with salt correction

3. **Secondary Structure**
   - UNAFold/Mfold vs. simple hairpin detection
   - Recommendation: Simple hairpin detection native, full folding via plugin

4. **Primer Visualization**
   - Arrows vs. colored regions vs. both
   - Recommendation: Arrows with binding site highlighting

### Primer3 Options
```swift
public struct Primer3Options: Codable {
    // Size constraints
    public var primerMinSize: Int = 18
    public var primerOptSize: Int = 20
    public var primerMaxSize: Int = 25

    // Tm constraints
    public var primerMinTm: Double = 57.0
    public var primerOptTm: Double = 60.0
    public var primerMaxTm: Double = 63.0
    public var primerMaxDiffTm: Double = 3.0

    // GC constraints
    public var primerMinGC: Double = 30.0
    public var primerOptGC: Double = 50.0
    public var primerMaxGC: Double = 70.0
    public var gcClamp: Int = 1

    // Product constraints
    public var productSizeMin: Int = 100
    public var productSizeMax: Int = 300
    public var productOptSize: Int = 200

    // Thermodynamic conditions
    public var dnaNaConc: Double = 50.0       // mM
    public var dnaMgConc: Double = 1.5        // mM
    public var dnadNTPConc: Double = 0.2      // mM
    public var dnaOligoConc: Double = 250.0   // nM

    // Self-complementarity
    public var maxSelfComplementarity: Int = 8
    public var maxSelfEndComplementarity: Int = 3
    public var maxPairComplementarity: Int = 8
    public var maxPairEndComplementarity: Int = 3

    // Number of primers to return
    public var numReturn: Int = 5
}
```

---

## Success Criteria

### Performance Targets
- Primer3 design for 10kb target: < 5 seconds
- Tm calculation: < 1ms per primer
- Dimer checking: < 10ms per pair
- Hairpin detection: < 5ms per primer

### Quality Metrics
- Primer3 output parsing accuracy: 100%
- Tm calculation within 0.5°C of Primer3
- Dimer detection sensitivity: > 95%
- Hairpin detection: deltaG threshold configurable

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 4 | Primer3 wrapper | Week 8 |
| 4 | Tm calculator | Week 9 |
| 4 | Primer options UI | Week 9 |
| 4 | Dimer checker | Week 10 |
| 5 | Hairpin detection | Week 11 |
| 5 | Primer visualization | Week 12 |

---

## Reference Materials

### Primer3 Documentation
- [Primer3 Manual](https://primer3.org/manual.html)
- [Primer3 Input Tags](https://primer3.org/manual.html#inputTags)

### Thermodynamics
- SantaLucia J. (1998) Nearest-neighbor thermodynamics
- Owczarzy R. (2008) Salt correction for Tm

### Geneious References
- Primer design workflow
- Tm calculation options

---

## Technical Specifications

### Primer3 Wrapper
```swift
public final class Primer3Wrapper {
    private let executablePath: URL

    public init(path: URL = URL(fileURLWithPath: "/usr/local/bin/primer3_core")) {
        self.executablePath = path
    }

    public func design(
        template: Sequence,
        target: Range<Int>?,
        options: Primer3Options
    ) async throws -> [PrimerPair] {
        let input = buildInput(template: template, target: target, options: options)
        let output = try await runPrimer3(input: input)
        return parsePrimerOutput(output)
    }

    private func buildInput(
        template: Sequence,
        target: Range<Int>?,
        options: Primer3Options
    ) -> String {
        var lines: [String] = []

        lines.append("SEQUENCE_ID=\(template.name)")
        lines.append("SEQUENCE_TEMPLATE=\(template.sequenceString)")

        if let target = target {
            lines.append("SEQUENCE_TARGET=\(target.lowerBound),\(target.count)")
        }

        lines.append("PRIMER_TASK=generic")
        lines.append("PRIMER_PICK_LEFT_PRIMER=1")
        lines.append("PRIMER_PICK_RIGHT_PRIMER=1")
        lines.append("PRIMER_OPT_SIZE=\(options.primerOptSize)")
        lines.append("PRIMER_MIN_SIZE=\(options.primerMinSize)")
        lines.append("PRIMER_MAX_SIZE=\(options.primerMaxSize)")
        lines.append("PRIMER_OPT_TM=\(options.primerOptTm)")
        lines.append("PRIMER_MIN_TM=\(options.primerMinTm)")
        lines.append("PRIMER_MAX_TM=\(options.primerMaxTm)")
        lines.append("PRIMER_MAX_DIFF_TM=\(options.primerMaxDiffTm)")
        lines.append("PRIMER_MIN_GC=\(options.primerMinGC)")
        lines.append("PRIMER_MAX_GC=\(options.primerMaxGC)")
        lines.append("PRIMER_PRODUCT_SIZE_RANGE=\(options.productSizeMin)-\(options.productSizeMax)")
        lines.append("PRIMER_NUM_RETURN=\(options.numReturn)")
        lines.append("PRIMER_DNA_CONC=\(options.dnaOligoConc)")
        lines.append("PRIMER_SALT_MONOVALENT=\(options.dnaNaConc)")
        lines.append("PRIMER_SALT_DIVALENT=\(options.dnaMgConc)")
        lines.append("=")  // End of record

        return lines.joined(separator: "\n")
    }
}
```

### Tm Calculator
```swift
public struct TmCalculator {
    public enum Method {
        case wallace       // 4*(G+C) + 2*(A+T)
        case nearestNeighbor
        case santaLucia    // With salt correction
    }

    public struct Conditions {
        public var naConc: Double = 50.0     // mM
        public var mgConc: Double = 1.5      // mM
        public var dntpConc: Double = 0.2    // mM
        public var oligoConc: Double = 250.0 // nM
    }

    public func calculate(
        sequence: String,
        method: Method = .santaLucia,
        conditions: Conditions = Conditions()
    ) -> Double {
        switch method {
        case .wallace:
            return wallaceRule(sequence: sequence)

        case .nearestNeighbor, .santaLucia:
            return santaLuciaTm(sequence: sequence, conditions: conditions)
        }
    }

    private func santaLuciaTm(sequence: String, conditions: Conditions) -> Double {
        // Nearest-neighbor thermodynamic parameters (SantaLucia 1998)
        let nn = NearestNeighborParams.santaLucia98

        var deltaH: Double = 0
        var deltaS: Double = 0

        // Sum nearest-neighbor contributions
        for i in 0..<(sequence.count - 1) {
            let dinuc = String(sequence[sequence.index(sequence.startIndex, offsetBy: i)...sequence.index(sequence.startIndex, offsetBy: i+1)])
            if let params = nn.params[dinuc.uppercased()] {
                deltaH += params.deltaH
                deltaS += params.deltaS
            }
        }

        // Initiation parameters
        deltaH += nn.initAT + nn.initGC
        deltaS += nn.initATEntropy + nn.initGCEntropy

        // Salt correction (Owczarzy 2008)
        let saltCorrection = saltCorrectionFactor(conditions: conditions, gcFraction: gcContent(sequence))

        // Calculate Tm
        let R = 1.987  // Gas constant
        let Ct = conditions.oligoConc * 1e-9  // Convert to M
        let tm = (deltaH * 1000) / (deltaS + R * log(Ct / 4)) - 273.15

        return tm + saltCorrection
    }
}
```

### Dimer Checker
```swift
public struct DimerChecker {
    public struct DimerResult {
        public let score: Int           // Complementarity score
        public let deltaG: Double       // Free energy
        public let position: (Int, Int) // Alignment positions
        public let isEndDimer: Bool     // 3' end involvement
    }

    public func checkSelfDimer(sequence: String) -> [DimerResult] {
        let revComp = reverseComplement(sequence)
        return findComplementaryRegions(seq1: sequence, seq2: revComp)
    }

    public func checkPairDimer(primer1: String, primer2: String) -> [DimerResult] {
        let revComp2 = reverseComplement(primer2)
        return findComplementaryRegions(seq1: primer1, seq2: revComp2)
    }

    public func checkHairpin(sequence: String, minLoop: Int = 3) -> [HairpinResult] {
        var hairpins: [HairpinResult] = []

        // Scan for complementary regions with minimum loop
        for stemLength in (4...sequence.count/2).reversed() {
            for pos in 0..<(sequence.count - 2*stemLength - minLoop) {
                let leftStem = String(sequence[pos..<pos+stemLength])
                let rightStart = pos + stemLength + minLoop
                let rightStem = reverseComplement(String(sequence[rightStart..<rightStart+stemLength]))

                if leftStem == rightStem {
                    let loopSeq = String(sequence[(pos+stemLength)..<rightStart])
                    let deltaG = calculateHairpinDeltaG(stem: leftStem, loop: loopSeq)
                    hairpins.append(HairpinResult(
                        position: pos,
                        stemLength: stemLength,
                        loopLength: minLoop,
                        deltaG: deltaG
                    ))
                }
            }
        }

        return hairpins.sorted { $0.deltaG < $1.deltaG }
    }
}
```
