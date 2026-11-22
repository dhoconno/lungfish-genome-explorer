import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

/// FIX-ROUTES-5 items 1, 2 and 4 (BIO-ROUTES-4). The pairs a plan declares are the ones the node checks for mate names. A
/// read import plan lists R1, R2 and the run-alone file in that order, a merged-to-mixed plan lists the merged reads
/// first and never has them read as a mate, and an RNA-seq plan names each pair by its number.
final class RunPlanDeclaredPairsTests: XCTestCase {
    private func entries(_ paths: [String]) -> [PlanEntry] {
        paths.map { PlanEntry(role: .input, relativePath: $0, sha256: String(repeating: "a", count: 64), size: 1) }
    }

    private func pairs(_ paths: [String], steps: [PlanStep] = []) -> [[String]] {
        PlanReadPairs.declared(entries: entries(paths), steps: steps).map { [$0.r1, $0.r2] }
    }

    private func step(_ kind: PlanStepKind, arguments: [String] = [], inputs: [String]) -> PlanStep {
        PlanStep(id: "s", title: "s", kind: kind, tool: nil, arguments: arguments, deadlineSeconds: 60, inputs: inputs, outputs: ["o"])
    }

    func testAReadImportPlanDeclaresItsFirstTwoInputsWhateverTheirNumber() {
        XCTAssertEqual(pairs(["inputs/R1.fastq", "inputs/R2.fastq"]), [["inputs/R1.fastq", "inputs/R2.fastq"]])
        XCTAssertEqual(
            pairs(["inputs/R1.fastq", "inputs/R2.fastq", "inputs/R3.fastq"]), [["inputs/R1.fastq", "inputs/R2.fastq"]],
            "the third input is the run-alone file of an SRA download")
        XCTAssertEqual(pairs(["inputs/R1.fastq"]), [])
        XCTAssertEqual(pairs([]), [])
    }

    func testAMergedToMixedPlanNeverHasItsMergedReadsReadAsAMate() {
        let paths = ["inputs/R1.fastq", "inputs/R2.fastq", "inputs/R3.fastq"]
        let merge = step(.interleave, inputs: paths)
        XCTAssertEqual(pairs(paths, steps: [merge]), [["inputs/R2.fastq", "inputs/R3.fastq"]])
        let convert = step(.interleave, arguments: ["reformat.sh"], inputs: paths)
        XCTAssertEqual(pairs(paths, steps: [convert]), [["inputs/R1.fastq", "inputs/R2.fastq"]], "a step with an argv is no merged-to-mixed step")
    }

    func testAnRNASeqPlanDeclaresEachPairByItsNumberAndNeverASingleRead() {
        let paths = [
            "inputs/pair2_R1.fastq.gz", "inputs/pair2_R2.fastq.gz", "inputs/single1.fastq.gz",
            "inputs/pair1_R1.fastq.gz", "inputs/pair1_R2.fastq.gz", "inputs/pair10_R1.fastq.gz", "inputs/pair10_R2.fastq.gz",
        ]
        XCTAssertEqual(pairs(paths), [
            ["inputs/pair1_R1.fastq.gz", "inputs/pair1_R2.fastq.gz"],
            ["inputs/pair2_R1.fastq.gz", "inputs/pair2_R2.fastq.gz"],
            ["inputs/pair10_R1.fastq.gz", "inputs/pair10_R2.fastq.gz"],
        ])
        XCTAssertEqual(pairs(["inputs/single1.fastq.gz", "inputs/single2.fastq.gz"]), [["inputs/single1.fastq.gz", "inputs/single2.fastq.gz"]],
                       "two single reads of no pair name read as a read import plan does")
    }
}
