// RunPlanDecompressorTests.swift - run --plan reads gzip files only through a program the plan pins (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

extension RunPlanTests {
    /// A storage step that stores `inputs/R1.fastq` with `tool`.
    static func decompressorStorageStep(_ tool: PlanToolPin) -> PlanStep {
        PlanStep(
            id: "storage", title: "Store reads", kind: .storage, tool: tool, arguments: [], deadlineSeconds: 60,
            inputs: ["inputs/R1.fastq"], outputs: ["out/sample.fastq.gz"]
        )
    }

    /// SWIFT fix 2 (a) and BIO fix 5 of the K4 part B review: a plan whose storage step reads gzip files and that pins
    /// no gzip, pigz or bgzip is refused before any tool, so no program outside the tool manifest reads the payload.
    /// Fix B2's rule asks a BBTools storage step to pin bgzip, so the plan decoder refuses that plan first, by its
    /// missing bgzip. A Trim Galore storage step, which that rule does not cover, meets the executor's own refusal.
    func testRunRefusesGzipReadingPlanWithNoPinnedDecompressor() throws {
        var bbtools = try RunPlanFixture()
        let reformat = try bbtools.addTool("reformat.sh", "printf '%s\\n' \"$@\" > logs/reformat.argv")
        let bbtoolsManifest = try bbtools.writeManifest()
        let settings = noneStorage(.illumina4)
        let bbtoolsPlan = try bbtools.writePlan(
            [Self.decompressorStorageStep(reformat)], manifestPin: bbtoolsManifest.pin, storage: settings.storage,
            clumping: settings.clumping
        )
        let decoderRefusal = try bbtools.run(bbtoolsPlan, ["--image-manifest", bbtoolsManifest.path])
        XCTAssertEqual(decoderRefusal.status, ExecutorExitCode.refused, decoderRefusal.stderr)
        XCTAssertEqual(decoderRefusal.record?.outcome, .refused)
        XCTAssertEqual(decoderRefusal.record?.refusedField, "tools")
        XCTAssertEqual(
            decoderRefusal.record?.reason,
            "This plan pins no bgzip for step storage, which runs reformat.sh. BBTools compresses its output with bgzip, "
                + "so the plan must name bgzip. No tool ran."
        )
        XCTAssertEqual(decoderRefusal.record?.steps, [])
        XCTAssertFalse(bbtools.exists("logs/reformat.argv"))
        XCTAssertFalse(bbtools.exists("out"))

        var fixture = try RunPlanFixture()
        let trimGalore = try fixture.addTool("trim_galore", "printf '%s\\n' \"$@\" > logs/trim_galore.argv")
        let manifest = try fixture.writeManifest()
        let plan = try fixture.writePlan(
            [Self.decompressorStorageStep(trimGalore)], manifestPin: manifest.pin,
            storage: PlanStorageSettings(
                clumpingTool: .trimGalore, compressor: .bgzip, qualityBinning: .illumina4, threads: 1, clumpifyHeapGB: 1,
                compressionLevel: 4, threadsSource: .option, clumpifyHeapSource: .option, clumpingToolSource: .option,
                compressorSource: .option, qualityBinningSource: .option
            ),
            clumping: PlanClumpingChoice(
                requested: .trimGalore, resolved: .trimGalore, resolvedSource: .option, heapBytes: 1_073_741_824,
                reason: "explicit clumping tool selection"
            )
        )
        let run = try fixture.run(plan, ["--image-manifest", manifest.path])
        XCTAssertEqual(run.status, ExecutorExitCode.refused, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .refused)
        XCTAssertEqual(record.refusedField, "tools")
        XCTAssertEqual(
            record.reason,
            "Step storage reads gzip files, and the plan pins no gzip, pigz or bgzip to read them. No tool ran."
        )
        XCTAssertEqual(record.steps, [])
        XCTAssertFalse(fixture.exists("logs/trim_galore.argv"))
        XCTAssertFalse(fixture.exists("out"))
    }

    /// SWIFT fix 2 (b) of the K4 part B review: the child launcher of `run --plan` starts no program outside the tool
    /// manifest, the reader's own `/usr/bin/gzip` included. Through the binary the refusal above comes first, so this
    /// runs in process.
    func testChildLauncherRefusesAProgramOutsideTheManifest() {
        let launcher = ExecutorChildLauncher(controller: StepController(), allowedPrograms: ["/opt/lungfish/bin/gzip"])
        let request = PortableChildRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-dc", "/absent/R1.fastq.gz"],
            environment: [:], label: "gzip -dc"
        )
        XCTAssertThrowsError(try launcher.start(request)) { error in
            XCTAssertEqual((error as? ExecutorSpawn.Failure)?.reason, "The program /usr/bin/gzip is not in the tool manifest.")
        }
    }
}
