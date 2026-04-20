import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

private final class CapturedArgumentsBox: @unchecked Sendable {
    var arguments: [String] = []
}

@MainActor
final class AssemblyContigMaterializationActionTests: XCTestCase {
    func testCopyFASTAWritesCliStdoutToPasteboard() async throws {
        let action = AssemblyContigMaterializationAction()
        let pasteboard = RecordingPasteboard()
        action.pasteboard = pasteboard
        action.runner = { _ in
            .init(stdout: ">contig_7\nAACCGGTT\n", stderr: "", status: 0)
        }

        let result = try makeAssemblyResult()

        try await action.copyFASTA(
            result: result,
            selectedContigs: ["contig_7"]
        )

        XCTAssertEqual(pasteboard.lastString, ">contig_7\nAACCGGTT\n")
    }

    func testBuildBlastRequestUsesCliStdoutAndSourceLabel() async throws {
        let action = AssemblyContigMaterializationAction()
        action.runner = { _ in
            .init(stdout: ">contig_7\nAACCGGTT\n", stderr: "", status: 0)
        }

        let result = try makeAssemblyResult()

        let request = try await action.buildBlastRequest(
            result: result,
            selectedContigs: ["contig_7"]
        )

        XCTAssertEqual(request.readCount, 1)
        XCTAssertEqual(request.sourceLabel, "contig contig_7")
        XCTAssertEqual(request.sequences, [">contig_7\nAACCGGTT\n"])
    }

    func testCreateBundleReturnsBundleURLPrintedByCli() async throws {
        let action = AssemblyContigMaterializationAction()
        let capturedArguments = CapturedArgumentsBox()
        action.runner = { arguments in
            capturedArguments.arguments = arguments
            return .init(stdout: "/tmp/SelectedContigs.lungfishref\n", stderr: "", status: 0)
        }

        let result = try makeAssemblyResult()

        let bundleURL = try await action.createBundle(
            result: result,
            selectedContigs: ["contig_7", "contig_9"],
            suggestedName: "SelectedContigs"
        )

        XCTAssertEqual(bundleURL?.path, "/tmp/SelectedContigs.lungfishref")
        XCTAssertTrue(capturedArguments.arguments.contains("--project-root"))
        XCTAssertTrue(capturedArguments.arguments.contains(result.outputDirectory.deletingLastPathComponent().deletingLastPathComponent().path))
    }

    func testCreateBundleThrowsWhenCliDoesNotPrintBundlePath() async throws {
        let action = AssemblyContigMaterializationAction()
        action.runner = { _ in
            .init(stdout: " \n", stderr: "", status: 0)
        }

        let result = try makeAssemblyResult()

        do {
            _ = try await action.createBundle(
                result: result,
                selectedContigs: ["contig_7"],
                suggestedName: "SelectedContigs"
            )
            XCTFail("Expected missing bundle path error")
        } catch let error as AssemblyContigMaterializationAction.Error {
            guard case .bundlePathMissing = error else {
                return XCTFail("Expected bundlePathMissing, got \(error)")
            }
        }
    }

    func testBuildBlastRequestRejectsMalformedCliOutput() async throws {
        let action = AssemblyContigMaterializationAction()
        action.runner = { _ in
            .init(stdout: "AACCGGTT\n", stderr: "", status: 0)
        }

        let result = try makeAssemblyResult()

        do {
            _ = try await action.buildBlastRequest(
                result: result,
                selectedContigs: ["contig_7"]
            )
            XCTFail("Expected invalid FASTA output error")
        } catch let error as AssemblyContigMaterializationAction.Error {
            guard case .invalidFASTAOutput = error else {
                return XCTFail("Expected invalidFASTAOutput, got \(error)")
            }
        }
    }
}
