# Mapped Reads To Annotations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a CLI and GUI workflow that converts bundle-owned mapped BAM reads into SQLite-backed annotation tracks with read metadata available in the annotation table.

**Architecture:** Implement a shared `MappedReadsAnnotationService` in `LungfishWorkflow` that resolves a bundle alignment track, runs `samtools view -h`, parses each SAM alignment, streams rows into the existing annotation database schema, and appends an `AnnotationTrackInfo` to `manifest.json`. Wire that service through `lungfish-cli bam annotate`, then expose the same request model in the Analysis sidecar and add dynamic annotation attribute columns in the drawer for sorting/filtering converted read metadata.

**Tech Stack:** Swift 6.2, SwiftPM/XCTest, ArgumentParser, SQLite3 via `LungfishIO.AnnotationDatabase`, existing `AlignmentSamtoolsRunning`/`NativeToolSamtoolsRunner`, SwiftUI/AppKit Inspector views

---

## File Structure

### Create

- `Sources/LungfishWorkflow/Alignment/MappedReadsAnnotationModels.swift`
  - Request/result/error types and parsed SAM-to-annotation row model.
- `Sources/LungfishWorkflow/Alignment/MappedReadsSAMRecord.swift`
  - Pure parser for one SAM alignment line that preserves all auxiliary tags.
- `Sources/LungfishWorkflow/Alignment/MappedReadsAnnotationDatabaseWriter.swift`
  - Streaming SQLite writer for the existing annotation DB schema.
- `Sources/LungfishWorkflow/Alignment/MappedReadsAnnotationService.swift`
  - Bundle-level conversion workflow and manifest attachment.
- `Tests/LungfishWorkflowTests/Alignment/MappedReadsSAMRecordTests.swift`
  - Pure parser and attribute behavior.
- `Tests/LungfishWorkflowTests/Alignment/MappedReadsAnnotationDatabaseWriterTests.swift`
  - SQLite row writing and query round-trip.
- `Tests/LungfishWorkflowTests/Alignment/MappedReadsAnnotationServiceTests.swift`
  - Bundle workflow with injectable samtools runner.
- `Tests/LungfishCLITests/BAMAnnotateCommandTests.swift`
  - CLI parsing/output behavior.

### Modify

- `Sources/LungfishCore/Bundles/BundleManifest.swift`
  - Add `addingAnnotationTrack(_:)` and `removingAnnotationTrack(id:)`.
- `Sources/LungfishCLI/Commands/BAMCommand.swift`
  - Add `AnnotateSubcommand` and event output.
