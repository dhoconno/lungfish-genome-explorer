# Role: Testing & QA Lead

## Responsibilities

### Primary Duties
- Design and maintain unit test framework
- Build integration testing infrastructure
- Create performance benchmarks
- Implement file format conformance testing
- Develop automated regression testing

### Key Deliverables
- Comprehensive unit test suite
- Integration test harness
- Performance benchmark suite
- File format test fixtures
- CI/CD pipeline configuration
- Code coverage reporting

### Decision Authority
- Testing framework selection
- Coverage requirements
- Performance baselines
- Test data management

---

## Technical Scope

### Technologies/Frameworks Owned
- XCTest framework
- Quick/Nimble (BDD testing)
- Performance testing tools
- Mock generation
- Test fixtures

### Component Ownership
```
LungfishTests/
├── Unit/
│   ├── Core/
│   │   ├── SequenceTests.swift       # PRIMARY OWNER
│   │   ├── AnnotationTests.swift     # PRIMARY OWNER
│   │   └── DiffEngineTests.swift     # PRIMARY OWNER
│   ├── IO/
│   │   ├── FASTATests.swift          # PRIMARY OWNER
│   │   ├── GenBankTests.swift        # PRIMARY OWNER
│   │   ├── BAMTests.swift            # PRIMARY OWNER
│   │   └── VCFTests.swift            # PRIMARY OWNER
│   ├── UI/
│   │   ├── SequenceViewerTests.swift # PRIMARY OWNER
│   │   └── TrackRendererTests.swift  # PRIMARY OWNER
│   └── Plugin/
│       └── PluginHostTests.swift     # PRIMARY OWNER
├── Integration/
│   ├── WorkflowTests.swift           # PRIMARY OWNER
│   ├── NCBIServiceTests.swift        # PRIMARY OWNER
│   └── ProjectTests.swift            # PRIMARY OWNER
├── Performance/
│   ├── RenderingBenchmarks.swift     # PRIMARY OWNER
│   ├── ParsingBenchmarks.swift       # PRIMARY OWNER
│   └── MemoryBenchmarks.swift        # PRIMARY OWNER
├── Fixtures/
│   ├── sequences/                    # Test FASTA/GenBank files
│   ├── alignments/                   # Test BAM/SAM files
│   └── annotations/                  # Test GFF/VCF files
└── Mocks/
    ├── MockNCBIService.swift         # PRIMARY OWNER
    ├── MockFileSystem.swift          # PRIMARY OWNER
    └── MockPluginHost.swift          # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| All roles | Unit test requirements |
| Swift Architecture Lead | Test architecture |
| Documentation Lead | Test documentation |
| CI/CD | Pipeline integration |

---

## Key Decisions to Make

### Architectural Choices

1. **Testing Framework**
   - XCTest only vs. Quick/Nimble vs. hybrid
   - Recommendation: XCTest primary, Quick for complex specs

2. **Mock Strategy**
   - Manual mocks vs. generated vs. protocol witnesses
   - Recommendation: Protocol-based dependency injection

3. **Test Data**
   - Embedded fixtures vs. generated vs. external
   - Recommendation: Embedded small, external for large files

4. **CI/CD Platform**
   - GitHub Actions vs. CircleCI vs. Xcode Cloud
   - Recommendation: GitHub Actions for flexibility

### Testing Standards
```swift
// Test naming convention
func test_<unit>_<condition>_<expectedBehavior>()

// Example
func test_sequence_reverseComplement_returnsCorrectResult()
func test_FASTAReader_malformedFile_throwsError()
func test_TileCache_memoryPressure_evictsOldestTiles()

// Performance baseline
struct PerformanceBaselines {
    static let fastaParsingMBPerSecond = 100.0
    static let bamRandomAccessMs = 50.0
    static let renderFrameMs = 16.0
    static let diffCalculationMs = 50.0
}
```

---

## Success Criteria

### Coverage Targets
- Unit test coverage: > 80%
- Integration test coverage: > 60%
- Critical path coverage: 100%

### Performance Metrics
- All benchmarks within 10% of baseline
- No memory leaks in stress tests
- No UI frame drops under normal load

### Quality Metrics
- Zero P0 bugs in production
- < 5 P1 bugs per release
- All format conformance tests passing

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 1 | Test infrastructure | Week 2 |
| 1 | Core unit tests | Week 3 |
| 2 | Format tests | Week 5 |
| 3 | Integration tests | Week 7 |
| 4 | Performance benchmarks | Week 9 |
| 5 | CI/CD pipeline | Week 11 |

---

## Reference Materials

### Apple Testing
- [XCTest Documentation](https://developer.apple.com/documentation/xctest)
- [Performance Testing](https://developer.apple.com/documentation/xctest/performance_tests)

### BDD Testing
- [Quick Framework](https://github.com/Quick/Quick)
- [Nimble Matchers](https://github.com/Quick/Nimble)

### Best Practices
- [Testing Best Practices](https://developer.apple.com/videos/play/wwdc2019/413/)

---

## Technical Specifications

### Test Base Class
```swift
import XCTest
@testable import LungfishCore
@testable import LungfishIO

