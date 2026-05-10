# Role: Alignment & Mapping Expert

## Responsibilities

### Primary Duties
- Implement read mapping functionality (wrapper for external tools)
- Build multiple sequence alignment interface
- Create pairwise alignment algorithms
- Design alignment visualization components
- Develop alignment editing capabilities

### Key Deliverables
- Read mapping workflow integration
- Multiple sequence alignment viewer
- Pairwise alignment algorithm library
- Alignment consensus generation
- Alignment statistics and quality metrics

### Decision Authority
- Alignment algorithm selection
- Default scoring matrices
- Gap penalty parameters
- Visualization strategies

---

## Technical Scope

### Technologies/Frameworks Owned
- Alignment algorithms (Smith-Waterman, Needleman-Wunsch)
- CIGAR string parsing and manipulation
- Scoring matrices (BLOSUM, PAM, NUC44)
- Consensus sequence generation

### Component Ownership
```
LungfishCore/
├── Alignment/
│   ├── PairwiseAligner.swift          # PRIMARY OWNER
│   ├── SmithWaterman.swift            # PRIMARY OWNER
│   ├── NeedlemanWunsch.swift          # PRIMARY OWNER
│   ├── ScoringMatrix.swift            # PRIMARY OWNER
│   ├── CIGAR.swift                    # PRIMARY OWNER
│   ├── ConsensusBuilder.swift         # PRIMARY OWNER
│   └── AlignmentStatistics.swift      # PRIMARY OWNER
├── Mapping/
│   ├── ReadMapper.swift               # PRIMARY OWNER - Protocol
│   ├── MiniMap2Wrapper.swift          # PRIMARY OWNER
│   └── BWAWrapper.swift               # PRIMARY OWNER
LungfishUI/
├── Tracks/
│   └── AlignmentTrack.swift           # CO-OWNER with Track Engineer
├── Views/
│   └── Alignment/
│       ├── MSAViewer.swift            # PRIMARY OWNER
│       └── AlignmentEditor.swift      # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| Bioinformatics Architect | Alignment data models |
| Track Rendering Engineer | Alignment track display |
| File Format Expert | BAM/SAM handling |
| Workflow Integration Lead | External tool execution |

---

## Key Decisions to Make

### Architectural Choices

1. **Pairwise Alignment**
   - Native Swift vs. wrapper around existing tools
   - Recommendation: Native Swift for small sequences, Rust plugin for large

2. **Multiple Sequence Alignment**
   - Integrate MUSCLE/ClustalO vs. implement progressive alignment
   - Recommendation: Wrapper for MUSCLE with optional ClustalO

3. **Read Mapping**
   - Minimap2 vs. BWA-MEM2 vs. both
   - Recommendation: Minimap2 primary (fast, versatile)

4. **Visualization Mode**
   - Full sequence display vs. diff-only view
   - Recommendation: Both modes, user-selectable

### Algorithm Parameters

**Scoring Matrices**
```swift
public struct ScoringMatrix {
    public static let nuc44 = ScoringMatrix(
        match: 5,
        mismatch: -4,
        transitions: -4,
        transversions: -4
    )

    public static let blosum62 = ScoringMatrix(
        matrix: loadBLOSUM62()
    )
}

public struct GapPenalties {
    public var open: Int = -10
    public var extend: Int = -1

    public static let standard = GapPenalties(open: -10, extend: -1)
    public static let affine = GapPenalties(open: -12, extend: -2)
}
```

**CIGAR Operations**
```swift
public enum CIGAROperation: Character {
    case match = "M"
    case insertion = "I"
    case deletion = "D"
    case skip = "N"
    case softClip = "S"
    case hardClip = "H"
    case padding = "P"
    case sequenceMatch = "="
    case mismatch = "X"

    var consumesReference: Bool {
        switch self {
        case .match, .deletion, .skip, .sequenceMatch, .mismatch:
            return true
        default:
            return false
        }
    }

    var consumesQuery: Bool {
        switch self {
        case .match, .insertion, .softClip, .sequenceMatch, .mismatch:
            return true
        default:
            return false
        }
    }
}
```

---

## Success Criteria

### Performance Targets
- Pairwise alignment (1kb x 1kb): < 100ms
- CIGAR parsing: < 1ms per read
- Consensus generation: < 10ms per kb
- MSA display update: < 16ms (60 fps)

### Quality Metrics
- Optimal alignment guarantee for Smith-Waterman
- CIGAR validation on parse
- Consensus quality scores
- Alignment identity calculation

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 1 | CIGAR parser | Week 3 |
| 2 | Pairwise alignment (SW, NW) | Week 5 |
| 2 | Scoring matrices | Week 5 |
| 3 | Consensus builder | Week 7 |
| 4 | MSA viewer | Week 9 |
| 5 | Read mapper integration | Week 11 |

---

## Reference Materials

### IGV Code References
- `igv/src/main/java/org/igv/sam/AlignmentBlock.java` - Alignment blocks
- `igv/src/main/java/org/igv/sam/AlignmentRenderer.java` - Rendering
- `igv/src/main/java/org/igv/sam/AlignmentPacker.java` - Row packing

### Geneious References
- Alignment viewer functionality
- Consensus sequence generation
- Multiple sequence alignment display

### External Tools
- [Minimap2](https://github.com/lh3/minimap2)
- [BWA-MEM2](https://github.com/bwa-mem2/bwa-mem2)
- [MUSCLE](https://www.drive5.com/muscle/)

---

## Technical Specifications

### Pairwise Aligner
```swift
public struct PairwiseAligner {
    public enum Algorithm {
        case global     // Needleman-Wunsch
        case local      // Smith-Waterman
        case semiglobal // Free end gaps
    }

