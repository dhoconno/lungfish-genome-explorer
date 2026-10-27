// FASTQBatchImporterTests+LegacyPhred64.swift - A Phred+64 sample fails with the conversion words before any step starts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// The events one import logged, for a test that reads them after the run.
private final class LegacyPhred64EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ImportLogEvent] = []

    func append(_ event: ImportLogEvent) {
        lock.withLock { storage.append(event) }
    }

    var events: [ImportLogEvent] {
        lock.withLock { storage }
    }

    /// Whether any step of the sample started, a recipe step or the storage step.
    var startedAStep: Bool {
        events.contains {
            if case .stepStart = $0 { return true }
            return false
        }
    }
}

/// Phase 3.0 lane BIN, fix round 4 (BIO-BIN-QIN N2 at the batch importer). Every storage step tells BBTools the scores
/// are Phred+33, so a sample whose files are in the old Phred+64 encoding (Illumina pipelines 1.3 to 1.7) fails with the
/// conversion words and starts no step. Before this round a recipe ran its trims on the original reads first, which
/// read a Phred+64 byte as Phred+33 and trim nothing, and the pipeline's own check then read the recipe's output.
extension FASTQBatchImporterTests {
    /// BIO SF1b. The sample fails before the recipe's first step, so no recipe tool runs on the original reads.
    func testARecipeImportRefusesAPhred64PairBeforeTheRecipe() async throws {
        let root = try TestTempDirectory.make(prefix: "importer-legacy-phred64-recipe")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let r1 = root.appendingPathComponent("Old_R1.fastq")
        let r2 = root.appendingPathComponent("Old_R2.fastq")
        try Self.legacyPhred64Records().write(to: r1, atomically: true, encoding: .utf8)
        try Self.legacyPhred64Records().write(to: r2, atomically: true, encoding: .utf8)
        let recipe = Recipe(
            id: "merge-only",
            name: "Merge Only",
            requiredInput: .paired,
            steps: [RecipeStep(type: "fastp-merge", label: "Merge overlapping pairs", params: nil)]
        )
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: projectURL, platform: .illumina,
            newRecipe: recipe,
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: false,
            threads: 1
        )
        let log = LegacyPhred64EventLog()

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [SamplePair(sampleName: "Old", r1: r1, r2: r2)], config: config, log: { log.append($0) }
        )

        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.errors.first?.sample, "Old")
        let words = result.errors.first?.error ?? ""
        XCTAssertTrue(words.contains("old Phred+64 encoding"), "the failure names the encoding: \(words)")
        XCTAssertTrue(words.contains("do not convert it"), "the failure warns against converting a modern file: \(words)")
        XCTAssertFalse(log.startedAStep, "the recipe's first step started although the reads are Phred+64")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: projectURL.appendingPathComponent("Imports/Old.\(FASTQBundle.directoryExtension)").path
            ),
            "a refused sample leaves no bundle"
        )
    }

    /// 200 reads of 100 bases with quality bytes 66 (`B`, Q2) to 104 (`h`, Q40), as Illumina 1.5 wrote them.
    private static func legacyPhred64Records() -> String {
        let bases = String(String(repeating: "ACGT", count: 26).prefix(100))
        var text = ""
        for read in 0..<200 {
            let quality = String(decoding: (0..<100).map { UInt8(66 + (read * 7 + $0 * 3) % 39) }, as: UTF8.self)
            text += "@r\(read)\n\(bases)\n+\n\(quality)\n"
        }
        return text
    }
}
