import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

/// BIO-ROUTES-3 D2, item 5 (S1). The node pairs a sample's R1 and R2 by position in every storage route, so a plan of two
/// files that hold equal counts and are out of step by name stores wrong pairs with no word. The executor checks the two
/// inputs before its first step, with the launcher of the run, in the words of `LungfishPortable`.
final class RunPlanMateCheckTests: XCTestCase {
    /// A launcher that fails the test when the check asks it for a child. Plain files need none.
    private struct NoLaunchLauncher: PortableChildLauncher {
        func start(_ request: PortableChildRequest) throws -> any PortableChild {
            XCTFail("the mate check asked the launcher to start \(request.label)")
            throw CancellationError()
        }
    }

    private func writeReads(_ name: String, serials: [Int]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("run-plan-mates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try Self.readsText(serials: serials).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The text of a FASTQ file of 10-base reads named like SRA spots, one serial each and no mate mark.
    private static func readsText(serials: [Int]) -> String {
        serials.map { "@SRR0000001.\($0) \($0) length=10\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
    }

    /// Two inputs with equal counts, out of step at read 3: the check throws the interleaver's own error and starts no child.
    /// The swap is at reads 3 and 4, because the check reads the SRA spot names `x.1` and `x.2` as dotted mates, so a swap
    /// of reads 1 and 2 is named at record 2 (backlog S4).
    func testTheCheckRefusesAnEqualCountPairOutOfStepByName() throws {
        let r1 = try writeReads("S_R1.fastq", serials: [1, 2, 3, 4])
        let r2 = try writeReads("S_R2.fastq", serials: [1, 2, 4, 3])
        var refusal: FASTQPairInterleaver.InterleaveError?
        do {
            try PlanRunner.refuseOutOfStepMates([r1, r2], launcher: NoLaunchLauncher())
        } catch let error as FASTQPairInterleaver.InterleaveError {
            refusal = error
        }
        XCTAssertEqual(
            refusal,
            .mateNameMismatch(
                recordNumber: 3, r1File: "S_R1.fastq", r1Name: "SRR0000001.3 3 length=10",
                r2File: "S_R2.fastq", r2Name: "SRR0000001.4 4 length=10"
            )
        )
    }

    /// Guard. A pair in step passes, and one input or three are not checked as a pair.
    func testTheCheckPassesAPairInStepAndSkipsOneInputOrThree() throws {
        let r1 = try writeReads("S_R1.fastq", serials: [1, 2, 3, 4])
        let r2 = try writeReads("S_R2.fastq", serials: [1, 2, 3, 4])
        let swapped = try writeReads("S_R3.fastq", serials: [2, 1, 3, 4])
        var refusals: [FASTQPairInterleaver.InterleaveError?] = []
        for reads in [[r1, r2], [swapped], [r1, r2, swapped]] {
            do {
                try PlanRunner.refuseOutOfStepMates(reads, launcher: NoLaunchLauncher())
                refusals.append(nil)
            } catch let error as FASTQPairInterleaver.InterleaveError {
                refusals.append(error)
            }
        }
        XCTAssertEqual(refusals, [nil, nil, nil])
    }

    /// SWIFT review ROUTES-4-AFFECTED, SF1. The wiring: `run(into:)` calls the check before its first step, so a plan of two
    /// inputs that hold equal counts and are out of step by name fails with the interleaver's words and no step starts,
    /// the recipe step included. The plan is built as in `RunPlanLegacyPhred64Tests`, with the pair pinned as
    /// `inputs/S_R1.fastq` and `inputs/S_R2.fastq`. Deleting the call from `run(into:)` turns this red.
    func testRunRefusesAnOutOfStepPairBeforeItsFirstStep() throws {
        var fixture = try RunPlanFixture()
        let inputs = ["inputs/S_R1.fastq", "inputs/S_R2.fastq"]
        try RunPlanFixture.write(Self.readsText(serials: [1, 2, 3, 4]), to: fixture.planFolder + "/" + inputs[0])
        try RunPlanFixture.write(Self.readsText(serials: [2, 1, 3, 4]), to: fixture.planFolder + "/" + inputs[1])
        let recipe = try fixture.addTool("trim-reads", "echo ran > logs/recipe.ran")
        let manifest = try fixture.writeManifest()
        let step = PlanStep(
            id: "trim", title: "Run trim", kind: .recipe, tool: recipe, arguments: [], deadlineSeconds: 60,
            inputs: inputs, outputs: ["out/trimmed.fastq"]
        )
        let plan = try fixture.writePlan([step], manifestPin: manifest.pin, inputs: inputs)

        let run = try fixture.run(plan, ["--image-manifest", manifest.path])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(
            record.reason,
            "Paired FASTQ mates are out of step at record 2: S_R1.fastq has 'SRR0000001.2 2 length=10' but S_R2.fastq has "
                + "'SRR0000001.1 1 length=10'. The two files do not list the same fragments in the same order, so nothing was written.")
        XCTAssertEqual(record.steps.count, 0)
        XCTAssertEqual(fixture.exists("logs/recipe.ran"), false, "the recipe ran on a pair the check refuses")
    }
}