- `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
  - Add Analysis-sidecar state and UI controls for mapped-read annotation conversion.
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
  - Wire the GUI action to `MappedReadsAnnotationService`, Operation Center, reload, and success/failure alerts.
- `Sources/LungfishApp/Services/AnnotationSearchIndex.swift`
  - Carry annotation attributes in search results.
- `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift`
  - Discover annotation attributes as dynamic columns; sort and locally filter them.
- `Tests/LungfishAppTests/ReadStyleSectionViewModelTests.swift`
  - Request construction defaults and optional sequence/quality toggles.
- `Tests/LungfishAppTests/VariantTableEnhancementTests.swift`
  - Annotation attribute columns and numeric sorting/filtering.
- `Tests/LungfishCLITests/BAMCommandTests.swift`
  - Help text includes `annotate`.

## Task 1: Pure SAM Record Conversion

**Files:**
- Create: `Sources/LungfishWorkflow/Alignment/MappedReadsAnnotationModels.swift`
- Create: `Sources/LungfishWorkflow/Alignment/MappedReadsSAMRecord.swift`
- Test: `Tests/LungfishWorkflowTests/Alignment/MappedReadsSAMRecordTests.swift`

- [ ] **Step 1: Write failing parser tests**

```swift
import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class MappedReadsSAMRecordTests: XCTestCase {
    func testParseMappedRecordPreservesCoreFieldsAndAllAuxiliaryTags() throws {
        let line = "read-1\t99\tchr1\t101\t42\t8M1I4M2D6M\t=\t151\t200\tACGTACGTACGTACGTAAA\tIIIIIIIIIIIIIIIIIII\tNM:i:2\tAS:i:87\tRG:Z:grp-a\tXX:Z:a=b;c"

        let record = try XCTUnwrap(MappedReadsSAMRecord.parse(line))

        XCTAssertEqual(record.readName, "read-1")
        XCTAssertEqual(record.flag, 99)
        XCTAssertEqual(record.referenceName, "chr1")
        XCTAssertEqual(record.start0, 100)
        XCTAssertEqual(record.end0, 120)
        XCTAssertEqual(record.mapq, 42)
        XCTAssertEqual(record.cigarString, "8M1I4M2D6M")
        XCTAssertEqual(record.referenceLength, 20)
        XCTAssertEqual(record.queryLength, 19)
        XCTAssertEqual(record.mateReferenceName, "chr1")
        XCTAssertEqual(record.matePosition0, 150)
        XCTAssertEqual(record.templateLength, 200)
        XCTAssertEqual(record.auxiliaryTags["NM"], "2")
        XCTAssertEqual(record.auxiliaryTags["AS"], "87")
        XCTAssertEqual(record.auxiliaryTags["RG"], "grp-a")
        XCTAssertEqual(record.auxiliaryTags["XX"], "a=b;c")
    }

    func testDefaultAttributesExcludeSequenceAndQualities() throws {
        let line = "r2\t16\tchr2\t10\t60\t5S10M\t*\t0\t0\tNNNNNACGTACGTAC\tFFFFFJJJJJJJJJJ\tNM:i:0\tMD:Z:10"
        let record = try XCTUnwrap(MappedReadsSAMRecord.parse(line))
        let request = MappedReadsAnnotationRequest(
            bundleURL: URL(fileURLWithPath: "/tmp/ref.lungfishref"),
            sourceTrackID: "aln_a",
            outputTrackName: "Mapped Reads",
            mappedOnly: true,
            primaryOnly: false,
            includeSequence: false,
            includeQualities: false,
            replaceExisting: false
        )

        let row = record.annotationRow(sourceTrackID: "aln_a", sourceTrackName: "Reads", request: request)

        XCTAssertEqual(row.name, "r2")
        XCTAssertEqual(row.type, "mapped_read")
        XCTAssertEqual(row.chromosome, "chr2")
        XCTAssertEqual(row.start, 9)
        XCTAssertEqual(row.end, 19)
        XCTAssertEqual(row.strand, "-")
        XCTAssertEqual(row.attributes["tag_NM"], "0")
        XCTAssertEqual(row.attributes["tag_MD"], "10")
        XCTAssertNil(row.attributes["sequence"])
        XCTAssertNil(row.attributes["qualities"])
    }

    func testOptionalSequenceAndQualitiesAreIncludedOnlyWhenRequested() throws {
        let line = "r3\t0\tchr1\t1\t20\t4M\t*\t0\t0\tACGT\tABCD\tNM:i:0"
        let record = try XCTUnwrap(MappedReadsSAMRecord.parse(line))
        let request = MappedReadsAnnotationRequest(
            bundleURL: URL(fileURLWithPath: "/tmp/ref.lungfishref"),
            sourceTrackID: "aln_a",
            outputTrackName: "Mapped Reads",
            mappedOnly: true,
            primaryOnly: false,
            includeSequence: true,
            includeQualities: true,
            replaceExisting: false
        )

        let row = record.annotationRow(sourceTrackID: "aln_a", sourceTrackName: "Reads", request: request)

        XCTAssertEqual(row.attributes["sequence"], "ACGT")
        XCTAssertEqual(row.attributes["qualities"], "ABCD")
    }
}
```

- [ ] **Step 2: Run the parser tests and verify RED**

Run:

```bash
swift test --filter MappedReadsSAMRecordTests
```

Expected: FAIL with missing `MappedReadsSAMRecord` / `MappedReadsAnnotationRequest` symbols.

- [ ] **Step 3: Add request/result/row models**

Create `Sources/LungfishWorkflow/Alignment/MappedReadsAnnotationModels.swift` with:

```swift
import Foundation
import LungfishCore

public struct MappedReadsAnnotationRequest: Sendable, Equatable {
    public let bundleURL: URL
    public let sourceTrackID: String
    public let outputTrackName: String
    public let mappedOnly: Bool
    public let primaryOnly: Bool
    public let includeSequence: Bool
    public let includeQualities: Bool
    public let replaceExisting: Bool

    public init(
        bundleURL: URL,
        sourceTrackID: String,
        outputTrackName: String,
        mappedOnly: Bool = true,
        primaryOnly: Bool = false,
        includeSequence: Bool = false,
        includeQualities: Bool = false,
        replaceExisting: Bool = false
    ) {
        self.bundleURL = bundleURL
        self.sourceTrackID = sourceTrackID
        self.outputTrackName = outputTrackName
        self.mappedOnly = mappedOnly
        self.primaryOnly = primaryOnly
        self.includeSequence = includeSequence
        self.includeQualities = includeQualities
        self.replaceExisting = replaceExisting
    }
}

public struct MappedReadsAnnotationRow: Sendable, Equatable {
    public let name: String
    public let type: String
    public let chromosome: String
    public let start: Int
    public let end: Int
    public let strand: String
    public let attributes: [String: String]
}

public struct MappedReadsAnnotationResult: Sendable, Equatable {
    public let bundleURL: URL
    public let sourceAlignmentTrackID: String
    public let sourceAlignmentTrackName: String
    public let annotationTrackInfo: AnnotationTrackInfo
    public let databasePath: String
    public let convertedRecordCount: Int
    public let skippedUnmappedCount: Int
    public let skippedSecondarySupplementaryCount: Int
    public let includedSequence: Bool
    public let includedQualities: Bool
}

