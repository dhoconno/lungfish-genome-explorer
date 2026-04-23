import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishWorkflow

final class BAMFilterCommandTests: XCTestCase {
    func testFilterCommandPassesBundleRequestToRuntimeAndEmitsRunCompleteJSON() async throws {
        let command = try BAMCommand.FilterSubcommand.parse([
            "filter",
            "--bundle", "/tmp/Test.lungfishref",
            "--alignment-track", "aln-1",
            "--output-track-name", "Exact Match Reads",
            "--mapped-only",
            "--primary-only",
            "--min-mapq", "30",
            "--remove-duplicates",
            "--exact-match",
            "--format", "json",
        ])

        let runtime = BAMCommand.FilterSubcommand.Runtime(
            runFilter: { target, sourceTrackID, outputTrackName, request in
                XCTAssertEqual(target, .bundle(URL(fileURLWithPath: "/tmp/Test.lungfishref")))
                XCTAssertEqual(sourceTrackID, "aln-1")
                XCTAssertEqual(outputTrackName, "Exact Match Reads")
                XCTAssertEqual(
                    request,
                    AlignmentFilterRequest(
                        mappedOnly: true,
                        primaryOnly: true,
                        minimumMAPQ: 30,
                        duplicateMode: .remove,
                        identityFilter: .exactMatch,
                        region: nil
                    )
                )

                return BundleAlignmentFilterResult(
                    bundleURL: URL(fileURLWithPath: "/tmp/Test.lungfishref"),
                    mappingResultURL: nil,
                    trackInfo: AlignmentTrackInfo(
                        id: "aln-derived",
                        name: "Exact Match Reads",
                        format: .bam,
                        sourcePath: "alignments/filtered/aln-derived.bam",
                        indexPath: "alignments/filtered/aln-derived.bam.bai",
                        metadataDBPath: "alignments/filtered/aln-derived.stats.db"
                    ),
                    commandHistory: []
                )
            }
        )

        var lines: [String] = []
        _ = try await command.executeForTesting(runtime: runtime) { lines.append($0) }

        let runComplete = try XCTUnwrap(
            lines
                .compactMap(decodeEvent)
                .first(where: { $0.event == "runComplete" })
        )
        XCTAssertEqual(runComplete.bundlePath, "/tmp/Test.lungfishref")
        XCTAssertNil(runComplete.mappingResultPath)
        XCTAssertEqual(runComplete.sourceAlignmentTrackID, "aln-1")
        XCTAssertEqual(runComplete.outputAlignmentTrackID, "aln-derived")
        XCTAssertEqual(runComplete.outputAlignmentTrackName, "Exact Match Reads")
        XCTAssertEqual(runComplete.bamPath, "/tmp/Test.lungfishref/alignments/filtered/aln-derived.bam")
        XCTAssertEqual(runComplete.baiPath, "/tmp/Test.lungfishref/alignments/filtered/aln-derived.bam.bai")
        XCTAssertEqual(runComplete.metadataDBPath, "/tmp/Test.lungfishref/alignments/filtered/aln-derived.stats.db")
    }

    func testFilterCommandPassesMappingResultTargetAndEmitsTextLines() async throws {
        let command = try BAMCommand.FilterSubcommand.parse([
            "filter",
            "--mapping-result", "/tmp/Run/mapping-result.json",
            "--alignment-track", "aln-2",
            "--output-track-name", "Identity >= 99",
            "--mapped-only",
            "--exclude-marked-duplicates",
            "--min-percent-identity", "99",
        ])

        let runtime = BAMCommand.FilterSubcommand.Runtime(
            runFilter: { target, sourceTrackID, outputTrackName, request in
                XCTAssertEqual(target, .mappingResult(URL(fileURLWithPath: "/tmp/Run/mapping-result.json")))
                XCTAssertEqual(sourceTrackID, "aln-2")
                XCTAssertEqual(outputTrackName, "Identity >= 99")
                XCTAssertEqual(
                    request,
                    AlignmentFilterRequest(
                        mappedOnly: true,
                        primaryOnly: false,
                        minimumMAPQ: nil,
                        duplicateMode: .exclude,
                        identityFilter: .minimumPercentIdentity(99),
                        region: nil
                    )
                )

                return BundleAlignmentFilterResult(
                    bundleURL: URL(fileURLWithPath: "/tmp/Test.lungfishref"),
                    mappingResultURL: URL(fileURLWithPath: "/tmp/Run/mapping-result.json"),
                    trackInfo: AlignmentTrackInfo(
                        id: "aln-derived-99",
                        name: "Identity >= 99",
                        format: .bam,
                        sourcePath: "alignments/filtered/aln-derived-99.bam",
                        indexPath: "alignments/filtered/aln-derived-99.bam.bai",
                        metadataDBPath: "alignments/filtered/aln-derived-99.stats.db"
                    ),
                    commandHistory: []
                )
            }
        )

        var lines: [String] = []
        _ = try await command.executeForTesting(runtime: runtime) { lines.append($0) }

        XCTAssertTrue(lines.contains("Created filtered BAM track 'Identity >= 99' (aln-derived-99)."))
        XCTAssertTrue(lines.contains("Bundle: /tmp/Test.lungfishref"))
        XCTAssertTrue(lines.contains("Mapping result: /tmp/Run/mapping-result.json"))
        XCTAssertTrue(lines.contains("BAM: /tmp/Test.lungfishref/alignments/filtered/aln-derived-99.bam"))
        XCTAssertTrue(lines.contains("BAI: /tmp/Test.lungfishref/alignments/filtered/aln-derived-99.bam.bai"))
        XCTAssertTrue(lines.contains("Metadata DB: /tmp/Test.lungfishref/alignments/filtered/aln-derived-99.stats.db"))
    }
}

private func decodeEvent(_ line: String) -> BAMCommand.FilterEvent? {
    guard let data = line.data(using: .utf8) else {
        return nil
    }
    return try? JSONDecoder().decode(BAMCommand.FilterEvent.self, from: data)
}