    public var algorithm: Algorithm
    public var scoringMatrix: ScoringMatrix
    public var gapPenalties: GapPenalties

    public func align(seq1: Sequence, seq2: Sequence) -> AlignmentResult {
        switch algorithm {
        case .global:
            return needlemanWunsch(seq1: seq1, seq2: seq2)
        case .local:
            return smithWaterman(seq1: seq1, seq2: seq2)
        case .semiglobal:
            return semiglobalAlign(seq1: seq1, seq2: seq2)
        }
    }

    private func smithWaterman(seq1: Sequence, seq2: Sequence) -> AlignmentResult {
        let m = seq1.length
        let n = seq2.length

        // Initialize scoring matrix
        var H = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        var maxScore = 0
        var maxPos = (0, 0)

        // Fill matrix
        for i in 1...m {
            for j in 1...n {
                let match = scoringMatrix.score(seq1.base(at: i-1), seq2.base(at: j-1))
                H[i][j] = max(
                    0,
                    H[i-1][j-1] + match,
                    H[i-1][j] + gapPenalties.extend,
                    H[i][j-1] + gapPenalties.extend
                )

                if H[i][j] > maxScore {
                    maxScore = H[i][j]
                    maxPos = (i, j)
                }
            }
        }

        // Traceback
        return traceback(H: H, seq1: seq1, seq2: seq2, start: maxPos)
    }
}
```

### CIGAR Parser
```swift
public struct CIGAR: CustomStringConvertible {
    public let operations: [CIGARElement]

    public struct CIGARElement {
        public let length: Int
        public let operation: CIGAROperation
    }

    public init(string: String) throws {
        var ops: [CIGARElement] = []
        var numberStr = ""

        for char in string {
            if char.isNumber {
                numberStr.append(char)
            } else if let op = CIGAROperation(rawValue: char) {
                guard let length = Int(numberStr) else {
                    throw CIGARError.invalidLength(numberStr)
                }
                ops.append(CIGARElement(length: length, operation: op))
                numberStr = ""
            } else {
                throw CIGARError.invalidOperation(char)
            }
        }

        self.operations = ops
    }

    public var alignedLength: Int {
        operations.filter { $0.operation.consumesReference }
            .reduce(0) { $0 + $1.length }
    }

    public var readLength: Int {
        operations.filter { $0.operation.consumesQuery }
            .reduce(0) { $0 + $1.length }
    }
}
```

### Consensus Builder
```swift
public struct ConsensusBuilder {
    public enum Method {
        case majority
        case weighted
        case iupac
    }

    public func build(
        alignedSequences: [Sequence],
        method: Method = .majority
    ) -> ConsensusResult {
        let length = alignedSequences[0].length
        var consensus = ""
        var qualities: [Double] = []

        for pos in 0..<length {
            let column = alignedSequences.map { $0.base(at: pos) }
            let (base, quality) = consensusBase(column: column, method: method)
            consensus.append(base)
            qualities.append(quality)
        }

        return ConsensusResult(
            sequence: Sequence(name: "Consensus", data: consensus),
            qualities: qualities
        )
    }

    private func consensusBase(column: [Character], method: Method) -> (Character, Double) {
        let counts = Dictionary(grouping: column, by: { $0 }).mapValues { $0.count }
        let sorted = counts.sorted { $0.value > $1.value }

        switch method {
        case .majority:
            let topBase = sorted[0].key
            let quality = Double(sorted[0].value) / Double(column.count)
            return (topBase, quality)

        case .iupac:
            // Return IUPAC ambiguity code if not unanimous
            if sorted.count > 1 && sorted[1].value > column.count / 4 {
                return (iupacCode(for: sorted.prefix(2).map { $0.key }), 0.5)
            }
            return (sorted[0].key, Double(sorted[0].value) / Double(column.count))

        case .weighted:
            // Implement quality-weighted consensus
            return (sorted[0].key, 1.0)
        }
    }
}
```
