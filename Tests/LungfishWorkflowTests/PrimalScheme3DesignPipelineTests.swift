import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class PrimalScheme3DesignPipelineTests: XCTestCase {
    func testPrimalSchemeInputTreatsUnknownBasesAsMissingCoverage() {
        let result = Primer3InputLoader.normalizeForPrimalScheme([
            Primer3AlignedRow(title: "reference", sequence: "ACN-Uu"),
            Primer3AlignedRow(title: "sample", sequence: "AC--TT")
        ])

        XCTAssertEqual(result.rows.map(\.sequence), ["AC--TT", "AC--TT"])
        XCTAssertEqual(result.uracilCount, 2)
        XCTAssertEqual(result.unknownBaseCount, 1)
    }

    func testSupportedInputsIncludeRawNucleotideFASTAAndNativeMSA() {
        for extensionName in ["fa", "fasta", "fna", "ffn", "frn", "fas", "lungfishmsa"] {
            XCTAssertTrue(
                PrimalScheme3DesignPipeline.supportsInput(at: URL(fileURLWithPath: "/input/reference.\(extensionName)")),
                extensionName
            )
        }
        XCTAssertFalse(PrimalScheme3DesignPipeline.supportsInput(at: URL(fileURLWithPath: "/input/proteins.faa")))
        XCTAssertFalse(PrimalScheme3DesignPipeline.supportsInput(at: URL(fileURLWithPath: "/input/reference.fa.gz")))
    }

    func testExplicitAmpliconBoundsReachBothCommandsAndProvenance() throws {
        let options = PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 2,
            ampliconSizeMinimum: 150, ampliconSizeMaximum: 250)
        for grouping in [PrimerAnalysisGrouping.independent, .combined] {
            let args = try PrimalScheme3DesignPipeline.arguments(inputs: [URL(fileURLWithPath: "/input")],
                output: URL(fileURLWithPath: "/output"), grouping: grouping, options: options)
            XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--amplicon-size-min")) + 1], "150")
            XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--amplicon-size-max")) + 1], "250")
        }
        XCTAssertEqual(options.provenanceOptions["ampliconSizeMinimum"], .integer(150))
        XCTAssertEqual(options.provenanceOptions["ampliconSizeMaximum"], .integer(250))
        XCTAssertEqual(options.provenanceOptions["ampliconSizeMetric"], .string("reference-span"))
        XCTAssertEqual(try JSONDecoder().decode(PrimalScheme3DesignOptions.self, from: JSONEncoder().encode(options)), options)
    }

    func testLegacyOptionsDecodeWithoutNewFieldsAndSingleExplicitBoundResolvesOther() throws {
        let original = PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 2)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        payload.removeValue(forKey: "requestedAmpliconSizeMinimum")
        payload.removeValue(forKey: "requestedAmpliconSizeMaximum")
        let decoded = try JSONDecoder().decode(PrimalScheme3DesignOptions.self,
            from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(decoded.ampliconSizeMinimum, 180)
        XCTAssertEqual(decoded.ampliconSizeMaximum, 220)
        XCTAssertEqual(decoded.ampliconSizeMetric, "legacy-pairing")
        let lower = PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: 150)
        XCTAssertEqual(lower.ampliconSizeMaximum, 220)
        XCTAssertEqual(lower.ampliconSizeMetric, "reference-span")
    }

    func testInvalidExplicitAmpliconBoundsAreRejectedBeforeExecution() {
        for (minimum, maximum) in [(0, 250), (-1, 250), (251, 150), (201, 250), (150, 199)] {
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(inputs: [URL(fileURLWithPath: "/input")],
                output: URL(fileURLWithPath: "/output"), grouping: .independent,
                options: .init(ampliconSize: 200, poolCount: 2, ampliconSizeMinimum: minimum, ampliconSizeMaximum: maximum)))
        }
    }

    func testNativeFullReferenceSpansMustHonorExplicitInclusiveBounds() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let options = PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 2,
            ampliconSizeMinimum: 150, ampliconSizeMaximum: 250)
        let bed = output.appendingPathComponent("amplicon.bed")
        for length in [150, 200, 250] {
            try "reference\t10\t\(10 + length)\tamplicon\t1\n".write(to: bed, atomically: true, encoding: .utf8)
            XCTAssertNoThrow(try PrimalScheme3DesignPipeline.validateNativeAmpliconSpans(at: output, options: options))
        }
        for text in ["reference\t10\t159\ta\t1\n", "reference\t10\t261\ta\t1\n", "reference\t0\tbad\n", "reference\t-1\t200\n"] {
            try text.write(to: bed, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.validateNativeAmpliconSpans(at: output, options: options))
        }
    }

    func testSupportedPanelControlsAndEffectiveRange() throws {
        let options = PrimalScheme3DesignOptions(ampliconSize: 401, poolCount: 2,
            dimerScore: -30, useMatchDB: false, panelMode: .entropy,
            maxAmplicons: 20, maxAmpliconsPerMSA: 5)
        XCTAssertEqual(options.ampliconSizeMinimum, 360)
        XCTAssertEqual(options.ampliconSizeMaximum, 441)
        let args = try PrimalScheme3DesignPipeline.arguments(inputs: [URL(fileURLWithPath: "/a")],
            output: URL(fileURLWithPath: "/o"), grouping: .combined, options: options)
        XCTAssertEqual(args[2], "entropy")
        XCTAssertTrue(args.contains("--no-use-matchdb"))
        XCTAssertTrue(args.contains("--max-amplicons-msa"))
        XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(inputs: [URL(fileURLWithPath: "/a")],
            output: URL(fileURLWithPath: "/o"), grouping: .independent, options: options))
    }

    func testSchemeOnlyControlsRejectCombinedAndInvalidLimits() throws {
        for options in [PrimalScheme3DesignOptions(ampliconSize: 400, poolCount: 2, backtrack: true),
            .init(ampliconSize: 400, poolCount: 2, ignoreN: true),
            .init(ampliconSize: 400, poolCount: 2, dimerScore: .nan),
            .init(ampliconSize: 400, poolCount: 2, maxAmplicons: 0)] {
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(inputs: [URL(fileURLWithPath: "/a")],
                output: URL(fileURLWithPath: "/o"), grouping: .combined, options: options))
        }
    }

    func testCombinedUsesOnePanelCreateWithEachAlignment() throws {
        let options = PrimalScheme3DesignOptions(ampliconSize: 400, poolCount: 2)
        let inputs = [URL(fileURLWithPath: "/test/first.fasta"), URL(fileURLWithPath: "/test/second.fasta")]
        let arguments = try PrimalScheme3DesignPipeline.arguments(
            inputs: inputs, output: URL(fileURLWithPath: "/test/output"),
            grouping: .combined, options: options)
        XCTAssertEqual(arguments, ["panel-create", "--mode", "equal", "--msa", inputs[0].path, "--msa", inputs[1].path,
            "--output", "/test/output", "--amplicon-size", "400", "--n-pools", "2",
            "--min-base-freq", "0.0", "--mapping", "first", "--no-high-gc", "--ncores", String(PrimalScheme3DesignOptions.defaultCoreCount), "--terminal-gap-policy", "observed-only", "--dimer-score", "-26.0", "--use-matchdb", "--offline-plots"])
    }

    func testAdvancedOptionsRespectVerifiedSubcommandCapabilities() throws {
        let input = URL(fileURLWithPath: "/test/input.fasta")
        let options = PrimalScheme3DesignOptions(ampliconSize: 400, poolCount: 2,
            minOverlap: 25, minimumBaseFrequency: 0.5, highGC: true, coreCount: 3, terminalGapPolicy: .legacy)
        let argv = try PrimalScheme3DesignPipeline.arguments(inputs: [input],
            output: URL(fileURLWithPath: "/test/output"), grouping: .independent, options: options)
        XCTAssertEqual(Array(argv.dropLast(8).suffix(9)), ["--min-base-freq", "0.5", "--mapping", "first",
            "--high-gc", "--ncores", "3", "--terminal-gap-policy", "legacy"])
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
        XCTAssertEqual(PrimalScheme3DesignOptions(ampliconSize: .max, poolCount: 2).ampliconSizeMaximum, 0)
        for options in [PrimalScheme3DesignOptions(ampliconSize: 0, poolCount: 2),
                        PrimalScheme3DesignOptions(ampliconSize: .max, poolCount: 2),
                        PrimalScheme3DesignOptions(ampliconSize: 400, poolCount: 0)] {
            XCTAssertThrowsError(try PrimalScheme3DesignPipeline.arguments(
                inputs: [URL(fileURLWithPath: "/a")], output: URL(fileURLWithPath: "/o"),
                grouping: .independent, options: options))
        }
    }
}
