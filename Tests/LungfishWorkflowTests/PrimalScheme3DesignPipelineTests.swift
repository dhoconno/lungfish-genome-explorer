import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class PrimalScheme3DesignPipelineTests: XCTestCase {
    func testCombinedUsesOnePanelCreateWithEachAlignment() throws {
        let options = PrimalScheme3DesignOptions(ampliconSize: 400, poolCount: 2)
        let inputs = [URL(fileURLWithPath: "/test/first.fasta"), URL(fileURLWithPath: "/test/second.fasta")]
        let arguments = try PrimalScheme3DesignPipeline.arguments(
            inputs: inputs, output: URL(fileURLWithPath: "/test/output"),
            grouping: .combined, options: options)
        XCTAssertEqual(arguments, ["panel-create", "--mode", "equal", "--msa", inputs[0].path, "--msa", inputs[1].path,
            "--output", "/test/output", "--amplicon-size", "400", "--n-pools", "2",
            "--min-base-freq", "0.0", "--mapping", "first", "--no-high-gc", "--ncores", String(PrimalScheme3DesignOptions.defaultCoreCount), "--terminal-gap-policy", "observed-only"])
    }

    func testAdvancedOptionsRespectVerifiedSubcommandCapabilities() throws {
        let input = URL(fileURLWithPath: "/test/input.fasta")
        let options = PrimalScheme3DesignOptions(ampliconSize: 400, poolCount: 2,
            minOverlap: 25, minimumBaseFrequency: 0.5, highGC: true, coreCount: 3, terminalGapPolicy: .legacy)
        let argv = try PrimalScheme3DesignPipeline.arguments(inputs: [input],
            output: URL(fileURLWithPath: "/test/output"), grouping: .independent, options: options)
        XCTAssertEqual(Array(argv.suffix(11)), ["--min-base-freq", "0.5", "--mapping", "first",
            "--high-gc", "--ncores", "3", "--terminal-gap-policy", "legacy", "--min-overlap", "25"])
        XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(inputs: [input],
            output: URL(fileURLWithPath: "/test/output"), grouping: .combined, options: options))
        for invalid in [
            PrimalScheme3DesignOptions(ampliconSize: 400, poolCount: 2, minOverlap: -1),
            .init(ampliconSize: 400, poolCount: 2, minimumBaseFrequency: .nan),
            .init(ampliconSize: 400, poolCount: 2, minimumBaseFrequency: 1.01),
            .init(ampliconSize: 400, poolCount: 2, coreCount: 0)
        ] {
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(inputs: [input],
                output: URL(fileURLWithPath: "/test/output"), grouping: .independent, options: invalid))
        }
    }

    func testLegacyPolicyIsExplicitForBothGroupingModes() throws {
        for grouping in [PrimerAnalysisGrouping.independent, .combined] {
            let args = try PrimalScheme3DesignPipeline.arguments(inputs: [URL(fileURLWithPath: "/input")],
                output: URL(fileURLWithPath: "/output"), grouping: grouping,
                options: .init(ampliconSize: 400, poolCount: 2, terminalGapPolicy: .legacy))
            let flag = try XCTUnwrap(args.firstIndex(of: "--terminal-gap-policy"))
            XCTAssertEqual(args[flag + 1], "legacy")
        }
    }

    func testBothPoliciesPassSelectedCPUCount() throws {
        for policy in PrimalScheme3TerminalGapPolicy.allCases {
            let args = try PrimalScheme3DesignPipeline.arguments(inputs: [URL(fileURLWithPath: "/input")],
                output: URL(fileURLWithPath: "/output"), grouping: .independent,
                options: .init(ampliconSize: 400, poolCount: 2, coreCount: 4, terminalGapPolicy: policy))
            let coreFlag = try XCTUnwrap(args.firstIndex(of: "--ncores"))
            let policyFlag = try XCTUnwrap(args.firstIndex(of: "--terminal-gap-policy"))
            XCTAssertEqual(args[coreFlag + 1], "4")
            XCTAssertEqual(args[policyFlag + 1], policy.rawValue)
        }
    }

    func testIndependentRejectsMultipleInputsAndInvalidOptions() {
        XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(
            inputs: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")],
            output: URL(fileURLWithPath: "/o"), grouping: .independent,
            options: .init(ampliconSize: 400, poolCount: 2)))
        for options in [PrimalScheme3DesignOptions(ampliconSize: 0, poolCount: 2),
                        PrimalScheme3DesignOptions(ampliconSize: 400, poolCount: 0)] {
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(
                inputs: [URL(fileURLWithPath: "/a")], output: URL(fileURLWithPath: "/o"),
                grouping: .independent, options: options))
        }
    }
}
