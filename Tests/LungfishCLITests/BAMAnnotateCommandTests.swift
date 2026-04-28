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

    func testAnnotateBestCommandPassesRequestToRuntimeAndEmitsRunCompleteJSON() async throws {
        let command = try BAMCommand.AnnotateBestSubcommand.parse([
            "annotate-best",
            "--bundle", "/tmp/Input.lungfishref",
            "--mapping-result", "/tmp/mapping",
            "--output-bundle", "/tmp/Output.lungfishref",
            "--output-track-name", "miSeq MHC",
            "--primary-only",
            "--replace",
            "--format", "json",
        ])

        let runtime = BAMCommand.AnnotateBestSubcommand.Runtime(
            runAnnotateBest: { request in
                XCTAssertEqual(request.sourceBundleURL, URL(fileURLWithPath: "/tmp/Input.lungfishref"))
                XCTAssertEqual(request.mappingResultURL, URL(fileURLWithPath: "/tmp/mapping"))
                XCTAssertEqual(request.outputBundleURL, URL(fileURLWithPath: "/tmp/Output.lungfishref"))
                XCTAssertEqual(request.outputTrackName, "miSeq MHC")
                XCTAssertTrue(request.primaryOnly)
                XCTAssertTrue(request.replaceExisting)

                return BestMappedReadsAnnotationResult(
                    sourceBundleURL: URL(fileURLWithPath: "/tmp/Input.lungfishref"),
                    mappingResultURL: URL(fileURLWithPath: "/tmp/mapping"),
                    outputBundleURL: URL(fileURLWithPath: "/tmp/Output.lungfishref"),
                    annotationTrackInfo: AnnotationTrackInfo(
                        id: "ann-best",
                        name: "miSeq MHC",
                        path: "annotations/ann-best.db",
                        databasePath: "annotations/ann-best.db",
                        annotationType: .custom,
                        featureCount: 7
                    ),
                    databasePath: "annotations/ann-best.db",
                    convertedRecordCount: 7,
                    candidateRecordCount: 9,
                    selectedRecordCount: 7,
                    skippedUnmappedCount: 1,
                    skippedSecondarySupplementaryCount: 2
                )
            }
        )

        var lines: [String] = []
        _ = try await command.executeForTesting(runtime: runtime) { lines.append($0) }

        let runComplete = try XCTUnwrap(
            lines
                .compactMap(decodeAnnotateBestEvent)
                .first(where: { $0.event == "runComplete" })
        )
        XCTAssertEqual(runComplete.sourceBundlePath, "/tmp/Input.lungfishref")
        XCTAssertEqual(runComplete.mappingResultPath, "/tmp/mapping")
        XCTAssertEqual(runComplete.outputBundlePath, "/tmp/Output.lungfishref")
        XCTAssertEqual(runComplete.outputAnnotationTrackID, "ann-best")
        XCTAssertEqual(runComplete.outputAnnotationTrackName, "miSeq MHC")
        XCTAssertEqual(runComplete.convertedRecordCount, 7)
        XCTAssertEqual(runComplete.candidateRecordCount, 9)
        XCTAssertEqual(runComplete.selectedRecordCount, 7)
    }

    func testAnnotateCDSBestCommandPassesRequestToRuntimeAndEmitsRunCompleteJSON() async throws {
        let command = try BAMCommand.AnnotateCDSBestSubcommand.parse([
            "annotate-cds-best",
            "--bundle", "/tmp/Input.lungfishref",
            "--mapping-result", "/tmp/cds-mapping",
            "--output-bundle", "/tmp/Output.lungfishref",
            "--output-track-name", "IPD CDS",
            "--include-secondary",
            "--min-query-cover", "0.95",
            "--replace",
            "--format", "json",
        ])

        let runtime = BAMCommand.AnnotateCDSBestSubcommand.Runtime(
            runAnnotateCDSBest: { request in
                XCTAssertEqual(request.sourceBundleURL, URL(fileURLWithPath: "/tmp/Input.lungfishref"))
                XCTAssertEqual(request.mappingResultURL, URL(fileURLWithPath: "/tmp/cds-mapping"))
                XCTAssertEqual(request.outputBundleURL, URL(fileURLWithPath: "/tmp/Output.lungfishref"))
                XCTAssertEqual(request.outputTrackName, "IPD CDS")
                XCTAssertTrue(request.includeSecondary)
                XCTAssertFalse(request.includeSupplementary)
                XCTAssertEqual(request.minimumQueryCoverage, 0.95)
                XCTAssertTrue(request.replaceExisting)

                return CDSBestAnnotationResult(
                    sourceBundleURL: URL(fileURLWithPath: "/tmp/Input.lungfishref"),
                    mappingResultURL: URL(fileURLWithPath: "/tmp/cds-mapping"),
                    outputBundleURL: URL(fileURLWithPath: "/tmp/Output.lungfishref"),
                    annotationTrackInfo: AnnotationTrackInfo(
                        id: "ann-cds",
                        name: "IPD CDS",
                        path: "annotations/ann-cds.db",
                        databasePath: "annotations/ann-cds.db",
                        annotationType: .custom,
                        featureCount: 15
                    ),
                    databasePath: "annotations/ann-cds.db",
                    geneCount: 5,
                    cdsCount: 10,
                    candidateRecordCount: 20,
                    selectedLocusCount: 5,
                    skippedUnmappedCount: 1,
                    skippedSecondaryCount: 0,
                    skippedSupplementaryCount: 2
                )
            }
        )

        var lines: [String] = []
        _ = try await command.executeForTesting(runtime: runtime) { lines.append($0) }

        let runComplete = try XCTUnwrap(
            lines
                .compactMap(decodeAnnotateCDSBestEvent)
                .first(where: { $0.event == "runComplete" })
        )
        XCTAssertEqual(runComplete.outputAnnotationTrackID, "ann-cds")
        XCTAssertEqual(runComplete.outputAnnotationTrackName, "IPD CDS")
        XCTAssertEqual(runComplete.geneCount, 5)
        XCTAssertEqual(runComplete.cdsCount, 10)
        XCTAssertEqual(runComplete.candidateRecordCount, 20)
        XCTAssertEqual(runComplete.selectedLocusCount, 5)
    }
}

private func decodeAnnotateEvent(_ line: String) -> BAMCommand.AnnotateEvent? {
    guard let data = line.data(using: .utf8) else {
        return nil
    }
    return try? JSONDecoder().decode(BAMCommand.AnnotateEvent.self, from: data)
}

private func decodeAnnotateBestEvent(_ line: String) -> BAMCommand.AnnotateBestEvent? {
    guard let data = line.data(using: .utf8) else {
        return nil
    }
    return try? JSONDecoder().decode(BAMCommand.AnnotateBestEvent.self, from: data)
}

private func decodeAnnotateCDSBestEvent(_ line: String) -> BAMCommand.AnnotateCDSBestEvent? {
    guard let data = line.data(using: .utf8) else {
        return nil
    }
    return try? JSONDecoder().decode(BAMCommand.AnnotateCDSBestEvent.self, from: data)
}
