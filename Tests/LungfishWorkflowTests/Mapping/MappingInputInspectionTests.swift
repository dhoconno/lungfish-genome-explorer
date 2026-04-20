import XCTest
@testable import LungfishWorkflow

final class MappingInputInspectionTests: XCTestCase {

    func testInspectDetectsReadClassAndObservedMaxReadLength() throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }

        let illuminaFASTQ = try fixture.writeFASTQ(
            name: "illumina.fastq",
            header: "@A00488:385:HKGCLDRXX:1:1101:1000:1000 1:N:0:1",
            sequenceLength: 151
        )

        let inspection = MappingInputInspection.inspect(urls: [illuminaFASTQ])

        XCTAssertEqual(inspection.readClass, .illuminaShortReads)
        XCTAssertEqual(inspection.observedMaxReadLength, 151)
        XCTAssertFalse(inspection.mixedReadClasses)
    }

    func testInspectFlagsMixedReadClasses() throws {
        let fixture = try MappingFASTQFixture()
        defer { fixture.cleanup() }

        let illuminaFASTQ = try fixture.writeFASTQ(
            name: "illumina.fastq",
            header: "@A00488:385:HKGCLDRXX:1:1101:1000:1000 1:N:0:1",
            sequenceLength: 151
        )
        let ontFASTQ = try fixture.writeFASTQ(
            name: "ont.fastq",
            header: "@0d4c6f0e-1234-5678-9abc-def012345678 runid=test flow_cell_id=FLO-MIN106 start_time=2026-04-19T00:00:00Z",
            sequenceLength: 1_200
        )

        let inspection = MappingInputInspection.inspect(urls: [illuminaFASTQ, ontFASTQ])

        XCTAssertNil(inspection.readClass)
        XCTAssertEqual(inspection.observedMaxReadLength, 1_200)
        XCTAssertTrue(inspection.mixedReadClasses)
    }
}

private struct MappingFASTQFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mapping-fastq-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeFASTQ(name: String, header: String, sequenceLength: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        let sequence = String(repeating: "A", count: sequenceLength)
        let quality = String(repeating: "I", count: sequenceLength)
        let text = "\(header)\n\(sequence)\n+\n\(quality)\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
