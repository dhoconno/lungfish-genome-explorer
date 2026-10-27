import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

/// BIO-BIN-QIN N2 at the executor (lane BIN, fix round 3, S1). Every storage route of `run --plan` tells BBTools the
/// scores are Phred+33, so a plan whose storage step names a file in the old Phred+64 encoding (Illumina pipelines 1.3
/// to 1.7) would store every score 31 too high. The step stops at the top of its storage work with the ruled words,
/// and no tool runs.
extension RunPlanTests {
    /// Two Illumina 1.5 reads. Their quality bytes run from `B` (66, the Q2 tail mark) to `h` (104, Q40), short reads
    /// with nothing below 64 and nothing above 105, which is the file the guard refuses.
    static let illumina15Reads = "@r1\nACGTACGTAC\n+\nhhhhgggfBB\n@r2\nACGTACGTAC\n+\nhhhhhhhhhh\n"

    func testExecutorRefusesAPhred64FileAtTheStorageStep() throws {
        let (fixture, plan, manifest) = try clumpifyPlan(
            "echo ran > logs/clumpify.ran", inputText: Self.illumina15Reads
        )
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failedStepID, "storage")
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(step.outcome, .failed)
        let reason = try XCTUnwrap(step.reason)
        for words in [
            "old Phred+64 encoding", "LGE stores Phred+33 scores only", "reformat.sh qin=64 qout=33", "do not convert it",
        ] {
            XCTAssertTrue(reason.contains(words), "\(words) is missing from the step reason: \(reason)")
            XCTAssertTrue(record.reason?.contains(words) ?? false, "\(words) is missing from the record reason")
        }
        XCTAssertEqual(step.outputs, [])
        XCTAssertEqual(record.payloads, [])
        XCTAssertFalse(fixture.exists("logs/clumpify.ran"), "clumpify ran on a file the guard refuses")
        XCTAssertFalse(step.storage?.launches?.contains { $0.tool.id == "clumpify.sh" } ?? false)
    }
}
