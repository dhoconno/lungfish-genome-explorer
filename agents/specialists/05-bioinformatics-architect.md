# Role: Bioinformatics Architect

## Responsibilities

### Primary Duties
- Define core biological data structures and algorithms
- Make strategic decisions about assembly and alignment approaches
- Ensure biological correctness of all sequence operations
- Review bioinformatics-related code from other roles
- Coordinate with domain experts (assembly, primer, alignment)

### Key Deliverables
- Core biological data models (Sequence, Annotation, etc.)
- Codon tables and translation logic
- Sequence operation implementations (complement, reverse, etc.)
- Quality metric calculations
- Biological validation rules

### Decision Authority
- Biological data structure design
- Algorithm selection for core operations
- Assembly strategy (SPAdes, MEGAHIT)
- Alignment algorithm choices
- Quality scoring methods

---

## Technical Scope

### Technologies/Frameworks Owned
- Core bioinformatics algorithms
- Sequence data structures
- Codon tables and translation
- Quality score handling

### Component Ownership
```
LungfishCore/
├── Models/
│   ├── Sequence.swift                 # PRIMARY OWNER
│   ├── SequenceAlphabet.swift         # PRIMARY OWNER
│   ├── Annotation.swift               # PRIMARY OWNER
│   ├── Alignment.swift                # PRIMARY OWNER
│   ├── Variant.swift                  # PRIMARY OWNER
│   └── QualityScore.swift             # PRIMARY OWNER
├── Translation/
│   ├── CodonTable.swift               # PRIMARY OWNER
│   ├── AminoAcidTranslator.swift      # PRIMARY OWNER
│   └── ReadingFrame.swift             # PRIMARY OWNER
├── Operations/
│   ├── SequenceOperations.swift       # PRIMARY OWNER
│   ├── ComplementOperation.swift      # PRIMARY OWNER
│   └── TranslationOperation.swift     # PRIMARY OWNER
└── Validation/
    ├── SequenceValidator.swift        # PRIMARY OWNER
    └── AnnotationValidator.swift      # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| Swift Architect | Data model design patterns |
| Assembly Specialist | Assembly algorithm selection |
| Alignment Expert | Alignment algorithm selection |
| File Format Expert | Data import/export formats |
| Primer Design Lead | Primer biology rules |

---

## Key Decisions to Make

### Architectural Choices

1. **Sequence Storage**
   - String vs. 2-bit encoding vs. compressed
   - Recommendation: 2-bit for DNA with N-mask for ambiguity codes

2. **Annotation Model**
   - Flat list vs. hierarchical (gene > mRNA > exon)
   - Recommendation: Hierarchical with parent-child relationships

3. **Quality Score Encoding**
   - Phred+33 vs. Phred+64 vs. numeric
   - Recommendation: Store as UInt8 (Phred score), convert on I/O

4. **Coordinate System**
   - 0-based half-open vs. 1-based closed
   - Recommendation: 0-based internally, convert for display/export

### Algorithm Selections

**Complement Table**
```swift
let complementTable: [Character: Character] = [
    "A": "T", "T": "A", "G": "C", "C": "G",
    "a": "t", "t": "a", "g": "c", "c": "g",
    "R": "Y", "Y": "R", "S": "S", "W": "W",
    "K": "M", "M": "K", "B": "V", "V": "B",
    "D": "H", "H": "D", "N": "N",
    "r": "y", "y": "r", "s": "s", "w": "w",
    "k": "m", "m": "k", "b": "v", "v": "b",
    "d": "h", "h": "d", "n": "n"
]
```

**Translation (Standard Genetic Code)**
```swift
// NCBI Table 1 - Standard Code
let standardCodonTable: [String: Character] = [
    "TTT": "F", "TTC": "F", "TTA": "L", "TTG": "L",
    "TCT": "S", "TCC": "S", "TCA": "S", "TCG": "S",
    "TAT": "Y", "TAC": "Y", "TAA": "*", "TAG": "*",
    "TGT": "C", "TGC": "C", "TGA": "*", "TGG": "W",
    "CTT": "L", "CTC": "L", "CTA": "L", "CTG": "L",
    "CCT": "P", "CCC": "P", "CCA": "P", "CCG": "P",
    "CAT": "H", "CAC": "H", "CAA": "Q", "CAG": "Q",
    "CGT": "R", "CGC": "R", "CGA": "R", "CGG": "R",
    "ATT": "I", "ATC": "I", "ATA": "I", "ATG": "M",
    "ACT": "T", "ACC": "T", "ACA": "T", "ACG": "T",
    "AAT": "N", "AAC": "N", "AAA": "K", "AAG": "K",
    "AGT": "S", "AGC": "S", "AGA": "R", "AGG": "R",
    "GTT": "V", "GTC": "V", "GTA": "V", "GTG": "V",
    "GCT": "A", "GCC": "A", "GCA": "A", "GCG": "A",
    "GAT": "D", "GAC": "D", "GAA": "E", "GAG": "E",
    "GGT": "G", "GGC": "G", "GGA": "G", "GGG": "G"
]
```

### Trade-off Considerations
- **Memory vs. Speed**: Compressed storage vs. fast access
- **Precision vs. Compatibility**: Extended alphabets vs. simple ACGT
- **Correctness vs. Flexibility**: Strict validation vs. permissive parsing

---

## Success Criteria

### Performance Targets
- Complement 1Mb sequence: < 10ms
- Translate 1Mb sequence: < 50ms
- 2-bit encoding overhead: < 10% vs raw string

### Quality Metrics
- 100% IUPAC ambiguity code support
- All standard codon tables implemented
- Correct handling of edge cases (partial codons, etc.)
- Round-trip accuracy for all operations

### Biological Correctness Requirements
- Complement must handle all IUPAC codes
- Translation must support alternative start codons
- Annotations must preserve strand information
- Quality scores must use correct Phred scale

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 1 | Sequence model with 2-bit encoding | Week 2 |
| 1 | Basic sequence operations | Week 3 |
| 1 | Annotation model | Week 3 |
| 2 | Full codon table support | Week 5 |
| 2 | Translation with all frames | Week 6 |
| 3 | Quality score handling | Week 8 |

---

## Reference Materials

### Geneious Code References
- `geneious-devkit/api-javadoc/com/biomatters/geneious/publicapi/documents/sequence/` - Sequence models
- `SequenceDocument` interface - Core sequence abstraction
- `SequenceAnnotation` class - Annotation model

### NCBI Resources
- [Genetic Codes](https://www.ncbi.nlm.nih.gov/Taxonomy/Utils/wprintgc.cgi) - All codon tables
- [IUPAC Codes](https://www.bioinformatics.org/sms/iupac.html) - Ambiguity codes

### File Format Specifications
- FASTA format specification
- GenBank feature table definitions
- SAM/BAM specification for CIGAR operations

---

## Technical Specifications

### Sequence Model
```swift
public struct Sequence: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let alphabet: SequenceAlphabet

    // Internal storage - 2-bit encoded for DNA/RNA
    private let storage: SequenceStorage

    // Lazy-computed properties
    public var length: Int { storage.length }
    public var gcContent: Double { computeGCContent() }

    // Efficient access
    public subscript(range: Range<Int>) -> SequenceView {
        SequenceView(storage: storage, range: range)
    }

    public func base(at position: Int) -> Character {
        storage.base(at: position)
    }

    // Operations
    public func complement() -> Sequence
    public func reverseComplement() -> Sequence
    public func translate(frame: ReadingFrame, codonTable: CodonTable) -> AminoAcidSequence?
}

