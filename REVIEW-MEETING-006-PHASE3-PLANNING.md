# Expert Review Meeting #006 - Phase 3 Planning

**Date**: Phase 3 Sprint Planning
**Attendees**: All 20 Experts
**Chair**: Swift Architecture Lead (Role 01)
**Agenda**: Plan Phase 3 deliverables and delegate tasks

---

## Phase 2 Retrospective

### Completed Successfully
| Deliverable | Owner | Status |
|-------------|-------|--------|
| ReferenceFrame coordinate system | Track Rendering Engineer (04) | ✅ |
| TileCache with LRU eviction | Track Rendering Engineer (04) | ✅ |
| Track protocol and DisplayMode | Track Rendering Engineer (04) | ✅ |
| SequenceTrack rendering | Track Rendering Engineer (04) | ✅ |
| FeatureTrack with RowPacker | Track Rendering Engineer (04) | ✅ |
| GFF3Reader | File Format Expert (06) | ✅ |
| BEDReader/Writer | File Format Expert (06) | ✅ |
| FASTQ reader/writer | File Format Expert (06) | ✅ |
| MainMenu system | UI/UX Lead (02) | ✅ |
| 64 unit tests | Testing & QA Lead (19) | ✅ |

### Lessons Learned
1. Type consistency matters - `Strand.unknown` not `.unstranded`
2. Platform separation important - `AnnotationColor` in Core, `NSColor` in UI
3. Actor isolation requires careful test design

---

## Phase 3 Scope Discussion

### Swift Architecture Lead (Role 01)

Phase 3 focuses on **editing, versioning, and advanced file formats**. The goals are:

1. **Sequence Editing** - Enable base-level modifications
2. **Version History** - Implement diff-based change tracking
3. **Advanced Readers** - VCF for variants, BigWig for coverage
4. **BAM/CRAM Support** - Alignment visualization (requires htslib)

**Architectural Decisions**:
- Editing will use a command pattern for undo/redo integration
- Version history will use git-like content-addressable storage
- htslib will be integrated via C interop (System library)

**Risk Assessment**: BAM/CRAM support depends on htslib availability. We'll create a wrapper layer that can gracefully degrade if htslib is not installed.

---

## Phase 3 Task Delegation

### Week 1: Core Editing & Versioning

#### Task 1: Sequence Editing System
**Owner**: Sequence Viewer Specialist (Role 03)
**Priority**: HIGH
**Estimated Files**: 4-5

**Deliverables**:
1. `Sources/LungfishCore/Editing/SequenceEdit.swift`
   - Edit operations: insert, delete, replace
   - Command pattern for undo/redo

2. `Sources/LungfishCore/Editing/EditableSequence.swift`
   - Mutable sequence wrapper
   - Edit history tracking

3. `Sources/LungfishCore/Editing/EditOperation.swift`
   - Operation enum with position, length, content
   - Serializable for persistence

**API Design**:
```swift
// Proposed API
protocol EditOperation: Sendable {
    var position: Int { get }
    func apply(to sequence: inout String) throws
    func inverse() -> EditOperation
}

class EditableSequence: ObservableObject {
    @Published private(set) var sequence: Sequence
    private var undoStack: [EditOperation] = []
    private var redoStack: [EditOperation] = []

    func insert(_ bases: String, at position: Int) throws
    func delete(range: Range<Int>) throws
    func replace(range: Range<Int>, with bases: String) throws
    func undo() -> Bool
    func redo() -> Bool
}
```

**Acceptance Criteria**:
- [ ] Insert/delete/replace operations work
- [ ] Undo/redo stack functional
- [ ] Operations are serializable
- [ ] Unit tests for all operations

---

#### Task 2: Version History System
**Owner**: Version Control Specialist (Role 17)
**Priority**: HIGH
**Estimated Files**: 5-6

**Deliverables**:
1. `Sources/LungfishCore/Versioning/SequenceDiff.swift`
   - VCF-like delta representation
   - Efficient diff computation

2. `Sources/LungfishCore/Versioning/Version.swift`
   - Version metadata (timestamp, message, author)
   - Content hash (SHA-256)

3. `Sources/LungfishCore/Versioning/VersionHistory.swift`
   - Linear version chain
   - Checkout and commit operations

4. `Sources/LungfishCore/Versioning/ObjectStore.swift`
   - Content-addressable storage
   - Git-like object model

**Storage Format**:
```
.lgb/history/
├── objects/
│   ├── aa/
│   │   └── bb1234...  # SHA-256 hash prefix/suffix
│   └── ...
├── refs/
│   ├── main           # Current HEAD
│   └── tags/
└── versions.json      # Version metadata
```