public enum MappedReadsAnnotationServiceError: Error, LocalizedError, Sendable, Equatable {
    case sourceTrackNotFound(String)
    case outputTrackExists(String)
    case missingAlignmentFile(String)
    case samtoolsFailed(String)
    case invalidSAMLine(String)
    case manifestWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceTrackNotFound(let id):
            return "Could not find alignment track '\(id)' in the bundle."
        case .outputTrackExists(let name):
            return "An annotation track named '\(name)' already exists. Use --replace to overwrite it."
        case .missingAlignmentFile(let path):
            return "Alignment file not found: \(path)"
        case .samtoolsFailed(let message):
            return "samtools mapped-read annotation export failed: \(message)"
        case .invalidSAMLine(let line):
            return "Could not parse SAM alignment line: \(line)"
        case .manifestWriteFailed(let message):
            return "Failed to update bundle manifest: \(message)"
        }
    }
}
```

- [ ] **Step 4: Add the SAM parser and attribute conversion**

Create `Sources/LungfishWorkflow/Alignment/MappedReadsSAMRecord.swift` with a parser that:

```swift
import Foundation
import LungfishCore

public struct MappedReadsSAMRecord: Sendable, Equatable {
    public let readName: String
    public let flag: UInt16
    public let referenceName: String
    public let start0: Int
    public let mapq: UInt8
    public let cigarString: String
    public let cigar: [CIGAROperation]
    public let mateReferenceName: String?
    public let matePosition0: Int?
    public let templateLength: Int
    public let sequence: String
    public let qualities: String
    public let auxiliaryTags: [String: String]

    public var referenceLength: Int {
        cigar.reduce(0) { $0 + ($1.consumesReference ? $1.length : 0) }
    }

    public var queryLength: Int {
        cigar.reduce(0) { $0 + ($1.consumesQuery ? $1.length : 0) }
    }

    public var end0: Int { start0 + referenceLength }
    public var isUnmapped: Bool { flag & 0x4 != 0 }
    public var isReverse: Bool { flag & 0x10 != 0 }
    public var isSecondary: Bool { flag & 0x100 != 0 }
    public var isDuplicate: Bool { flag & 0x400 != 0 }
    public var isSupplementary: Bool { flag & 0x800 != 0 }

    public static func parse(_ line: some StringProtocol) -> MappedReadsSAMRecord? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 11,
              let flag = UInt16(fields[1]),
              let pos1 = Int(fields[3]),
              pos1 > 0,
              let cigar = CIGAROperation.parse(String(fields[5])) else { return nil }
        let referenceName = String(fields[2])
        guard referenceName != "*" else { return nil }
        let mateReference: String?
        switch String(fields[6]) {
        case "*": mateReference = nil
        case "=": mateReference = referenceName
        default: mateReference = String(fields[6])
        }
        let matePosition0 = Int(fields[7]).flatMap { $0 > 0 ? $0 - 1 : nil }
        var tags: [String: String] = [:]
        for field in fields.dropFirst(11) {
            let pieces = field.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            if pieces.count == 3 {
                tags[String(pieces[0])] = String(pieces[2])
            }
        }
        return MappedReadsSAMRecord(
            readName: String(fields[0]),
            flag: flag,
            referenceName: referenceName,
            start0: pos1 - 1,
            mapq: UInt8(fields[4]) ?? 0,
            cigarString: String(fields[5]),
            cigar: cigar,
            mateReferenceName: mateReference,
            matePosition0: matePosition0,
            templateLength: Int(fields[8]) ?? 0,
            sequence: fields[9] == "*" ? "" : String(fields[9]),
            qualities: fields[10] == "*" ? "" : String(fields[10]),
            auxiliaryTags: tags
        )
    }

    public func annotationRow(
        sourceTrackID: String,
        sourceTrackName: String,
        request: MappedReadsAnnotationRequest
    ) -> MappedReadsAnnotationRow {
        var attrs: [String: String] = [
            "read_name": readName,
            "flag": "\(flag)",
            "mapq": "\(mapq)",
            "cigar": cigarString,
            "pos_1_based": "\(start0 + 1)",
            "alignment_start": "\(start0)",
            "alignment_end": "\(end0)",
            "reference_length": "\(referenceLength)",
            "query_length": "\(queryLength)",
            "template_length": "\(templateLength)",
            "is_paired": flag & 0x1 != 0 ? "true" : "false",
            "is_proper_pair": flag & 0x2 != 0 ? "true" : "false",
            "is_reverse": isReverse ? "true" : "false",
            "is_first_in_pair": flag & 0x40 != 0 ? "true" : "false",
            "is_second_in_pair": flag & 0x80 != 0 ? "true" : "false",
            "is_secondary": isSecondary ? "true" : "false",
            "is_supplementary": isSupplementary ? "true" : "false",
            "is_duplicate": isDuplicate ? "true" : "false",
            "source_alignment_track_id": sourceTrackID,
            "source_alignment_track_name": sourceTrackName,
        ]
        if let mateReferenceName { attrs["mate_reference"] = mateReferenceName }
        if let matePosition0 { attrs["mate_position_1_based"] = "\(matePosition0 + 1)" }
        if let rg = auxiliaryTags["RG"] { attrs["read_group"] = rg }
        for (tag, value) in auxiliaryTags.sorted(by: { $0.key < $1.key }) {
            attrs["tag_\(tag)"] = value
        }
        if request.includeSequence { attrs["sequence"] = sequence }
        if request.includeQualities { attrs["qualities"] = qualities }
        return MappedReadsAnnotationRow(
            name: readName,
            type: "mapped_read",
            chromosome: referenceName,
            start: start0,
            end: max(start0 + 1, end0),
            strand: isReverse ? "-" : "+",
            attributes: attrs
        )
    }
}
```

- [ ] **Step 5: Run parser tests and verify GREEN**

Run:

```bash
swift test --filter MappedReadsSAMRecordTests
```

Expected: PASS.

## Task 2: SQLite Writer and Bundle Service

**Files:**
- Create: `Sources/LungfishWorkflow/Alignment/MappedReadsAnnotationDatabaseWriter.swift`
- Create: `Sources/LungfishWorkflow/Alignment/MappedReadsAnnotationService.swift`
- Modify: `Sources/LungfishCore/Bundles/BundleManifest.swift`
- Test: `Tests/LungfishWorkflowTests/Alignment/MappedReadsAnnotationDatabaseWriterTests.swift`
- Test: `Tests/LungfishWorkflowTests/Alignment/MappedReadsAnnotationServiceTests.swift`

- [ ] **Step 1: Write failing writer tests**

```swift
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class MappedReadsAnnotationDatabaseWriterTests: XCTestCase {
    func testWriterCreatesQueryableAnnotationDatabaseWithAttributes() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let dbURL = temp.appendingPathComponent("mapped_reads.db")

        let rows = [
            MappedReadsAnnotationRow(
                name: "read-a",
                type: "mapped_read",
                chromosome: "chr1",
                start: 10,
                end: 20,
                strand: "+",
                attributes: ["mapq": "60", "tag_NM": "0", "sequence": "ACGT"]
            ),
            MappedReadsAnnotationRow(
                name: "read-b",
                type: "mapped_read",
                chromosome: "chr1",
                start: 30,
                end: 35,
                strand: "-",
                attributes: ["mapq": "12", "tag_NM": "2"]
            ),
        ]

        let count = try MappedReadsAnnotationDatabaseWriter.write(rows: rows, to: dbURL)

        XCTAssertEqual(count, 2)
        let db = try AnnotationDatabase(url: dbURL)
        let records = db.queryByRegion(chromosome: "chr1", start: 0, end: 40)
        XCTAssertEqual(records.map(\.name), ["read-a", "read-b"])
        XCTAssertEqual(AnnotationDatabase.parseAttributes(records[0].attributes ?? "")["tag_NM"], "0")
        XCTAssertEqual(AnnotationDatabase.parseAttributes(records[0].attributes ?? "")["sequence"], "ACGT")
    }
}
```

- [ ] **Step 2: Run writer test and verify RED**

Run:

```bash
swift test --filter MappedReadsAnnotationDatabaseWriterTests
```

Expected: FAIL with missing writer symbol.

- [ ] **Step 3: Implement the SQLite writer**

Implement `MappedReadsAnnotationDatabaseWriter.write(rows:to:)` using the same v4 schema as `AnnotationDatabase.createFromBED`:

```swift
import Foundation
import SQLite3

