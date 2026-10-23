import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

/// The Trim Galore storage route of `run --plan`, which owner answer O23 offers on CHTC (QA fix 4 of the K4 part B
/// review). `RunPlanMergedToMixedTests.swift` holds the merged-to-mixed step of the same fix.
extension RunPlanTests {
    /// The plan's note on what Trim Galore removes, `ClumpingTool.operationNotice` as the plan emitter copies it.
    static let trimGaloreNotice = "Trim Galore --clumpify also performs adapter/quality filtering and may remove short reads."

    /// A one-step plan that stores one interleaved file of two pairs with Trim Galore at a 1 GB heap. The fake Trim
    /// Galore keeps the first pair of its two mate files and writes a paired-end report of two pairs read and
    /// `reportedPairsWritten` written. The fake `reformat.sh` joins the two kept mates and gzips them, which interleaves
    /// one pair. The plan pins the `gzip` that reads the payload.
    private func trimGalorePlan(reportedPairsWritten: Int) throws -> (fixture: RunPlanFixture, plan: String, manifest: String) {
        var fixture = try RunPlanFixture()
        try RunPlanFixture.write(
            "@p1/1\nACGTACGT\n+\nIIIIIIII\n@p1/2\nTTGCATGC\n+\nIIIIIIII\n@p2/1\nAC\n+\nII\n@p2/2\nGT\n+\nII\n",
            to: fixture.planFolder + "/inputs/R1.fastq"
        )
        let report = #"{"trim_galore_version":"2.3.0","mode":"paired-end","read_number":1,"#
            + #""read_processing":{"total_reads":2,"reads_written":\#(reportedPairsWritten)},"#
            + #""parameters":{"quality_cutoff":20,"length_cutoff":20}}"#
        let trimGalore = try fixture.addTool("trim_galore", """
        printf '%s\\n' "$@" > logs/trim_galore.argv
        head -n 4 "${11}" > "$9/sample_R1_val_1.fq"
        head -n 4 "${12}" > "$9/sample_R2_val_2.fq"
        printf '%s' '\(report)' > "$9/sample_R1.fastq_trimming_report.json"
        """)
        let reformat = try fixture.addTool("reformat.sh", """
        for a in "$@"; do case "$a" in in1=*) A="${a#in1=}" ;; in2=*) B="${a#in2=}" ;; out=*) OUT="${a#out=}" ;; esac; done
        cat "$A" "$B" | gzip -c > "$OUT"
        """)
        let gzip = try fixture.addLoggingGzip()
        let manifest = try fixture.writeManifest()
        let step = PlanStep(
            id: "storage", title: "Store reads", kind: .storage, tool: trimGalore, arguments: [],
            environment: [PlanEnvironmentVariable(name: "_JAVA_OPTIONS", value: "-Xmx1g")], deadlineSeconds: 60,
            inputs: ["inputs/R1.fastq"], outputs: ["out/sample.fastq.gz"]
        )
        let plan = try fixture.writePlan(
            [step], manifestPin: manifest.pin,
            // The default binning, which the Trim Galore route does not run (BIO fix 1 of the K4 part C review).
            storage: PlanStorageSettings(
                clumpingTool: .trimGalore, compressor: .bgzip, qualityBinning: .illumina4, threads: 1, clumpifyHeapGB: 1,
                compressionLevel: 4, threadsSource: .option, clumpifyHeapSource: .option, clumpingToolSource: .option,
                compressorSource: .option, qualityBinningSource: .option
            ),
            clumping: PlanClumpingChoice(
                requested: .trimGalore, resolved: .trimGalore, resolvedSource: .option, heapBytes: 1_073_741_824,
                reason: "explicit clumping tool selection", operationNotice: Self.trimGaloreNotice
            ),
            pins: [reformat, gzip]
        )
        return (fixture, plan, manifest.path)
    }

    /// QA fix 4, O23. The single-input Trim Galore route splits the interleaved file by mate, runs Trim Galore's paired
    /// mode and interleaves its two outputs with `reformat.sh`. The record keeps both launches with their whole argv and
    /// no `_JAVA_OPTIONS`, counts the reads the report states as read and written, and states the payload. The plan the
    /// record names carries the note on what Trim Galore removes.
    func testTrimGaloreStorageRunsThroughPlan() throws {
        let (fixture, plan, manifest) = try trimGalorePlan(reportedPairsWritten: 1)
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .succeeded, record.reason ?? "")
        let stored = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(stored.outcome, .succeeded, stored.reason ?? "")
        let storage = try XCTUnwrap(stored.storage)
        let launches = try XCTUnwrap(storage.launches)
        XCTAssertEqual(launches.map(\.tool.id), ["trim_galore", "reformat.sh"])
        XCTAssertEqual(launches.map(\.outcome), [.succeeded, .succeeded])