**API Design**:
```swift
struct SequenceDiff: Codable, Sendable {
    let operations: [DiffOperation]

    enum DiffOperation: Codable, Sendable {
        case insert(position: Int, bases: String)
        case delete(position: Int, length: Int)
        case replace(position: Int, original: String, replacement: String)
    }

    static func compute(from original: String, to modified: String) -> SequenceDiff
    func apply(to sequence: String) throws -> String
}

class VersionHistory: ObservableObject {
    @Published var versions: [Version]
    @Published var currentVersionIndex: Int

    func commit(diff: SequenceDiff, message: String?) throws -> Version
    func checkout(version: Version) throws -> (sequence: String, annotations: [SequenceAnnotation])
    func diff(from: Version, to: Version) -> SequenceDiff
}
```

**Acceptance Criteria**:
- [ ] Diff computation works for insertions/deletions/replacements
- [ ] Versions can be saved and restored
- [ ] Content-addressable storage functional
- [ ] History navigation works
- [ ] Unit tests for diff operations

---

### Week 2: Advanced File Formats

#### Task 3: VCF Reader
**Owner**: File Format Expert (Role 06)
**Priority**: MEDIUM
**Estimated Files**: 2-3

**Deliverables**:
1. `Sources/LungfishIO/Formats/VCF/VCFReader.swift`
   - VCF 4.3 spec compliance
   - Header parsing (##INFO, ##FORMAT, ##contig)
   - Variant record parsing

2. `Sources/LungfishIO/Formats/VCF/VCFVariant.swift`
   - Variant model with CHROM, POS, ID, REF, ALT, QUAL, FILTER, INFO

**API Design**:
```swift
struct VCFVariant: Sendable, Identifiable {
    let id: String  // ID field or generated
    let chromosome: String
    let position: Int  // 1-based
    let ref: String
    let alt: [String]
    let quality: Double?
    let filter: String?
    let info: [String: String]
    let genotypes: [String: VCFGenotype]?
}

final class VCFReader: Sendable {
    func variants(from url: URL) -> AsyncThrowingStream<VCFVariant, Error>
    func readAll(from url: URL) async throws -> [VCFVariant]
    func readHeader(from url: URL) async throws -> VCFHeader
}
```

**Acceptance Criteria**:
- [ ] Parse VCF header correctly
- [ ] Parse variant records
- [ ] Handle multi-allelic variants
- [ ] Convert to annotations
- [ ] Unit tests with sample VCF data

---

#### Task 4: BigWig Reader
**Owner**: File Format Expert (Role 06)
**Priority**: MEDIUM
**Estimated Files**: 3-4

**Deliverables**:
1. `Sources/LungfishIO/Formats/BigWig/BigWigReader.swift`
   - Binary file parsing
   - R-tree index navigation
   - Zoom level selection

2. `Sources/LungfishIO/Formats/BigWig/BigWigIndex.swift`
   - R-tree data structure
   - Range queries

3. `Sources/LungfishIO/Formats/BigWig/ChromTree.swift`
   - Chromosome B+ tree

**Reference**: UCSC BigWig specification

**API Design**:
```swift
struct BigWigValue: Sendable {
    let chromosome: String
    let start: Int
    let end: Int
    let value: Float
}

actor BigWigReader {
    func values(chromosome: String, start: Int, end: Int) async throws -> [BigWigValue]
    func chromosomes() async throws -> [String: Int]  // name -> length
    func summary(chromosome: String, start: Int, end: Int, bins: Int) async throws -> [Float]
}
```

**Acceptance Criteria**:
- [ ] Read BigWig header correctly
- [ ] Navigate R-tree index
- [ ] Extract values for regions
- [ ] Zoom level summarization works
- [ ] Unit tests with sample BigWig

---

#### Task 5: CoverageTrack
**Owner**: Track Rendering Engineer (Role 04)
**Priority**: MEDIUM
**Estimated Files**: 1-2

**Deliverables**:
1. `Sources/LungfishUI/Tracks/Implementations/CoverageTrack.swift`
   - Signal/coverage visualization
   - Auto-scaling Y-axis
   - Histogram and line modes

**API Design**:
```swift
@MainActor
public final class CoverageTrack: Track {
    public enum RenderMode {
        case histogram
        case line
        case heatmap
    }

    var renderMode: RenderMode = .histogram
    var yAxisScale: YAxisScale = .auto
    var color: NSColor = .systemBlue

    func setDataSource(_ source: CoverageDataSource)
}
```

**Acceptance Criteria**:
- [ ] Renders coverage data from BigWig
- [ ] Auto-scaling Y-axis
- [ ] Multiple render modes
- [ ] Performance acceptable for large regions

---

#### Task 6: BAM/CRAM Preparation (Deferred)
**Owner**: Alignment Expert (Role 08)
**Priority**: LOW (Phase 3.5)
**Status**: PLANNING ONLY

**Rationale**: htslib integration requires:
1. System library wrapper
2. Complex memory management
3. Significant testing

**Decision**: Create interface definitions in Phase 3, defer implementation to Phase 3.5 or Phase 4.

**Deliverables (Interface Only)**:
1. `Sources/LungfishIO/Formats/BAM/BAMReader.swift` - Protocol only
2. `Sources/LungfishIO/Formats/BAM/AlignmentRecord.swift` - Data model

---

### Week 2 Continued: UI Integration

#### Task 7: Edit UI Components
**Owner**: UI/UX Lead (Role 02)
**Priority**: MEDIUM
**Estimated Files**: 2-3

**Deliverables**:
1. `Sources/LungfishApp/Views/Viewer/SequenceEditorView.swift`
   - Base-level editing interface
   - Selection handling
   - Keyboard input

2. Updates to existing views for edit mode toggling

**Acceptance Criteria**:
- [ ] Toggle between view/edit modes
- [ ] Selection works at base level
- [ ] Keyboard shortcuts for editing
- [ ] Visual feedback for edits

---

### Testing Requirements

#### Task 8: Phase 3 Unit Tests
**Owner**: Testing & QA Lead (Role 19)
**Priority**: HIGH

**Required Test Files**:
1. `Tests/LungfishCoreTests/EditableSequenceTests.swift` - 15+ tests
2. `Tests/LungfishCoreTests/SequenceDiffTests.swift` - 12+ tests
3. `Tests/LungfishCoreTests/VersionHistoryTests.swift` - 10+ tests
4. `Tests/LungfishIOTests/VCFReaderTests.swift` - 12+ tests
5. `Tests/LungfishIOTests/BigWigReaderTests.swift` - 10+ tests

**Target**: 60+ new tests (124+ total)

**Test Data Requirements**:
- Sample VCF file with variants
- Sample BigWig file with coverage data

---

## Risk Assessment

| Risk | Severity | Mitigation | Owner |
|------|----------|------------|-------|
| BigWig binary format complexity | Medium | Use reference implementation as guide | File Format Expert (06) |
| Version history data corruption | High | Comprehensive testing, checksums | Version Control Specialist (17) |
| Edit undo/redo edge cases | Medium | Extensive unit testing | Sequence Viewer Specialist (03) |
| BAM/CRAM htslib dependency | High | Defer to Phase 3.5 | Alignment Expert (08) |

---

## Expert Assignments Summary

| Expert | Primary Task | Secondary Task |
|--------|--------------|----------------|
| Sequence Viewer Specialist (03) | Sequence Editing System | Edit UI feedback |
| Track Rendering Engineer (04) | CoverageTrack | BigWig integration |
| File Format Expert (06) | VCF Reader, BigWig Reader | - |
| Alignment Expert (08) | BAM interface design | - |
| Version Control Specialist (17) | Version History System | - |
| UI/UX Lead (02) | Edit UI Components | Menu updates |
| Testing & QA Lead (19) | Unit tests | Integration tests |

---

## Sprint Schedule

### Week 1 (Days 1-7)
- Day 1-2: EditOperation, EditableSequence
- Day 3-4: SequenceDiff, Version
- Day 5-6: VersionHistory, ObjectStore
- Day 7: Week 1 review, bug fixes

### Week 2 (Days 8-14)
- Day 8-9: VCFReader
- Day 10-11: BigWigReader
- Day 12: CoverageTrack
- Day 13: Edit UI integration
- Day 14: Final testing, Phase 3 review

---

## Consensus

**Phase 3 scope approved by all 20 experts.**

| Expert Category | Approval |
|-----------------|----------|
| Core Development (1-4) | ✅ 4/4 |
| Bioinformatics (5-8) | ✅ 4/4 |
| Primer & PCR (9-11) | ✅ 3/3 (monitoring) |
| Data & Integration (12-14) | ✅ 3/3 (monitoring) |
| Plugin & Workflow (15-16) | ✅ 2/2 (monitoring) |
| Data Management (17-18) | ✅ 2/2 |
| Quality & Docs (19-20) | ✅ 2/2 |

**Note**: BAM/CRAM support deferred to Phase 3.5 per Alignment Expert recommendation.

---

## Action Items

| Expert | Task | Due |
|--------|------|-----|
| Sequence Viewer Specialist (03) | Begin EditableSequence implementation | Week 1 |
| Version Control Specialist (17) | Begin VersionHistory implementation | Week 1 |
| File Format Expert (06) | Begin VCF Reader | Week 2 |
| File Format Expert (06) | Begin BigWig Reader | Week 2 |
| Track Rendering Engineer (04) | Begin CoverageTrack | Week 2 |
| Testing & QA Lead (19) | Prepare test data files | Week 1 |

---

*Meeting adjourned. Phase 3 implementation begins.*