public enum SequenceAlphabet: String, Codable, Sendable {
    case dna = "DNA"
    case rna = "RNA"
    case protein = "Protein"
    case unknown = "Unknown"

    var validCharacters: CharacterSet {
        switch self {
        case .dna: return CharacterSet(charactersIn: "ACGTNacgtnRYSWKMBVDH")
        case .rna: return CharacterSet(charactersIn: "ACGUNacgunRYSWKMBVDH")
        case .protein: return CharacterSet(charactersIn: "ACDEFGHIKLMNPQRSTVWY*")
        case .unknown: return CharacterSet.alphanumerics
        }
    }
}
```

### Annotation Model
```swift
public struct SequenceAnnotation: Identifiable, Codable, Sendable {
    public let id: UUID
    public var type: AnnotationType
    public var name: String
    public var intervals: [AnnotationInterval]
    public var strand: Strand
    public var qualifiers: [String: String]
    public var parentID: UUID?  // For hierarchical annotations

    // Computed properties
    public var span: Range<Int> {
        guard let first = intervals.first, let last = intervals.last else {
            return 0..<0
        }
        return first.start..<last.end
    }

    public var isDiscontinuous: Bool {
        intervals.count > 1
    }
}

public struct AnnotationInterval: Codable, Sendable {
    public let start: Int   // 0-based, inclusive
    public let end: Int     // 0-based, exclusive
    public var phase: Int?  // For CDS features (0, 1, or 2)
}

public enum Strand: String, Codable, Sendable {
    case positive = "+"
    case negative = "-"
    case none = "."
}
```

### Codon Table
```swift
public struct CodonTable: Sendable {
    public let id: Int
    public let name: String
    public let codons: [String: Character]
    public let startCodons: Set<String>
    public let stopCodons: Set<String>

    public static let standard = CodonTable(id: 1, name: "Standard", ...)
    public static let vertebrateMitochondrial = CodonTable(id: 2, ...)
    // ... all NCBI tables

    public func translate(codon: String) -> Character? {
        codons[codon.uppercased()]
    }

    public func isStartCodon(_ codon: String) -> Bool {
        startCodons.contains(codon.uppercased())
    }

    public func isStopCodon(_ codon: String) -> Bool {
        stopCodons.contains(codon.uppercased())
    }
}
```
