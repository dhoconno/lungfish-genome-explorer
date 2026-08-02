import Foundation
import XCTest
@testable import LungfishWorkflow

final class ONTBAMImportMaterializerTests: XCTestCase {
    func testNonBAMPassesThroughWithoutConversion() async throws {
        let pair = SamplePair(
            sampleName: "sample",
            r1: URL(fileURLWithPath: "/tmp/sample.fastq.gz"),
            r2: nil
        )

        let result = try await ONTBAMImportMaterializer.materializeIfNeeded(
            pair: pair,
            platform: .ont,
            workspace: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(result.processingPair.r1, pair.r1)
        XCTAssertTrue(result.provenanceSteps.isEmpty)
    }

    func testBAMRequiresONTPlatform() async {
        let pair = SamplePair(
            sampleName: "sample",
            r1: URL(fileURLWithPath: "/tmp/sample.bam"),
            r2: nil
        )

        do {
            _ = try await ONTBAMImportMaterializer.materializeIfNeeded(
                pair: pair,
                platform: .illumina,
                workspace: URL(fileURLWithPath: "/tmp")
            )
            XCTFail("Expected the non-ONT BAM import to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("only for Oxford Nanopore"))
        }
    }

    func testBAMCannotBeUsedAsOneHalfOfAPair() async {
        let pair = SamplePair(
            sampleName: "mixed",
            r1: URL(fileURLWithPath: "/tmp/mixed_R1.fastq.gz"),
            r2: URL(fileURLWithPath: "/tmp/mixed_R2.bam")
        )

        do {
            _ = try await ONTBAMImportMaterializer.materializeIfNeeded(
                pair: pair,
                platform: .ont,
                workspace: URL(fileURLWithPath: "/tmp")
            )
            XCTFail("Expected the mixed FASTQ/BAM pair to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("must be a single file"))
        }
    }

    func testBAMMaterializesCompressedFASTQAndRecordsBothTools() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTBAMImportMaterializerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let bamURL = root.appendingPathComponent("reads.bam")
        try Data([0x42, 0x41, 0x4d]).write(to: bamURL)

        let samtools = root.appendingPathComponent(".lungfish/conda/envs/samtools/bin/samtools")
        let pigz = root.appendingPathComponent(".lungfish/conda/envs/pigz/bin/pigz")
        try installScript(at: samtools, body: """
        if [ "${1:-}" = "--version" ]; then echo "samtools 1.23"; exit 0; fi
        printf '@read1\\nACGT\\n+\\nIIII\\n'
        """)
        try installScript(at: pigz, body: """
        if [ "${1:-}" = "--version" ]; then echo "pigz 2.8"; exit 0; fi
        for argument in "$@"; do input="$argument"; done
        /usr/bin/gzip -c "$input"
        """)

        let result = try await ONTBAMImportMaterializer.materializeIfNeeded(
            pair: SamplePair(sampleName: "reads", r1: bamURL, r2: nil),
            platform: .ont,
            workspace: workspace,
            threads: 3,
            runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: root)
        )

        XCTAssertEqual(result.processingPair.r1.lastPathComponent, "reads-from-bam.fastq.gz")
        XCTAssertGreaterThan(try fileSize(result.processingPair.r1), 0)
        XCTAssertEqual(result.provenanceSteps.map(\.toolName), ["samtools", "pigz"])
        XCTAssertEqual(result.provenanceSteps[0].inputs.first?.format, .bam)
        XCTAssertTrue(result.provenanceSteps[0].command.contains(String(ONTBAMImportMaterializer.primaryReadFlagFilter)))
        XCTAssertTrue(result.provenanceSteps[1].command.contains("3"))
        XCTAssertEqual(result.provenanceSteps[0].durableReplayArgv?.first, "/bin/sh")
        XCTAssertTrue(result.provenanceSteps[0].durableReplayArgv?.last?.contains(" > ") == true)
    }

    private func installScript(at url: URL, body: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nset -eu\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