public enum MappedReadsAnnotationDatabaseWriter {
    public static func write(rows: [MappedReadsAnnotationRow], to outputURL: URL) throws -> Int {
        try? FileManager.default.removeItem(at: outputURL)
        var db: OpaquePointer?
        guard sqlite3_open(outputURL.path, &db) == SQLITE_OK, let db else {
            throw MappedReadsAnnotationServiceError.manifestWriteFailed("Could not open annotation database.")
        }
        defer { sqlite3_close(db) }
        try exec(db, """
        CREATE TABLE annotations (
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            chromosome TEXT NOT NULL,
            start INTEGER NOT NULL,
            end INTEGER NOT NULL,
            strand TEXT NOT NULL DEFAULT '.',
            attributes TEXT,
            block_count INTEGER,
            block_sizes TEXT,
            block_starts TEXT,
            gene_name TEXT
        );
        CREATE TABLE db_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        INSERT INTO db_metadata VALUES ('schema_version', '4');
        """)
        try exec(db, "BEGIN TRANSACTION")
        let sql = "INSERT INTO annotations (name, type, chromosome, start, end, strand, attributes, block_count, block_sizes, block_starts, gene_name) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MappedReadsAnnotationServiceError.manifestWriteFailed("Could not prepare annotation insert.")
        }
        defer { sqlite3_finalize(stmt) }
        for row in rows {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, row.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, row.type, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, row.chromosome, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, Int64(row.start))
            sqlite3_bind_int64(stmt, 5, Int64(row.end))
            sqlite3_bind_text(stmt, 6, row.strand, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, serialize(row.attributes), -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw MappedReadsAnnotationServiceError.manifestWriteFailed("Could not insert annotation row.")
            }
        }
        try exec(db, "CREATE INDEX idx_annotations_name ON annotations(name COLLATE NOCASE)")
        try exec(db, "CREATE INDEX idx_annotations_type ON annotations(type)")
        try exec(db, "CREATE INDEX idx_annotations_chrom ON annotations(chromosome)")
        try exec(db, "CREATE INDEX idx_annotations_region ON annotations(chromosome, start, end)")
        try exec(db, "CREATE INDEX idx_annotations_gene_name ON annotations(gene_name COLLATE NOCASE)")
        try exec(db, "COMMIT")
        return rows.count
    }
}
```

Use a private `serialize(_:)` helper that percent-encodes `%`, `;`, `=`, `&`, and `,`, and a private `exec(_:_:)` helper that throws `manifestWriteFailed` with the SQLite error string. Add the `SQLITE_TRANSIENT` constant at file scope:

```swift
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
```

- [ ] **Step 4: Add manifest annotation helpers**

Add to `BundleManifest`:

```swift
public func addingAnnotationTrack(_ track: AnnotationTrackInfo) -> BundleManifest {
    BundleManifest(
        formatVersion: formatVersion,
        name: name,
        identifier: identifier,
        description: description,
        originBundlePath: originBundlePath,
        createdDate: createdDate,
        modifiedDate: Date(),
        source: source,
        genome: genome,
        annotations: annotations + [track],
        variants: variants,
        tracks: tracks,
        alignments: alignments,
        metadata: metadata,
        browserSummary: nil
    )
}

