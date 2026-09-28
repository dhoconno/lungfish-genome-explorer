import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class MapCommandTests: XCTestCase {
    // `--format json` used to print the text report, and no output form gave
    // the id of the alignment track the BAM was attached as.
    func testReportCarriesPathsCountsAndTheAttachedTrackAndEncodesAsJSON() throws {
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.rawValue,
            inputFASTQURLs: [URL(fileURLWithPath: "/scratch/materialized.fastq")],
            originalInputFASTQURLs: [URL(fileURLWithPath: "/proj/Imports/s.lungfishfastq")],
            referenceFASTAURL: URL(fileURLWithPath: "/proj/Reference Sequences/r.lungfishref/genome/sequence.fa"),
            projectURL: URL(fileURLWithPath: "/proj"),
            outputDirectory: URL(fileURLWithPath: "/proj/Analyses/minimap2-2026-09-27T10-00-00"),
            sampleName: "s",
            threads: 4
        )
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.rawValue,
            sourceReferenceBundleURL: URL(fileURLWithPath: "/proj/Reference Sequences/r.lungfishref"),
            viewerBundleURL: URL(fileURLWithPath: "/proj/Analyses/minimap2-2026-09-27T10-00-00/r.lungfishref"),
            bamURL: URL(fileURLWithPath: "/proj/Analyses/minimap2-2026-09-27T10-00-00/s.sorted.bam"),
            baiURL: URL(fileURLWithPath: "/proj/Analyses/minimap2-2026-09-27T10-00-00/s.sorted.bam.bai"),
            totalReads: 200,
            mappedReads: 150,
            unmappedReads: 50,
            wallClockSeconds: 3.5,
            contigs: []
        )
        let track = AlignmentTrackInfo(
            id: "aln_1a2b3c4d",
            name: "minimap2 Mapping",
            format: .bam,
            sourcePath: "alignments/aln_1a2b3c4d.sorted.bam",
            indexPath: "alignments/aln_1a2b3c4d.sorted.bam.bai"
        )

        let report = MapCommand.Report(
            published: MapCommand.PublishedLayout(result: result, trackInfo: track),
            request: request
        )

        XCTAssertEqual(report.alignmentTrack?.id, "aln_1a2b3c4d")
        XCTAssertEqual(report.alignmentTrack?.name, "minimap2 Mapping")
        XCTAssertEqual(report.outputDirectory, "/proj/Analyses/minimap2-2026-09-27T10-00-00")
        XCTAssertEqual(report.inputFiles, ["/proj/Imports/s.lungfishfastq"], "the user's inputs, not the scratch copy")
        XCTAssertEqual(report.sortedBAM, result.bamURL.path)
        XCTAssertEqual(report.viewerBundle, result.viewerBundleURL?.path)
        XCTAssertEqual(report.totalReads, 200)
        XCTAssertEqual(report.mappedReads, 150)
        XCTAssertEqual(report.mappingRate, 0.75)

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        let trackJSON = json?["alignmentTrack"] as? [String: Any]
        XCTAssertEqual(trackJSON?["id"] as? String, "aln_1a2b3c4d")
        XCTAssertEqual(json?["outputDirectory"] as? String, "/proj/Analyses/minimap2-2026-09-27T10-00-00")
        XCTAssertEqual(json?["mappedReads"] as? Int, 150)

        // The text table names the track id too.
        let rows = Dictionary(uniqueKeysWithValues: report.textRows)
        XCTAssertEqual(rows["Track ID"], "aln_1a2b3c4d")
        XCTAssertEqual(rows["Track name"], "minimap2 Mapping")
        XCTAssertEqual(rows["Analysis folder"], "/proj/Analyses/minimap2-2026-09-27T10-00-00")
        XCTAssertEqual(rows["Mapped reads"], "150 (75.00%)")

        // Without a viewer bundle there is no track to report.
        let bare = MapCommand.Report(
            published: MapCommand.PublishedLayout(result: result, trackInfo: nil),
            request: request
        )
        XCTAssertNil(bare.alignmentTrack)
        XCTAssertFalse(bare.textRows.contains { $0.0 == "Track ID" })
    }

    func testParsesExpandedReadGroupFlags() throws {
        let command = try MapCommand.parse([
            "/tmp/reads_R1.fastq.gz",
            "/tmp/reads_R2.fastq.gz",
            "--reference", "/tmp/reference.fa",
            "--paired",
            "--sample-name", "sample-1",
            "--rg-id", "rg-1",
            "--rg-sm", "sample-rg",
            "--rg-lb", "lib-1",
            "--rg-pl", "ILLUMINA",
            "--rg-pu", "unit-1",
        ])

        XCTAssertEqual(command.sampleName, "sample-1")
        XCTAssertEqual(command.readGroupID, "rg-1")
        XCTAssertEqual(command.readGroupSampleName, "sample-rg")
        XCTAssertEqual(command.readGroupLibrary, "lib-1")
        XCTAssertEqual(command.readGroupPlatform, "ILLUMINA")
        XCTAssertEqual(command.readGroupPlatformUnit, "unit-1")
    }

    func testReadLayoutDefaultsToAutoAndMapsToTheSharedLayout() throws {
        let auto = try MapCommand.parse(["/tmp/reads.lungfishfastq", "--reference", "/tmp/reference.fa"])
        XCTAssertEqual(auto.readLayout, .auto)
        XCTAssertNil(auto.readLayout.explicitLayout)

        let expectations: [(String, MapCommand.MapReadLayoutArgument, FASTQInputLayout)] = [
            ("single-end", .singleEnd, .singleEnd),
            ("interleaved", .interleaved, .strictlyInterleaved),
            ("mixed", .mixed, .mixedMergedAndPairs),
        ]
        for (argument, expectedArgument, expectedLayout) in expectations {
            let command = try MapCommand.parse([
                "/tmp/reads.lungfishfastq",
                "--reference", "/tmp/reference.fa",
                "--read-layout", argument,
            ])
            XCTAssertEqual(command.readLayout, expectedArgument, argument)
            XCTAssertEqual(command.readLayout.explicitLayout, expectedLayout, argument)
        }
        XCTAssertThrowsError(try MapCommand.parse([
            "/tmp/reads.lungfishfastq",
            "--reference", "/tmp/reference.fa",
            "--read-layout", "paired",
        ]))
    }

    /// A run that fails after creating `Analyses/<mapper>-<timestamp>/` used
    /// to leave the folder behind holding only analysis-metadata.json, which
    /// the sidebar listed as an ordinary analysis.
    func testFailedRunRemovesTheAnalysisFolderItCreated() async throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-failed-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let reads = project.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let reference = project.appendingPathComponent("ref.fasta")
        try ">ref\nACGTACGT\n".write(to: reference, atomically: true, encoding: .utf8)

        let command = try MapCommand.parse([
            reads.path,
            "--reference", reference.path,
            "--project", project.path,
            "--preset", "not-a-preset",
            "--quiet",
        ])
        do {
            try await command.run()
            XCTFail("an unknown preset must fail the run")
        } catch {}

        XCTAssertTrue(try AnalysesFolder.listAnalyses(in: project).isEmpty)
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: analyses.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "left behind: \(leftovers)")
    }
}