class LungfishTestCase: XCTestCase {
    var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    // MARK: - Fixture Loading

    func loadFixture(_ name: String, extension ext: String) -> URL {
        Bundle(for: type(of: self))
            .url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!
    }

    func loadFixtureData(_ name: String, extension ext: String) throws -> Data {
        try Data(contentsOf: loadFixture(name, extension: ext))
    }

    func loadFixtureString(_ name: String, extension ext: String) throws -> String {
        try String(contentsOf: loadFixture(name, extension: ext))
    }

    // MARK: - Sequence Helpers

    func makeSequence(name: String = "test", bases: String) -> Sequence {
        Sequence(name: name, data: Data(bases.utf8))
    }

    func makeAnnotation(
        type: AnnotationType = .gene,
        name: String = "test",
        start: Int,
        end: Int,
        strand: Strand = .positive
    ) -> SequenceAnnotation {
        SequenceAnnotation(
            type: type,
            name: name,
            intervals: [AnnotationInterval(start: start, end: end)],
            strand: strand,
            qualifiers: [:]
        )
    }

    // MARK: - Assertions

    func assertSequencesEqual(_ seq1: Sequence, _ seq2: Sequence, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(seq1.name, seq2.name, "Names don't match", file: file, line: line)
        XCTAssertEqual(seq1.length, seq2.length, "Lengths don't match", file: file, line: line)
        XCTAssertEqual(seq1.sequenceString, seq2.sequenceString, "Sequences don't match", file: file, line: line)
    }

    func assertAnnotationsEqual(_ ann1: SequenceAnnotation, _ ann2: SequenceAnnotation, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(ann1.type, ann2.type, file: file, line: line)
        XCTAssertEqual(ann1.name, ann2.name, file: file, line: line)
        XCTAssertEqual(ann1.intervals, ann2.intervals, file: file, line: line)
        XCTAssertEqual(ann1.strand, ann2.strand, file: file, line: line)
    }
}
```

### Sequence Tests
```swift
final class SequenceTests: LungfishTestCase {
    // MARK: - Creation

    func test_sequence_creation_setsProperties() {
        let seq = makeSequence(name: "test", bases: "ATCG")

        XCTAssertEqual(seq.name, "test")
        XCTAssertEqual(seq.length, 4)
        XCTAssertEqual(seq.alphabet, .dna)
    }

    func test_sequence_emptySequence_hasZeroLength() {
        let seq = makeSequence(bases: "")
        XCTAssertEqual(seq.length, 0)
    }

    // MARK: - Complement

    func test_sequence_complement_dna_returnsCorrectResult() {
        let seq = makeSequence(bases: "ATCG")
        let comp = seq.complement()

        XCTAssertEqual(comp.sequenceString, "TAGC")
    }

    func test_sequence_reverseComplement_returnsCorrectResult() {
        let seq = makeSequence(bases: "ATCG")
        let revComp = seq.reverseComplement()

        XCTAssertEqual(revComp.sequenceString, "CGAT")
    }

    func test_sequence_complement_withAmbiguousBases_handlesCorrectly() {
        let seq = makeSequence(bases: "ATCGRYSWKMBDHVN")
        let comp = seq.complement()

        XCTAssertEqual(comp.sequenceString, "TAGCYRSWMKVHDBN")
    }

    // MARK: - Subscript

    func test_sequence_subscript_returnsCorrectSubsequence() {
        let seq = makeSequence(bases: "ATCGATCG")
        let sub = seq[2..<6]

        XCTAssertEqual(sub.sequenceString, "CGAT")
    }

    func test_sequence_subscript_emptyRange_returnsEmptySequence() {
        let seq = makeSequence(bases: "ATCG")
        let sub = seq[2..<2]

        XCTAssertEqual(sub.length, 0)
    }

    // MARK: - Translation

