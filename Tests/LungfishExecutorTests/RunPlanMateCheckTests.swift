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
        try serials.map { "@SRR0000001.\($0) \($0) length=10\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
            .write(to: url, atomically: true, encoding: .utf8)
        return url
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
}
