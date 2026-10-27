import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

/// BIO-BIN-QIN N2 at the executor (lane BIN, fix rounds 3 and 4). Every storage route of `run --plan` tells BBTools the
/// scores are Phred+33, so a plan whose reads are in the old Phred+64 encoding (Illumina pipelines 1.3 to 1.7) would
/// store every score 31 too high. Two guards stop it, each with the ruled words and each before any tool runs after it.
/// The run reads the plan's own read inputs once, before any step, so no recipe step runs on them. The storage step reads
/// its own inputs again, since a recipe step may have written them, and stops at the top of its storage work.
extension RunPlanTests {
    /// Two Illumina 1.5 reads. Their quality bytes run from `B` (66, the Q2 tail mark) to `h` (104, Q40), short reads
    /// with nothing below 64 and nothing above 105, which is the file the guard refuses.
    static let illumina15Reads = "@r1\nACGTACGTAC\n+\nhhhhgggfBB\n@r2\nACGTACGTAC\n+\nhhhhhhhhhh\n"

    /// The words the refusal carries, as the ruling of BIO-BIN-QIN 7.1 states them.
    static let legacyPhred64Words = [
        "old Phred+64 encoding", "LGE stores Phred+33 scores only", "reformat.sh qin=64 qout=33", "do not convert it",
    ]

    /// A clumpify that says it ran and stores its input, so a run that gets past the guards succeeds.
    static let storingClumpify = """
    for a in "$@"; do case "$a" in in=*) IN="${a#in=}" ;; out=*) OUT="${a#out=}" ;; esac; done
    echo ran > logs/clumpify.ran
    gzip -c < "$IN" > "$OUT"
    """

    /// A recipe step that says it ran and rewrites the scores, as a pair merge does. Its output holds only `5` (53, below
    /// the 64 that every Phred+64 file starts at), so the storage step's guard passes it.
    static let scoreRewritingRecipe = """
    echo ran > logs/recipe.ran
    printf '@r1\\nACGTACGTAC\\n+\\n5555555555\\n@r2\\nACGTACGTAC\\n+\\n5555555555\\n' > out/trimmed.fastq
    """

    /// A recipe step that says it ran and writes a file in the Phred+64 encoding, from a plan input that is not.
    static let phred64WritingRecipe = """
    echo ran > logs/recipe.ran
    printf '@r1\\nACGTACGTAC\\n+\\nhhhhgggfBB\\n@r2\\nACGTACGTAC\\n+\\nhhhhhhhhhh\\n' > out/trimmed.fastq
    """

    /// Fix round 4, item 3 (BIO Backlog line 1). The plan's read input is in the Phred+64 encoding and its first step is
    /// a recipe step that rewrites the scores. The run stops before that step, with the ruled words and no step record,
    /// so neither the recipe nor clumpify ran.
    func testExecutorRefusesAPhred64PlanInputBeforeAnyStep() throws {
        let (fixture, plan, manifest) = try clumpifyPlan(
            Self.storingClumpify, inputText: Self.illumina15Reads, leadingRecipe: Self.scoreRewritingRecipe
        )
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.steps.count, 0, "a step ran although the plan's reads are Phred+64")
        XCTAssertNil(record.failedStepID, "no step failed, since none started")
        let reason = record.reason ?? ""
        for words in Self.legacyPhred64Words {
            XCTAssertTrue(reason.contains(words), "\(words) is missing from the record reason: \(reason)")
        }
        XCTAssertEqual(record.payloads, [])
        XCTAssertFalse(fixture.exists("logs/recipe.ran"), "the recipe ran on a file the guard refuses")
        XCTAssertFalse(fixture.exists("logs/clumpify.ran"), "clumpify ran on a file the guard refuses")
    }

    /// The storage step's own guard. The plan's input is Phred+33, so the run's check passes it, and a recipe step writes
    /// a Phred+64 file for the storage step to read. The step stops at the top of its storage work and clumpify never runs.
    func testExecutorRefusesAPhred64FileAtTheStorageStep() throws {
        let (fixture, plan, manifest) = try clumpifyPlan(
            "echo ran > logs/clumpify.ran", leadingRecipe: Self.phred64WritingRecipe
        )
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failedStepID, "storage")
        XCTAssertEqual(record.steps.count, 2)
        XCTAssertEqual(record.steps.first?.outcome, .succeeded, "the recipe step ran first")
        let step = try XCTUnwrap(record.steps.last)
        XCTAssertEqual(step.outcome, .failed)
        let reason = try XCTUnwrap(step.reason)
        for words in Self.legacyPhred64Words {
            XCTAssertTrue(reason.contains(words), "\(words) is missing from the step reason: \(reason)")
            XCTAssertTrue(record.reason?.contains(words) ?? false, "\(words) is missing from the record reason")
        }
        XCTAssertEqual(step.outputs, [])
        XCTAssertEqual(record.payloads, [])
        XCTAssertTrue(fixture.exists("logs/recipe.ran"), "the recipe step ran and wrote the file the storage step refuses")
        XCTAssertFalse(fixture.exists("logs/clumpify.ran"), "clumpify ran on a file the guard refuses")
        XCTAssertFalse(step.storage?.launches?.contains { $0.tool.id == "clumpify.sh" } ?? false)
    }
}