    func test_sequence_translate_standardCode_returnsCorrectProtein() {
        let seq = makeSequence(bases: "ATGGCCGAA")  // Met-Ala-Glu
        let protein = seq.translate(frame: .frame1, codonTable: .standard)

        XCTAssertEqual(protein?.sequenceString, "MAE")
    }

    func test_sequence_translate_stopCodon_terminatesTranslation() {
        let seq = makeSequence(bases: "ATGTAAGCC")  // Met-Stop-Ala
        let protein = seq.translate(frame: .frame1, codonTable: .standard)

        XCTAssertEqual(protein?.sequenceString, "M")
    }

    func test_sequence_translate_frame2_shiftsReading() {
        let seq = makeSequence(bases: "AATGGCCGAA")
        let protein = seq.translate(frame: .frame2, codonTable: .standard)

        XCTAssertEqual(protein?.sequenceString, "MAE")
    }

    // MARK: - GC Content

    func test_sequence_gcContent_calculatesCorrectly() {
        let seq = makeSequence(bases: "ATCGATCG")

        XCTAssertEqual(seq.gcContent, 0.5, accuracy: 0.001)
    }

    func test_sequence_gcContent_allGC_returnsOne() {
        let seq = makeSequence(bases: "GCGCGC")

        XCTAssertEqual(seq.gcContent, 1.0, accuracy: 0.001)
    }

    func test_sequence_gcContent_noGC_returnsZero() {
        let seq = makeSequence(bases: "ATATAT")

        XCTAssertEqual(seq.gcContent, 0.0, accuracy: 0.001)
    }

    // MARK: - Hash

    func test_sequence_hash_sameSequence_sameHash() {
        let seq1 = makeSequence(bases: "ATCG")
        let seq2 = makeSequence(bases: "ATCG")

        XCTAssertEqual(seq1.hash, seq2.hash)
    }

    func test_sequence_hash_differentSequence_differentHash() {
        let seq1 = makeSequence(bases: "ATCG")
        let seq2 = makeSequence(bases: "ATCC")

        XCTAssertNotEqual(seq1.hash, seq2.hash)
    }
}
```

### Format Conformance Tests
```swift
final class FASTAConformanceTests: LungfishTestCase {
    var reader: FASTAReader!
    var writer: FASTAWriter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        reader = FASTAReader()
        writer = FASTAWriter()
    }

    // MARK: - Standard FASTA

    func test_fasta_singleSequence_parsesCorrectly() async throws {
        let url = loadFixture("single", extension: "fasta")
        let sequences = try await reader.read(from: url)

        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].name, "test_sequence")
        XCTAssertEqual(sequences[0].length, 100)
    }

    func test_fasta_multipleSequences_parsesAll() async throws {
        let url = loadFixture("multiple", extension: "fasta")
        let sequences = try await reader.read(from: url)

        XCTAssertEqual(sequences.count, 5)
    }

    func test_fasta_multilineSequence_joinsCorrectly() async throws {
        let url = loadFixture("multiline", extension: "fasta")
        let sequences = try await reader.read(from: url)

        XCTAssertEqual(sequences[0].length, 500)
        XCTAssertFalse(sequences[0].sequenceString.contains("\n"))
    }

    func test_fasta_wrappedSequence_roundTrips() async throws {
        let original = makeSequence(name: "test", bases: String(repeating: "ATCG", count: 100))

        let outputURL = tempDirectory.appending(path: "output.fasta")
        try writer.write([original], to: outputURL)

        let parsed = try await reader.read(from: outputURL)
        assertSequencesEqual(original, parsed[0])
    }

    // MARK: - Edge Cases

    func test_fasta_emptyFile_returnsEmptyArray() async throws {
        let url = loadFixture("empty", extension: "fasta")
        let sequences = try await reader.read(from: url)

        XCTAssertTrue(sequences.isEmpty)
    }

    func test_fasta_noHeader_throwsError() async {
        let url = loadFixture("no_header", extension: "fasta")

        await XCTAssertThrowsError(try await reader.read(from: url)) { error in
            XCTAssertTrue(error is FormatError)
        }
    }

    func test_fasta_specialCharactersInHeader_preserves() async throws {
        let url = loadFixture("special_header", extension: "fasta")
        let sequences = try await reader.read(from: url)

        XCTAssertEqual(sequences[0].name, "seq|123|ref|NC_001|")
    }

    // MARK: - Compression

    func test_fasta_gzipCompressed_parsesCorrectly() async throws {
        let url = loadFixture("compressed", extension: "fasta.gz")
        let sequences = try await reader.read(from: url)

        XCTAssertEqual(sequences.count, 1)
    }
}

