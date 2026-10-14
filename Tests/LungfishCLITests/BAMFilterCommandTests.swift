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
            "--output-track-id", "aln_exact",
            "--mapped-only",
            "--primary-only",
            "--min-mapq", "30",
            "--remove-duplicates",
            "--exact-match",
            "--format", "json",
        ])

        let runtime = BAMCommand.FilterSubcommand.Runtime(
            runFilter: { target, sourceTrackID, outputTrackName, outputTrackID, request, progress in
                progress(0.55, "Filtering alignments...")
                XCTAssertEqual(target, .bundle(URL(fileURLWithPath: "/tmp/Test.lungfishref")))
                XCTAssertEqual(sourceTrackID, "aln-1")
                XCTAssertEqual(outputTrackName, "Exact Match Reads")
                XCTAssertEqual(outputTrackID, "aln_exact")
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

        // Since Phase 2.10 lane A54 the leaf prints CLIEvent lines under --format json: a start with the
        // row's first detail, the service's stages as progress events, and a complete that names the
        // derived BAM first, then its index and its statistics database.
        let events = try lines.compactMap { try CLIEventLineDecoder().decode(line: $0) }
        XCTAssertEqual(
            events,
            [
                .start(message: "Preparing Exact Match Reads..."),
                .progress(fraction: 0.55, message: "Filtering alignments..."),
                .complete(
                    outputs: [
                        "/tmp/Test.lungfishref/alignments/filtered/aln-derived.bam",
                        "/tmp/Test.lungfishref/alignments/filtered/aln-derived.bam.bai",
                        "/tmp/Test.lungfishref/alignments/filtered/aln-derived.stats.db",
                    ],
                    message: "Created filtered alignment track \"Exact Match Reads\"."
                ),
            ]
        )
        XCTAssertEqual(lines.count, 3, "standard output holds event lines and nothing else")
    }

    func testFilterCommandPassesMappingResultTargetAndEmitsTextLines() async throws {
        let command = try BAMCommand.FilterSubcommand.parse([
            "filter",
            "--mapping-result", "/tmp/Run",
            "--alignment-track", "aln-2",
            "--output-track-name", "Identity >= 99",
            "--mapped-only",
            "--exclude-marked-duplicates",
            "--min-percent-identity", "99",
        ])

        let runtime = BAMCommand.FilterSubcommand.Runtime(
            runFilter: { target, sourceTrackID, outputTrackName, outputTrackID, request, _ in
                XCTAssertEqual(target, .mappingResult(URL(fileURLWithPath: "/tmp/Run")))
                XCTAssertEqual(sourceTrackID, "aln-2")
                XCTAssertEqual(outputTrackName, "Identity >= 99")
                XCTAssertNil(outputTrackID)
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
                    mappingResultURL: URL(fileURLWithPath: "/tmp/Run"),
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
        XCTAssertTrue(lines.contains("Mapping result: /tmp/Run"))
        XCTAssertTrue(lines.contains("BAM: /tmp/Test.lungfishref/alignments/filtered/aln-derived-99.bam"))
        XCTAssertTrue(lines.contains("BAI: /tmp/Test.lungfishref/alignments/filtered/aln-derived-99.bam.bai"))
        XCTAssertTrue(lines.contains("Metadata DB: /tmp/Test.lungfishref/alignments/filtered/aln-derived-99.stats.db"))
    }
}