public func removingAnnotationTrack(id: String) -> BundleManifest {
    BundleManifest(
        formatVersion: formatVersion,
        name: name,
        identifier: identifier,
        description: description,
        originBundlePath: originBundlePath,
        createdDate: createdDate,
        modifiedDate: Date(),
        source: source,
        genome: genome,
        annotations: annotations.filter { $0.id != id },
        variants: variants,
        tracks: tracks,
        alignments: alignments,
        metadata: metadata,
        browserSummary: nil
    )
}
```

- [ ] **Step 5: Write failing service tests**

```swift
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class MappedReadsAnnotationServiceTests: XCTestCase {
    func testServiceConvertsSamtoolsOutputIntoBundleAnnotationTrack() async throws {
        let bundleURL = try makeTestBundle()
        let sam = [
            "@HD\tVN:1.6\tSO:coordinate",
            "@SQ\tSN:chr1\tLN:1000",
            "r1\t0\tchr1\t11\t60\t10M\t*\t0\t0\tACGTACGTAC\tJJJJJJJJJJ\tNM:i:0\tAS:i:10",
            "r2\t256\tchr1\t21\t20\t5M\t*\t0\t0\tACGTA\tJJJJJ\tNM:i:1",
        ].joined(separator: "\n")
        let runner = StubSamtoolsRunner(stdout: sam)
        let service = MappedReadsAnnotationService(samtoolsRunner: runner, trackIDProvider: { "mapped_reads" })

        let result = try await service.convert(
            request: MappedReadsAnnotationRequest(
                bundleURL: bundleURL,
                sourceTrackID: "aln_a",
                outputTrackName: "Mapped Reads",
                mappedOnly: true,
                primaryOnly: true,
                includeSequence: false,
                includeQualities: false,
                replaceExisting: false
            )
        )

        XCTAssertEqual(result.convertedRecordCount, 1)
        XCTAssertEqual(result.skippedSecondarySupplementaryCount, 1)
        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.annotations.first?.id, "mapped_reads")
        XCTAssertEqual(manifest.annotations.first?.databasePath, "annotations/mapped_reads.db")
        let db = try AnnotationDatabase(url: bundleURL.appendingPathComponent("annotations/mapped_reads.db"))
        let records = db.queryByRegion(chromosome: "chr1", start: 0, end: 100)
        XCTAssertEqual(records.count, 1)
        let attrs = AnnotationDatabase.parseAttributes(records[0].attributes ?? "")
        XCTAssertEqual(attrs["tag_NM"], "0")
        XCTAssertNil(attrs["sequence"])
    }
}
```

The helper `makeTestBundle()` should create a minimal valid `.lungfishref` with `manifest.json`, `genome/sequence.fa`, `genome/sequence.fa.fai`, `alignments/reads.bam`, and `alignments/reads.bam.bai`. The stub runner should conform to `AlignmentSamtoolsRunning` and return the supplied stdout.

- [ ] **Step 6: Run service test and verify RED**

Run:

```bash
swift test --filter MappedReadsAnnotationServiceTests
```

Expected: FAIL with missing service symbol.

- [ ] **Step 7: Implement `MappedReadsAnnotationService`**

Implement `convert(request:progressHandler:)` to:

1. Open `ReferenceBundle(url:)`.
2. Find `sourceTrackID` in `bundle.alignmentTrack(id:)`.
3. Resolve BAM path with `bundle.resolveAlignmentPath(_:)`.
4. Fail if a normalized output track ID exists and `replaceExisting == false`.
5. Run `samtoolsRunner.runSamtools(arguments: ["view", "-h", bamPath], timeout: 3600)`.
6. Parse stdout line by line, skipping headers, unmapped records, and optionally secondary/supplementary records.
7. Write rows to `annotations/<track-id>.db`.
8. Update manifest with `addingAnnotationTrack`, or `removingAnnotationTrack(id:)` first when replacing.
9. Return `MappedReadsAnnotationResult`.

- [ ] **Step 8: Run writer and service tests and verify GREEN**

Run:

```bash
swift test --filter MappedReadsAnnotation
```

Expected: PASS for parser, writer, and service tests.

## Task 3: CLI Command

**Files:**
- Modify: `Sources/LungfishCLI/Commands/BAMCommand.swift`
- Test: `Tests/LungfishCLITests/BAMAnnotateCommandTests.swift`
- Test: `Tests/LungfishCLITests/BAMCommandTests.swift`

- [ ] **Step 1: Write failing CLI tests**

```swift
import XCTest
import LungfishCore
import LungfishWorkflow
@testable import LungfishCLI

