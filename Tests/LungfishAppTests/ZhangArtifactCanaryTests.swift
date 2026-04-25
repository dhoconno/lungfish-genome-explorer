import XCTest
@testable import LungfishApp
import LungfishIO

/// External-artifact canaries for the mounted Zhang pan-genome project.
///
/// These tests intentionally do not perform the full GenBank export. The real
/// Zhang bundles are large enough that a complete export belongs in a manual or
/// overnight gate. The canary validates the pieces that regressed here: planning
/// one GenBank export per bundle, surfacing CLI-equivalent commands, and finding
/// nested minimap2 analyses under the user's grouping folder.
final class ZhangArtifactCanaryTests: XCTestCase {
    private let projectURL = URL(
        fileURLWithPath: "/Volumes/iWES_WNPRC/32217-Zhang-et-al-MHC/Zhang-pan-genome.lungfish",
        isDirectory: true
    )

    func testMountedZhangPanGenomeBatchGenBankExportPlanIsCompleteWithoutWritingOutputs() throws {
        let projectURL = try requireMountedZhangProject()
        let panGenomesURL = projectURL
            .appendingPathComponent("Zhang pan-genomes", isDirectory: true)

        let bundles = try FileManager.default.contentsOfDirectory(
            at: panGenomesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "lungfishref" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertGreaterThanOrEqual(bundles.count, 20)
        XCTAssertTrue(bundles.contains { $0.lastPathComponent == "T2T-MFA8v1_0.lungfishref" })

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
            XCTAssertTrue(command.contains("lungfish convert"))
            XCTAssertTrue(command.contains("--to-format genbank"))
            XCTAssertTrue(command.contains("--include-annotations"))
        }
    }

    func testMountedZhangNestedMinimap2AnalysesAreDiscovered() throws {
        let projectURL = try requireMountedZhangProject()
        let groupName = "Map NHP genomic FASTA to Zhang pan-genomes"

        let analyses = try AnalysesFolder.listAnalyses(in: projectURL)
        let nestedMinimap2 = analyses.filter {
            $0.tool == "minimap2" && $0.url.pathComponents.contains(groupName)
        }

        XCTAssertGreaterThanOrEqual(nestedMinimap2.count, 20)
        XCTAssertTrue(nestedMinimap2.allSatisfy { $0.url.lastPathComponent.hasPrefix("minimap2-ont-") })
    }

    private func requireMountedZhangProject() throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("Zhang pan-genome project volume is not mounted at \(projectURL.path)")
        }
        return projectURL
    }
}
