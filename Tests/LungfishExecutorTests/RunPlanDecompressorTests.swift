// RunPlanDecompressorTests.swift - run --plan reads gzip files only through a program the plan pins (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

extension RunPlanTests {
    /// SWIFT fix 2 (a) and BIO fix 5 of the K4 part B review: a plan whose storage step reads gzip files and that pins
    /// no gzip, pigz or bgzip is refused before any tool, so no program outside the tool manifest reads the payload.
    func testRunRefusesGzipReadingPlanWithNoPinnedDecompressor() throws {
        var fixture = try RunPlanFixture()
        let reformat = try fixture.addTool("reformat.sh", """
        for a in "$@"; do case "$a" in in=*) IN="${a#in=}" ;; out=*) OUT="${a#out=}" ;; esac; done
        printf '%s\\n' "$@" > logs/reformat.argv
        gzip -c < "$IN" > "$OUT"
        """)
        let manifest = try fixture.writeManifest()
        let settings = noneStorage(.illumina4)
        let step = PlanStep(
            id: "storage", title: "Store reads", kind: .storage, tool: reformat, arguments: [], deadlineSeconds: 60,
            inputs: ["inputs/R1.fastq"], outputs: ["out/sample.fastq.gz"]
        )
        let plan = try fixture.writePlan([step], manifestPin: manifest.pin, storage: settings.storage, clumping: settings.clumping)
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
        XCTAssertFalse(fixture.exists("logs/reformat.argv"))
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