final class BAMAnnotateCommandTests: XCTestCase {
    func testParseAnnotateCommandDefaultsSequenceAndQualitiesOff() throws {
        let command = try BAMCommand.AnnotateSubcommand.parse([
            "annotate",
            "--bundle", "/tmp/ref.lungfishref",
            "--alignment-track", "aln_a",
            "--output-track-name", "Mapped Reads",
        ])

        XCTAssertEqual(command.bundlePath, "/tmp/ref.lungfishref")
        XCTAssertEqual(command.alignmentTrackID, "aln_a")
        XCTAssertEqual(command.outputTrackName, "Mapped Reads")
        XCTAssertTrue(command.mappedOnly)
        XCTAssertFalse(command.primaryOnly)
        XCTAssertFalse(command.includeSequence)
        XCTAssertFalse(command.includeQualities)
    }

    func testJSONRunCompleteEventContainsOutputAnnotationFields() async throws {
        let command = try BAMCommand.AnnotateSubcommand.parse([
            "annotate",
            "--bundle", "/tmp/ref.lungfishref",
            "--alignment-track", "aln_a",
            "--output-track-name", "Mapped Reads",
            "--include-sequence",
            "--output-format", "json",
        ])
        var emitted: [String] = []
        let resultTrack = AnnotationTrackInfo(
            id: "mapped_reads",
            name: "Mapped Reads",
            path: "annotations/mapped_reads.db",
            databasePath: "annotations/mapped_reads.db",
            annotationType: .custom,
            featureCount: 3
        )
        let runtime = BAMCommand.AnnotateSubcommand.Runtime { request, _ in
            XCTAssertTrue(request.includeSequence)
            XCTAssertFalse(request.includeQualities)
            return MappedReadsAnnotationResult(
                bundleURL: request.bundleURL,
                sourceAlignmentTrackID: request.sourceTrackID,
                sourceAlignmentTrackName: "Reads",
                annotationTrackInfo: resultTrack,
                databasePath: "annotations/mapped_reads.db",
                convertedRecordCount: 3,
                skippedUnmappedCount: 1,
                skippedSecondarySupplementaryCount: 2,
                includedSequence: true,
                includedQualities: false
            )
        }

        _ = try await command.executeForTesting(runtime: runtime, emit: { emitted.append($0) })

        let complete = try XCTUnwrap(emitted.compactMap(decodeAnnotateEvent).last)
        XCTAssertEqual(complete.event, "runComplete")
        XCTAssertEqual(complete.outputAnnotationTrackID, "mapped_reads")
        XCTAssertEqual(complete.convertedRecordCount, 3)
        XCTAssertTrue(complete.includedSequence ?? false)
    }
}
```

- [ ] **Step 2: Run CLI tests and verify RED**

Run:

```bash
swift test --filter BAMAnnotateCommandTests
```

Expected: FAIL with missing `AnnotateSubcommand`.

- [ ] **Step 3: Implement `bam annotate`**

Add `AnnotateSubcommand` to `BAMCommand.configuration.subcommands` and define:

- `@Option --bundle`
- `@Option --alignment-track`
- `@Option --output-track-name`
- `@Flag --primary-only`
- `@Flag --include-sequence`
- `@Flag --include-qualities`
- `@Flag --replace`
- `@OptionGroup var globalOptions: TextAndJSONGlobalOptions`

Reuse the same runtime/test pattern as `FilterSubcommand`, emitting `BAMCommand.AnnotateEvent`.

- [ ] **Step 4: Update BAM help tests**

Add assertions to `Tests/LungfishCLITests/BAMCommandTests.swift`:

```swift
XCTAssertTrue(BAMCommand.helpMessage().contains("annotate"))
XCTAssertTrue(BAMCommand.AnnotateSubcommand.helpMessage().contains("Convert mapped reads to annotations"))
XCTAssertTrue(BAMCommand.AnnotateSubcommand.helpMessage().contains("Output format: text, json"))
```

- [ ] **Step 5: Run CLI command tests and verify GREEN**

Run:

```bash
swift test --filter BAMAnnotateCommandTests
swift test --filter BAMCommandTests
```

Expected: PASS.

## Task 4: GUI Analysis Action

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Test: `Tests/LungfishAppTests/ReadStyleSectionViewModelTests.swift`

- [ ] **Step 1: Write failing view-model tests**

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class MappedReadsAnnotationInspectorStateTests: XCTestCase {
    func testMappedReadsAnnotationRequestDefaultsExcludeSequenceAndQualities() throws {
        let vm = ReadStyleSectionViewModel()
        vm.alignmentFilterTrackOptions = [
            AlignmentFilterTrackOption(id: "aln_a", name: "Reads")
        ]
        vm.selectedMappedReadsAnnotationSourceTrackID = "aln_a"
        vm.mappedReadsAnnotationOutputTrackName = "Mapped Reads"

        let request = try vm.makeMappedReadsAnnotationRequest(bundleURL: URL(fileURLWithPath: "/tmp/ref.lungfishref"))

        XCTAssertEqual(request.sourceTrackID, "aln_a")
        XCTAssertEqual(request.outputTrackName, "Mapped Reads")
        XCTAssertFalse(request.includeSequence)
        XCTAssertFalse(request.includeQualities)
    }

    func testMappedReadsAnnotationRequestHonorsOptionalSequenceAndQualities() throws {
        let vm = ReadStyleSectionViewModel()
        vm.alignmentFilterTrackOptions = [
            AlignmentFilterTrackOption(id: "aln_a", name: "Reads")
        ]
        vm.selectedMappedReadsAnnotationSourceTrackID = "aln_a"
        vm.mappedReadsAnnotationOutputTrackName = "Mapped Reads"
        vm.mappedReadsAnnotationIncludeSequence = true
        vm.mappedReadsAnnotationIncludeQualities = true

        let request = try vm.makeMappedReadsAnnotationRequest(bundleURL: URL(fileURLWithPath: "/tmp/ref.lungfishref"))

        XCTAssertTrue(request.includeSequence)
        XCTAssertTrue(request.includeQualities)
    }
}
```

