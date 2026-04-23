import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishWorkflow

final class BAMAnnotateCommandTests: XCTestCase {
    func testAnnotateCommandPassesRequestToRuntimeAndEmitsRunCompleteJSON() async throws {
        let command = try BAMCommand.AnnotateSubcommand.parse([
            "annotate",
            "--bundle", "/tmp/Test.lungfishref",
            "--alignment-track", "aln-1",
            "--output-track-name", "Mapped Reads",
            "--primary-only",
            "--include-sequence",
            "--include-qualities",
            "--replace",
            "--format", "json",
        ])

        let runtime = BAMCommand.AnnotateSubcommand.Runtime(
            runAnnotate: { request in
                XCTAssertEqual(request.bundleURL, URL(fileURLWithPath: "/tmp/Test.lungfishref"))
                XCTAssertEqual(request.sourceTrackID, "aln-1")
                XCTAssertEqual(request.outputTrackName, "Mapped Reads")
                XCTAssertTrue(request.primaryOnly)
                XCTAssertTrue(request.includeSequence)
                XCTAssertTrue(request.includeQualities)
                XCTAssertTrue(request.replaceExisting)

                return MappedReadsAnnotationResult(
                    bundleURL: URL(fileURLWithPath: "/tmp/Test.lungfishref"),
                    sourceAlignmentTrackID: "aln-1",
                    sourceAlignmentTrackName: "Source BAM",
                    annotationTrackInfo: AnnotationTrackInfo(
                        id: "ann-mapped",
                        name: "Mapped Reads",
                        path: "annotations/ann-mapped.db",
                        databasePath: "annotations/ann-mapped.db",
                        annotationType: .custom,
                        featureCount: 11
                    ),
                    databasePath: "annotations/ann-mapped.db",
                    convertedRecordCount: 11,
                    skippedUnmappedCount: 2,
                    skippedSecondarySupplementaryCount: 3,
                    includedSequence: true,
                    includedQualities: true
                )
            }
        )

        var lines: [String] = []
        _ = try await command.executeForTesting(runtime: runtime) { lines.append($0) }

        let runComplete = try XCTUnwrap(
            lines
                .compactMap(decodeAnnotateEvent)
                .first(where: { $0.event == "runComplete" })
        )
        XCTAssertEqual(runComplete.bundlePath, "/tmp/Test.lungfishref")
        XCTAssertEqual(runComplete.sourceAlignmentTrackID, "aln-1")
        XCTAssertEqual(runComplete.sourceAlignmentTrackName, "Source BAM")
        XCTAssertEqual(runComplete.outputAnnotationTrackID, "ann-mapped")
        XCTAssertEqual(runComplete.outputAnnotationTrackName, "Mapped Reads")
        XCTAssertEqual(runComplete.databasePath, "/tmp/Test.lungfishref/annotations/ann-mapped.db")
        XCTAssertEqual(runComplete.convertedRecordCount, 11)
        XCTAssertEqual(runComplete.skippedUnmappedCount, 2)
        XCTAssertEqual(runComplete.skippedSecondarySupplementaryCount, 3)
        XCTAssertEqual(runComplete.includedSequence, true)
        XCTAssertEqual(runComplete.includedQualities, true)
    }

    func testAnnotateCommandEmitsTextSummary() async throws {
        let command = try BAMCommand.AnnotateSubcommand.parse([
            "annotate",
            "--bundle", "/tmp/Test.lungfishref",
            "--alignment-track", "aln-1",
            "--output-track-name", "Mapped Reads",
        ])
        let runtime = BAMCommand.AnnotateSubcommand.Runtime(
            runAnnotate: { _ in
                MappedReadsAnnotationResult(
                    bundleURL: URL(fileURLWithPath: "/tmp/Test.lungfishref"),
                    sourceAlignmentTrackID: "aln-1",
                    sourceAlignmentTrackName: "Source BAM",
                    annotationTrackInfo: AnnotationTrackInfo(
                        id: "ann-mapped",
                        name: "Mapped Reads",
                        path: "annotations/ann-mapped.db",
                        databasePath: "annotations/ann-mapped.db",
                        annotationType: .custom,
                        featureCount: 1
                    ),
                    databasePath: "annotations/ann-mapped.db",
                    convertedRecordCount: 1,
                    skippedUnmappedCount: 0,
                    skippedSecondarySupplementaryCount: 0,
                    includedSequence: false,
                    includedQualities: false
                )
            }
        )

        var lines: [String] = []
        _ = try await command.executeForTesting(runtime: runtime) { lines.append($0) }

        XCTAssertTrue(lines.contains("Created annotation track 'Mapped Reads' (ann-mapped) from mapped reads."))
        XCTAssertTrue(lines.contains("Bundle: /tmp/Test.lungfishref"))
        XCTAssertTrue(lines.contains("Source alignment track: aln-1 (Source BAM)"))
        XCTAssertTrue(lines.contains("Database: /tmp/Test.lungfishref/annotations/ann-mapped.db"))
        XCTAssertTrue(lines.contains("Converted reads: 1"))
    }
}

private func decodeAnnotateEvent(_ line: String) -> BAMCommand.AnnotateEvent? {
    guard let data = line.data(using: .utf8) else {
        return nil
    }
    return try? JSONDecoder().decode(BAMCommand.AnnotateEvent.self, from: data)
}
