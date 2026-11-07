// DemultiplexDialogDefaultArgvTests.swift - The dialog leaves the search route to the route owner unless a person picks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXRUN (L4). The dialog wrote `--engine cutadapt` on every run, so a run of the default kit
// searched the read bases even when the read names carry the kit's index.

import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

final class DemultiplexDialogDefaultArgvTests: XCTestCase {
    private func request(
        engine: DemultiplexEngine, input: URL = URL(fileURLWithPath: "/tmp/reads.lungfishfastq")
    ) -> FASTQOperationLaunchRequest {
        // The dialog's defaults (`FASTQOperationDialogState` init) for a built-in kit.
        .derivative(
            request: .demultiplex(
                kitID: "truseq-single-a",
                customCSVPath: nil,
                location: "bothends",
                symmetryMode: nil,
                maxDistanceFrom5Prime: 0,
                maxDistanceFrom3Prime: 0,
                errorRate: 0.15,
                engine: engine,
                trimBarcodes: true,
                sampleAssignments: nil,
                kitOverride: nil
            ),
            inputURLs: [input],
            outputMode: .groupedResult
        )
    }

    func testDialogDefaultArgvOfTheDefaultKitAsksTheRouteOwner() throws {
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: request(engine: .cutadapt))
        XCTAssertEqual(Array(invocation.arguments.prefix(1)), ["demultiplex"])
        XCTAssertFalse(invocation.arguments.contains("--engine"), "\(invocation.arguments)")
        let kitIndex = try XCTUnwrap(invocation.arguments.firstIndex(of: "--kit"))
        XCTAssertEqual(invocation.arguments[kitIndex + 1], "truseq-single-a")
        XCTAssertTrue(invocation.arguments.contains("--error-rate"))
    }

    /// A Read Names pick is written as `--engine header-index`, with none of the options of a search of the bases,
    /// so the run takes the header route the person chose and its record says so (DEMUXSPLIT Handoff 1).
    func testReadNamesPickWritesTheHeaderEngineAndNoBaseSearchOption() throws {
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: request(engine: .headerIndex))
        let engineIndex = try XCTUnwrap(invocation.arguments.firstIndex(of: "--engine"), "\(invocation.arguments)")
        XCTAssertEqual(invocation.arguments[engineIndex + 1], "header-index")
        for option in ["--location", "--max-distance-5prime", "--max-distance-3prime", "--error-rate", "--no-trim"] {
            XCTAssertFalse(invocation.arguments.contains(option), "\(option) in \(invocation.arguments)")
        }
    }

    /// The split by the read names chooses the i5 orientation of each file of a bundle, so a Read Names pick passes a
    /// multi-file bundle whole and the dialog does not join its files first (BIO-DEMUX-PARITY section 3, S3).
    func testReadNamesPickPassesAMultiFileBundleWhole() {
        XCTAssertTrue(request(engine: .headerIndex).allowsDirectMultiFileFASTQBundleInput)
        XCTAssertFalse(request(engine: .cutadapt).allowsDirectMultiFileFASTQBundleInput)
    }

    /// The dialog's default argv, run by the CLI on L6's mixed fixture, takes the header route and records it. At
    /// 2b1e3e6ec the same run stopped in the floor's read-name refusal (DEMUXSPLIT Handoff 2).
    func testDialogDefaultArgvOfTheDefaultKitTakesTheHeaderRoute() async throws {
        let root = try TestTempDirectory.make(prefix: "demux-dialog-header")
        defer { TestTempDirectory.cleanup(root) }
        // L6's mixed fixture (`DemuxFloorFixtures.mixedHeaderNames` in the Workflow tests, which this target cannot
        // see): 1,000 names carry D701, 100 D702, 20 D701 at one mismatch and 10 an index of N.
        let bases = Array("ACGT")
        var indexes = Array(repeating: "ATTACTCG", count: 1_000) + Array(repeating: "TCCGGAGA", count: 100)
        for k in 0..<20 {
            var index = Array("ATTACTCG")
            index[k % 8] = bases[(bases.firstIndex(of: index[k % 8])! + 1 + k / 8) % 4]
            indexes.append(String(index))
        }
        indexes += Array(repeating: "NNNNNNNN", count: 10)
        let sequence = String(repeating: "GATTACA", count: 21)
        let quality = String(repeating: "I", count: sequence.count)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("mixed.fastq")
        try indexes.enumerated().map { "@r\($0.offset) 1:N:0:\($0.element)\n\(sequence)\n+\n\(quality)\n" }.joined()
            .write(to: input, atomically: true, encoding: .utf8)
        let output = project.appendingPathComponent("Analyses/demux", isDirectory: true)

        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: request(engine: .cutadapt, input: input), outputTargetPath: output.path
        )
        XCTAssertFalse(invocation.arguments.contains("--engine"), "\(invocation.arguments)")
        var command = try FastqDemultiplexSubcommand.parse(Array(invocation.arguments.dropFirst()))
        try await command.run()

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        let engineIndex = try XCTUnwrap(provenance.argv.firstIndex(of: "--engine"), "\(provenance.argv)")
        XCTAssertEqual(provenance.argv[engineIndex + 1], "header-index")
        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output))
        let counts = Dictionary(uniqueKeysWithValues: manifest.barcodes.filter { $0.readCount > 0 }.map { ($0.barcodeID, $0.readCount) })
        XCTAssertEqual(counts, ["D701": 1_020, "D702": 100])
        XCTAssertEqual(manifest.unassigned.readCount, 10)
    }
}
