import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

final class AssemblyConfigurationViewModelSourceTests: XCTestCase {
    func testAssemblyCompletionPresentationHandlesNoContigsOutcome() {
        let result = makeAssemblyResult(outcome: .completedWithNoContigs)

        XCTAssertEqual(
            AssemblyRunner.completionDetail(for: result),
            "Assembly completed, but no contigs were generated."
        )
        XCTAssertEqual(
            AssemblyRunner.completionNotificationTitle(for: result),
            "No Contigs Generated"
        )
        XCTAssertEqual(
            AssemblyRunner.completionNotificationBody(
                for: result,
                toolDisplayName: "SPAdes",
                projectName: "project-a"
            ),
            "SPAdes finished for project-a, but no contigs were generated."
        )
    }

    func testAssemblyCompletionPresentationHandlesNormalOutcome() {
        let result = makeAssemblyResult(outcome: .completed)

        XCTAssertEqual(AssemblyRunner.completionDetail(for: result), "Assembly complete")
        XCTAssertEqual(AssemblyRunner.completionNotificationTitle(for: result), "Assembly Complete")
        XCTAssertEqual(
            AssemblyRunner.completionNotificationBody(
                for: result,
                toolDisplayName: "SPAdes",
                projectName: "project-a"
            ),
            "SPAdes finished for project-a."
        )
    }

    private func makeAssemblyResult(outcome: AssemblyOutcome) -> AssemblyResult {
        AssemblyResult(
            tool: .spades,
            readType: .illuminaShortReads,
            outcome: outcome,
            contigsPath: URL(fileURLWithPath: "/tmp/project-a/contigs.fasta"),
            graphPath: nil,
            logPath: nil,
            assemblerVersion: "test",
            commandLine: "lungfish-cli assemble spades",
            outputDirectory: URL(fileURLWithPath: "/tmp/project-a"),
            statistics: AssemblyStatistics(
                contigCount: outcome == .completedWithNoContigs ? 0 : 1,
                totalLengthBP: outcome == .completedWithNoContigs ? 0 : 1200,
                largestContigBP: outcome == .completedWithNoContigs ? 0 : 1200,
                smallestContigBP: outcome == .completedWithNoContigs ? 0 : 1200,
                n50: outcome == .completedWithNoContigs ? 0 : 1200,
                l50: outcome == .completedWithNoContigs ? 0 : 1,
                n90: outcome == .completedWithNoContigs ? 0 : 1200,
                gcFraction: 0.5,
                meanLengthBP: outcome == .completedWithNoContigs ? 0 : 1200
            ),
            wallTimeSeconds: 1
        )
    }
}