        // The scratch folder's name holds a fresh UUID, so the frozen argv takes the name the run used.
        let trim = launches[0].argv
        let scratch = try XCTUnwrap(trim.firstIndex(of: "--output_dir").map { trim[$0 + 1] })
        XCTAssertTrue(scratch.hasPrefix("trim-galore-"), scratch)
        XCTAssertNotNil(UUID(uuidString: String(scratch.dropFirst("trim-galore-".count))), scratch)
        XCTAssertEqual(trim, [
            fixture.tools[0].path, "--clumpify", "--compression", "4", "--cores", "2", "--memory", "1G",
            "--output_dir", scratch, "--paired", scratch + "/input/sample_R1.fastq", scratch + "/input/sample_R2.fastq",
        ])
        XCTAssertEqual(fixture.text("logs/trim_galore.argv"), trim.dropFirst().joined(separator: "\n") + "\n")
        XCTAssertEqual(launches[1].argv, [
            fixture.tools[1].path, "in1=\(scratch)/sample_R1_val_1.fq", "in2=\(scratch)/sample_R2_val_2.fq",
            "out=out/sample.fastq.gz", "ow=t", "pigz=t", "zl=4", "threads=1", "interleaved=t",
        ])
        XCTAssertEqual(stored.argv, trim)
        for launch in launches {
            XCTAssertFalse(launch.environmentNames.contains("_JAVA_OPTIONS"), launch.tool.id)
        }
        XCTAssertFalse(stored.environmentNames.contains("_JAVA_OPTIONS"))
        XCTAssertFalse(fixture.exists(scratch), "the scratch folder outlived the step")

        // The report reads two pairs and writes one, and the record counts four records in and two out.
        XCTAssertEqual(storage.clumpingRan, true)
        // The plan names illumina4, and the route binned nothing and ran no bgzip probe, so the record states no binning
        // and no writer (BIO fix 1 of the K4 part C review).
        XCTAssertEqual(storage.qualityBinning, QualityBinningScheme.none)
        XCTAssertNil(storage.writer)
        XCTAssertEqual(stored.inputReadCount, 4)
        XCTAssertEqual(stored.outputReadCount, 2)

        let payloadURL = URL(fileURLWithPath: fixture.planFolder + "/out/sample.fastq.gz")
        let digest = try PortableDigest.sha256Hex(ofFileAt: payloadURL)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: payloadURL.path)[.size] as? Int64)
        XCTAssertEqual(stored.outputs, [ExecutorStepRecord.Output(path: "out/sample.fastq.gz", bytes: UInt64(size), sha256: digest)])
        XCTAssertEqual(record.payloads, [ExecutorPayloadRecord(
            relativePath: "out/sample.fastq.gz", sha256: digest, size: size, recordCount: 2,
            recordCountFile: ExecutorFileDigest(relativePath: "out/sample.fastq.gz", sha256: digest, size: size)
        )])
        let used = fixture.text("logs/gzip.used").split(separator: "\n").map(String.init)
        XCTAssertTrue(used.contains { $0.hasPrefix("-dc ") && $0.hasSuffix("out/sample.fastq.gz") }, "\(used)")

        let planData = try Data(contentsOf: URL(fileURLWithPath: plan))
        XCTAssertEqual(record.plan?.sha256, PortableDigest.sha256Hex(of: planData))
        XCTAssertEqual(try ExecutionPlan.decode(planData).clumping.operationNotice, Self.trimGaloreNotice)
    }

    /// QA fix 4. Trim Galore's report is checked against its output: a report of more reads written than the output
    /// holds fails the step with the counts in its reason, and no payload is kept.
    func testTrimGaloreReportThatDisagreesWithItsOutputFailsTheStep() throws {
        let (fixture, plan, manifest) = try trimGalorePlan(reportedPairsWritten: 2)
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failedStepID, "storage")
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(step.outcome, .failed)
        XCTAssertEqual(
            step.reason,
            "The storage step failed. trim_galore reports 4 reads written but its output holds 2; originals were kept"
        )
        XCTAssertEqual(step.outputs, [])
        XCTAssertNil(step.outputReadCount)
        XCTAssertEqual(record.payloads, [])
        XCTAssertEqual(step.storage?.launches?.map(\.tool.id), ["trim_galore", "reformat.sh"])
        XCTAssertFalse(fixture.exists("out/sample.fastq.gz"), "the unchecked output stayed")
    }
}
