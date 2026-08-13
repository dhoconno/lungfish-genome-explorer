import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO

/// Portable regressions distilled from the Zhang pan-genome project layout.
/// The original external volume is deliberately not consulted: every test
/// constructs the minimum representative project tree in its temporary root.
final class ZhangArtifactCanaryTests: XCTestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZhangArtifactCanary-\(UUID().uuidString).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let projectURL { try? FileManager.default.removeItem(at: projectURL) }
        projectURL = nil
    }

    func testPanGenomeBatchGenBankExportPlanIsCompleteWithoutWritingOutputs() throws {
        let panGenomesURL = projectURL.appendingPathComponent("Zhang pan-genomes", isDirectory: true)
        try FileManager.default.createDirectory(at: panGenomesURL, withIntermediateDirectories: true)
        let bundles = (0..<20).map { index in
            panGenomesURL.appendingPathComponent(
                index == 0 ? "T2T-MFA8v1_0.lungfishref" : "synthetic-\(index).lungfishref",
                isDirectory: true
            )
        }
        for bundle in bundles {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        }

        let outputFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZhangExportPlan-\(UUID().uuidString)", isDirectory: true)
        let targets = AppDelegate.batchSequenceExportTargets(
            for: bundles,
            outputFolder: outputFolder,
            format: .genbank,
            compression: .none
        )
        let commands = AppDelegate.batchSequenceExportCLICommands(
            for: bundles,
            outputFolder: outputFolder,
            format: .genbank,
            compression: .none
        )

        XCTAssertEqual(targets.count, bundles.count)
        XCTAssertEqual(commands.count, bundles.count)
        XCTAssertEqual(Set(targets.values.map(\.lastPathComponent)).count, bundles.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputFolder.path))
        for bundle in bundles {
            let outputURL = try XCTUnwrap(targets[bundle])
            XCTAssertEqual(outputURL.pathExtension, "gb")
            XCTAssertTrue(outputURL.lastPathComponent.hasPrefix(bundle.deletingPathExtension().lastPathComponent))
        }
        for command in commands {
            XCTAssertTrue(command.contains("\(CLICommandIdentity.executableName) convert"))
            XCTAssertTrue(command.contains("--to-format genbank"))
            XCTAssertTrue(command.contains("--include-annotations"))
        }
    }

    func testNestedMinimap2AnalysesAreDiscoveredFromSyntheticGroupedProject() throws {
        let groupURL = try AnalysesFolder.url(for: projectURL)
            .appendingPathComponent("Map NHP genomic FASTA to Zhang pan-genomes", isDirectory: true)
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<20 {
            let analysisURL = groupURL.appendingPathComponent("minimap2-ont-synthetic-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: analysisURL, withIntermediateDirectories: true)
            try AnalysesFolder.writeAnalysisMetadata(
                .init(tool: "minimap2", isBatch: false, created: created.addingTimeInterval(Double(index))),
                to: analysisURL
            )
        }

        let nestedMinimap2 = try AnalysesFolder.listAnalyses(in: projectURL).filter {
            $0.tool == "minimap2" && $0.url.pathComponents.contains(groupURL.lastPathComponent)
        }

        XCTAssertEqual(nestedMinimap2.count, 20)
        XCTAssertTrue(nestedMinimap2.allSatisfy { $0.url.lastPathComponent.hasPrefix("minimap2-ont-") })
    }
}