final class GenBankConformanceTests: LungfishTestCase {
    var reader: GenBankReader!

    override func setUpWithError() throws {
        try super.setUpWithError()
        reader = GenBankReader()
    }

    func test_genbank_fullRecord_parsesAllFields() async throws {
        let url = loadFixture("full_record", extension: "gb")
        let docs = try await reader.read(from: url)

        XCTAssertEqual(docs.count, 1)
        let doc = docs[0]

        // Check metadata
        XCTAssertNotNil(doc.metadata.accession)
        XCTAssertNotNil(doc.metadata.organism)

        // Check annotations
        XCTAssertFalse(doc.annotations.isEmpty)
        XCTAssertTrue(doc.annotations.contains { $0.type == .gene })
        XCTAssertTrue(doc.annotations.contains { $0.type == .cds })
    }

    func test_genbank_joinedFeature_parsesCorrectly() async throws {
        let url = loadFixture("joined_feature", extension: "gb")
        let docs = try await reader.read(from: url)

        let cds = docs[0].annotations.first { $0.type == .cds }!
        XCTAssertTrue(cds.intervals.count > 1)
    }

    func test_genbank_complementFeature_setsStrand() async throws {
        let url = loadFixture("complement_feature", extension: "gb")
        let docs = try await reader.read(from: url)

        let gene = docs[0].annotations.first { $0.name == "negative_strand_gene" }!
        XCTAssertEqual(gene.strand, .negative)
    }
}
```

### Performance Benchmarks
```swift
final class PerformanceBenchmarks: LungfishTestCase {
    // MARK: - Parsing

    func testPerformance_FASTAParsing_largeFile() throws {
        let url = loadFixture("large_genome", extension: "fasta")

        measure {
            let reader = FASTAReader()
            _ = try? reader.readSync(from: url)
        }
    }

    func testPerformance_BAMRandomAccess() throws {
        let url = loadFixture("aligned_reads", extension: "bam")
        let reader = try BAMReader(url: url)
        let regions = (0..<100).map { _ in
            GenomicRegion(
                chromosome: "chr1",
                start: Int.random(in: 0..<1_000_000),
                end: Int.random(in: 0..<1_000_000) + 1000
            )
        }

        measure {
            for region in regions {
                _ = try? reader.query(region: region)
            }
        }
    }

    // MARK: - Rendering

    func testPerformance_TileRendering() throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 100

        let renderer = SequenceTrackRenderer()
        let context = MockRenderContext(width: 1000, height: 100)
        let frame = ReferenceFrame(chromosome: "chr1", start: 0, end: 10000)

        measure(options: options) {
            renderer.render(context: context, frame: frame)
        }
    }

    // MARK: - Diff Engine

    func testPerformance_DiffCalculation_10kb() throws {
        let seq1 = makeSequence(bases: randomDNA(length: 10000))
        let seq2 = mutateSequence(seq1, mutationRate: 0.01)

        measure {
            _ = SequenceDiff.create(from: seq1, to: seq2)
        }
    }

    // MARK: - Helpers

    private func randomDNA(length: Int) -> String {
        let bases = "ATCG"
        return String((0..<length).map { _ in bases.randomElement()! })
    }

    private func mutateSequence(_ seq: Sequence, mutationRate: Double) -> Sequence {
        var bases = Array(seq.sequenceString)
        let mutations = Int(Double(bases.count) * mutationRate)

        for _ in 0..<mutations {
            let pos = Int.random(in: 0..<bases.count)
            bases[pos] = "ATCG".randomElement()!
        }

        return Sequence(name: seq.name + "_mutated", data: Data(String(bases).utf8))
    }
}
```

### CI/CD Configuration
```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_15.2.app

      - name: Build
        run: xcodebuild build -scheme Lungfish -destination 'platform=macOS'

      - name: Run Tests
        run: xcodebuild test -scheme Lungfish -destination 'platform=macOS' -resultBundlePath TestResults.xcresult

      - name: Upload Test Results
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: TestResults.xcresult

      - name: Generate Coverage Report
        run: xcrun xccov view --report TestResults.xcresult > coverage.txt

      - name: Upload Coverage
        uses: codecov/codecov-action@v3
        with:
          files: coverage.txt

  performance:
    runs-on: macos-14
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4

      - name: Run Performance Tests
        run: xcodebuild test -scheme LungfishPerformanceTests -destination 'platform=macOS'

  lint:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: SwiftLint
        run: swiftlint lint --strict
```