- [ ] **Step 2: Run GUI state test and verify RED**

Run:

```bash
swift test --filter MappedReadsAnnotationInspectorStateTests
```

Expected: FAIL with missing view-model properties/method.

- [ ] **Step 3: Add view-model state and request construction**

Add to `ReadStyleSectionViewModel`:

```swift
public var selectedMappedReadsAnnotationSourceTrackID: String?
public var mappedReadsAnnotationOutputTrackName: String = "Mapped Reads"
public var mappedReadsAnnotationPrimaryOnly: Bool = false
public var mappedReadsAnnotationIncludeSequence: Bool = false
public var mappedReadsAnnotationIncludeQualities: Bool = false
public var mappedReadsAnnotationReplaceExisting: Bool = false
public var isMappedReadsAnnotationWorkflowRunning: Bool = false
public var onConvertMappedReadsToAnnotationsRequested: ((MappedReadsAnnotationRequest) -> Void)?
```

Add `makeMappedReadsAnnotationRequest(bundleURL:)` that validates source track and output name and returns `MappedReadsAnnotationRequest`.

- [ ] **Step 4: Add Analysis UI controls**

In `AnalysisSection`, add a new subsection or panel labeled `Convert Mapped Reads to Annotations` with:

- source `Picker`
- output `TextField`
- primary-only `Toggle`
- include sequence `Toggle`
- include qualities `Toggle`
- replace existing `Toggle`
- `Button("Convert Mapped Reads to Annotations")`

The button calls `viewModel.onConvertMappedReadsToAnnotationsRequested?(request)`.

- [ ] **Step 5: Wire Inspector workflow**

In `InspectorViewController`, wire the callback in both `updateAlignmentSection(from:)` and `updateMappingAlignmentSection(from:applySettings:)`, then implement `runConvertMappedReadsToAnnotationsWorkflow(_:)`:

```swift
let result = try await MappedReadsAnnotationService().convert(
    request: request,
    progressHandler: { progress, message in
        OperationCenter.shared.update(id: operationID, progress: progress, detail: message)
    }
)
```

On success:

- reload active mapping viewer bundle when displayed, otherwise display bundle at current URL
- clear running state
- show a concise success alert with record count and track name
- switch the Inspector tab to `.analysis`

- [ ] **Step 6: Run GUI state tests and verify GREEN**

Run:

```bash
swift test --filter MappedReadsAnnotationInspectorStateTests
```

Expected: PASS.

## Task 5: Annotation Table Attribute Columns

**Files:**
- Modify: `Sources/LungfishApp/Services/AnnotationSearchIndex.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift`
- Test: `Tests/LungfishAppTests/VariantTableEnhancementTests.swift`

- [ ] **Step 1: Write failing annotation attribute table tests**

Add tests that create an annotation DB with mapped-read attributes:

