import XCTest
@testable import LungfishApp
import LungfishIO

final class AnalysisParameterSummaryTests: XCTestCase {
    /// The FASTQ Inspector Analyses row showed the raw mapping request
    /// ("compatibilityReadClassOverride:  | extraArgs:  | ..."). It must read
    /// as a short, labelled summary with internal keys and empty values left out.
    func testMappingParametersReadAsHumanSummary() {
        let parameters: [String: AnalysisParameterValue] = [
            "compatibilityReadClassOverride": .string(""),
            "extraArgs": .string(""),
            "includeSecondary": .bool(false),
            "includeSupplementary": .bool(true),
            "inputLayout": .string("strictly_interleaved"),
            "isPairedEnd": .bool(false),
            "minimumMappingQuality": .int(0),
            "mode": .string("short-read-default"),
            "outputTrackName": .string("minimap2 Mapping"),
            "readGroup.id": .string("HG002"),
            "readGroup.sm": .string("HG002"),
            "readLayoutHandling": .string("as_pairs"),
            "sampleName": .string("HG002"),
            "threads": .int(14),
            "tool": .string("minimap2"),
        ]
        let summary = AnalysisParameterSummary.format(parameters)
        XCTAssertEqual(
            summary,
            "Mode: short-read-default · Min MAPQ: 0 · Secondary: no · Supplementary: yes · Paired-end: no · Threads: 14")
        for internalKey in ["compatibilityReadClassOverride", "extraArgs", "readGroup", "outputTrackName", "tool:", "|"] {
            XCTAssertFalse(summary.contains(internalKey), "\(internalKey) leaked into: \(summary)")
        }
    }

    func testNonEmptyExtraArgumentsAndUnknownKeysStayReadable() {
        let summary = AnalysisParameterSummary.format([
            "databaseName": .string("Standard-8"),
            "confidence": .double(0.2),
            "extraArgs": .string("--quick"),
            "newSetting": .int(3),
        ])
        XCTAssertEqual(summary, "Database: Standard-8 · Confidence: 0.2 · Extra arguments: --quick · New setting: 3")
    }
}