```swift
func testAnnotationDrawerPromotesMappedReadAttributeColumns() throws {
    let drawer = try makeDrawerWithAnnotationAttributes([
        "chr1\t0\t10\tread-a\t0\t+\t0\t10\t0\t1\t10,\t0,\tmapped_read\tmapq=60;flag=0;cigar=10M;tag_NM=0;tag_AS=10;read_group=rg1;source_alignment_track_name=Reads"
    ])

    drawer.switchToTab(.annotations)

    let identifiers = drawer.tableView.tableColumns.map(\.identifier.rawValue)
    XCTAssertTrue(identifiers.contains("attr_mapq"))
    XCTAssertTrue(identifiers.contains("attr_cigar"))
    XCTAssertTrue(identifiers.contains("attr_tag_NM"))
}

func testAnnotationAttributeSortUsesNumericComparison() throws {
    let drawer = try makeDrawerWithAnnotationAttributes([
        "chr1\t0\t10\tlow\t0\t+\t0\t10\t0\t1\t10,\t0,\tmapped_read\tmapq=2;tag_NM=10",
        "chr1\t20\t30\thigh\t0\t+\t20\t30\t0\t1\t10,\t0,\tmapped_read\tmapq=60;tag_NM=0"
    ])

    drawer.switchToTab(.annotations)
    drawer.tableView.sortDescriptors = [NSSortDescriptor(key: "attr_mapq", ascending: true)]
    drawer.tableView(drawer.tableView, sortDescriptorsDidChange: [])

    XCTAssertEqual(drawer.displayedAnnotations.map(\.name), ["low", "high"])
}
```

- [ ] **Step 2: Run table tests and verify RED**

Run:

```bash
swift test --filter VariantTableEnhancementTests/testAnnotationDrawerPromotesMappedReadAttributeColumns
swift test --filter VariantTableEnhancementTests/testAnnotationAttributeSortUsesNumericComparison
```

Expected: FAIL because annotation attributes are not carried into search results or columns.

- [ ] **Step 3: Carry attributes in search results**

Add `public let attributes: [String: String]?` to `AnnotationSearchIndex.SearchResult`, defaulting to nil. When building annotation results from `AnnotationDatabaseRecord`, set:

```swift
attributes: record.attributes.map(AnnotationDatabase.parseAttributes)
```

Keep variant results unchanged.

- [ ] **Step 4: Add dynamic annotation attribute columns**

In `AnnotationTableDrawerView`:

- discover keys from `displayedAnnotations.compactMap(\.attributes)`
- promote mapped-read keys in order: `read_name`, `mapq`, `cigar`, `flag`, `tag_NM`, `tag_AS`, `read_group`, `source_alignment_track_name`
- add columns with identifiers `attr_<key>`
- set sort descriptor key to the same identifier
- render cells by looking up `annotation.attributes?[key]`
- sort numeric attributes numerically for keys in `mapq`, `flag`, `pos_1_based`, `alignment_start`, `alignment_end`, `reference_length`, `query_length`, `template_length`, `mate_position_1_based`, `tag_NM`, `tag_AS`

- [ ] **Step 5: Add local filter support for annotation attribute columns**

Mirror the existing variant local filter pattern with annotation-specific clauses:

```swift
struct AnnotationColumnFilterClause {
    let key: String
    let op: String
    let value: String
}
```

Add context-menu entries for `attr_*` columns: equals, contains, greater/less numeric, empty/not empty, and clear filters. Apply filters to currently loaded annotation rows.

- [ ] **Step 6: Run table tests and verify GREEN**

Run:

```bash
swift test --filter VariantTableEnhancementTests/testAnnotationDrawerPromotesMappedReadAttributeColumns
swift test --filter VariantTableEnhancementTests/testAnnotationAttributeSortUsesNumericComparison
```

Expected: PASS.

## Task 6: Final Verification

**Files:**
- All files changed above.

- [ ] **Step 1: Run focused test suites**

Run:

```bash
swift test --filter MappedReadsSAMRecordTests
swift test --filter MappedReadsAnnotationDatabaseWriterTests
swift test --filter MappedReadsAnnotationServiceTests
swift test --filter BAMAnnotateCommandTests
swift test --filter BAMCommandTests
swift test --filter MappedReadsAnnotationInspectorStateTests
swift test --filter VariantTableEnhancementTests/testAnnotationDrawerPromotesMappedReadAttributeColumns
swift test --filter VariantTableEnhancementTests/testAnnotationAttributeSortUsesNumericComparison
```

Expected: all pass.

- [ ] **Step 2: Run broader package tests for touched areas**

Run:

```bash
swift test --filter LungfishWorkflowTests
swift test --filter LungfishCLITests
swift test --filter LungfishAppTests
```

Expected: all pass, or report unrelated pre-existing failures with exact failing test names.

- [ ] **Step 3: Manual CLI smoke test on a temporary fixture**

Build CLI:

```bash
swift build --product lungfish-cli
```

Run the command against a small test bundle created by the service tests:

```bash
.build/debug/lungfish-cli bam annotate \
  --bundle /tmp/mapped-read-fixture.lungfishref \
  --alignment-track aln_a \
  --output-track-name "Mapped Reads" \
  --output-format json
```

Expected: JSON `runComplete` event with `convertedRecordCount > 0`, and `manifest.json` contains the new annotation track with a database path under `annotations/`.

- [ ] **Step 4: Inspect final diff**

Run:

```bash
git diff --stat
git diff -- Sources/LungfishWorkflow/Alignment Sources/LungfishCLI/Commands/BAMCommand.swift Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift Sources/LungfishApp/Views/Inspector/InspectorViewController.swift Sources/LungfishApp/Services/AnnotationSearchIndex.swift Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift
```

Expected: only mapped-read annotation conversion changes, with no unrelated edits or reversions.
