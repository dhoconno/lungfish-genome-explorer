import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

/// The storage route `none` and the full passes of `run --plan` over the stored payload (lane K4, milestone M4 item b).
extension RunPlanTests {
    /// Three reads whose Phred+33 qualities straddle Q20 and Q30: 10 bases, 6 at or above Q20 (`5 ? I`, `> > ?`) and 3
    /// at or above Q30 (`? I`, `?`). `4` is Q19 and `>` is Q29.
    static let qualityReads = "@a\nACGTA\n+\n5?I+!\n@b\nGG\n+\n44\n@c\nTTT\n+\n>>?\n"

    func noneStorage(_ binning: QualityBinningScheme) -> (storage: PlanStorageSettings, clumping: PlanClumpingChoice) {
        (
            PlanStorageSettings(
                clumpingTool: .none, compressor: .bgzip, qualityBinning: binning, threads: 1, clumpifyHeapGB: 1,
                compressionLevel: 4, threadsSource: .option, clumpifyHeapSource: .option, clumpingToolSource: .option,
                compressorSource: .option, qualityBinningSource: .option
            ),
            PlanClumpingChoice(
                requested: .none, resolved: .none, resolvedSource: .option, heapBytes: 1_073_741_824,
                reason: "explicit clumping tool selection"
            )
        )
    }

    /// Tally K4.1, BIO N6 and BIO K4A fixes 2 and 3. The compressor alone stores the reads, and the record holds the
    /// payload with its record count, seqkit's table byte for byte with the file it read, and the executor's own exact
    /// Q20 and Q30 count of the gzip payload, which names the executor as its tool. SWIFT fixes 2 and 4 and BIO fix 5 of
    /// the K4 part B review: the payload is read through the plan's pinned gzip, and the count step names the running
    /// executor by the label `/proc/self/exe`, so the record holds no folder of the machine that started it.
    func testFullPassesRecordExactCountsOfStoredPayload() throws {
        var fixture = try RunPlanFixture()
        try RunPlanFixture.write(Self.qualityReads, to: fixture.planFolder + "/inputs/R1.fastq")
        let bgzip = try fixture.addTool("bgzip", "for a in \"$@\"; do last=\"$a\"; done\ngzip -c < \"$last\"")
        let seqkit = try fixture.addTool("seqkit", "printf 'file\\tformat\\tnum_seqs\\n%s\\tFASTQ\\t3\\n' \"$4\"\necho 'seqkit note' >&2")
        let gzip = try fixture.addLoggingGzip()
        let manifest = try fixture.writeManifest()
        let payload = "out/sample.fastq.gz"
        let steps = [
            PlanStep(
                id: "storage", title: "Store reads", kind: .storage, tool: bgzip, arguments: [], deadlineSeconds: 60,
                inputs: ["inputs/R1.fastq"], outputs: [payload]
            ),
            PlanStep(
                id: "statistics", title: "Compute statistics", kind: .statistics, tool: seqkit,
                arguments: ["stats", "-a", "-T", payload], deadlineSeconds: 60, inputs: [payload], outputs: [],
                standardOutput: "out/sample.seqkit-stats.tsv"
            ),
            PlanStep(
                id: "quality-count", title: "Count Q20 and Q30 bases", kind: .qualityCount, tool: nil, arguments: [],
                deadlineSeconds: 60, inputs: [payload], outputs: []
            ),
        ]
        let settings = noneStorage(.none)
        let plan = try fixture.writePlan(
            steps, manifestPin: manifest.pin, storage: settings.storage, clumping: settings.clumping, pins: [gzip]
        )
        let run = try fixture.run(plan, ["--image-manifest", manifest.path])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .succeeded, record.reason ?? "")
        XCTAssertEqual(record.steps.map(\.id), ["storage", "statistics", "quality-count"])
        XCTAssertEqual(record.steps.map(\.outcome), [.succeeded, .succeeded, .succeeded])

        let bytes = try Data(contentsOf: URL(fileURLWithPath: fixture.planFolder + "/" + payload))
        let stored = ExecutorFileDigest(relativePath: payload, sha256: PortableDigest.sha256Hex(of: bytes), size: Int64(bytes.count))
        XCTAssertEqual(record.payloads, [ExecutorPayloadRecord(
            relativePath: payload, sha256: stored.sha256, size: stored.size, recordCount: 3, recordCountFile: stored
        )])

        let store = record.steps[0]
        XCTAssertEqual(store.inputReadCount, 3)
        XCTAssertEqual(store.outputReadCount, 3)
        XCTAssertEqual(store.storage?.clumpingRan, false)
        XCTAssertEqual(store.storage?.writer?.name, "bgzip")
        XCTAssertEqual(store.storage?.launches?.map(\.tool.id), ["bgzip"])

        let stats = record.steps[1]
        let table = try Data(contentsOf: URL(fileURLWithPath: fixture.planFolder + "/out/sample.seqkit-stats.tsv"))
        XCTAssertEqual(stats.standardOutput, ExecutorCapturedOutput(
            text: "file\tformat\tnum_seqs\n\(payload)\tFASTQ\t3\n", sha256: PortableDigest.sha256Hex(of: table),
            size: Int64(table.count)
        ))
        XCTAssertEqual(stats.inputFile, stored)
        XCTAssertEqual(stats.argv, [fixture.tools[1].path, "stats", "-a", "-T", payload])
        XCTAssertEqual(stats.toolExitCode, 0)
        XCTAssertEqual(stats.stderrTail, "seqkit note\n")

        let count = record.steps[2]
        XCTAssertEqual(count.qualityCounts, ExecutorQualityCounts(
            baseCount: 10, q20Count: 6, q30Count: 3, recordCount: 3, file: stored
        ))
        XCTAssertEqual(count.tool?.id, "lungfish-executor")
        XCTAssertEqual(count.tool?.version, "test")
        XCTAssertEqual(count.tool?.build, RunPlanFixture.zeros)
        XCTAssertEqual(count.tool?.versionSource, .planPin)
        XCTAssertEqual(count.tool?.sha256, fixture.executorEntry.sha256)
        XCTAssertEqual(count.argv, record.executorArguments)

        let used = fixture.text("logs/gzip.used").split(separator: "\n").map(String.init)
        XCTAssertFalse(used.isEmpty, "the pinned gzip never ran")
        for line in used {
            XCTAssertTrue(line.hasPrefix("-dc ") && line.hasSuffix(payload), line)
        }

        XCTAssertEqual(count.tool?.path, "/proc/self/exe")
        var withoutTails = record
        withoutTails.steps = withoutTails.steps.map { step in
            var step = step
            step.stderrTail = ""
            return step
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(withoutTails), as: UTF8.self)
        let binaryFolder = URL(fileURLWithPath: fixture.binary).deletingLastPathComponent().path
        XCTAssertFalse(text.contains(binaryFolder), "the record names the folder \(binaryFolder)")
    }

    /// QA fix 3 of the K4 part C review. The executor reads every gzip file of its own steps through the first of gzip,
    /// pigz and bgzip that the plan pins, so the routes the node takes most, pigz for a merged plan and bgzip alone, read
    /// the payload as the gzip route does. Each reader logs the argv of a read to logs/<id>.used and reads through the
    /// host's gzip, and bgzip also stores the reads, since it is the step's compressor.
    func testPayloadIsReadThroughTheFirstPinnedOfGzipPigzBgzip() throws {
        let payload = "out/sample.fastq.gz"
        for (readers, winner) in [(["gzip", "bgzip"], "gzip"), (["pigz", "bgzip"], "pigz"), (["bgzip"], "bgzip")] {
            var fixture = try RunPlanFixture()
            let folder = fixture.planFolder
            try RunPlanFixture.write(Self.qualityReads, to: folder + "/inputs/R1.fastq")
            var pins: [PlanToolPin] = []
            for id in readers {
                pins.append(try fixture.addTool(id, """
                if [ "$1" = "-dc" ]; then printf '%s\\n' "$*" >> '\(folder)/logs/\(id).used'; exec /usr/bin/gzip -dc "$2"; fi
                for a in "$@"; do last="$a"; done
                gzip -c < "$last"
                """))
            }
            let manifest = try fixture.writeManifest()
            let steps = [
                PlanStep(
                    id: "storage", title: "Store reads", kind: .storage, tool: PlanToolPin(id: "bgzip", version: "1.0", build: "t0"),
                    arguments: [], deadlineSeconds: 60, inputs: ["inputs/R1.fastq"], outputs: [payload]
                ),
                PlanStep(
                    id: "quality-count", title: "Count Q20 and Q30 bases", kind: .qualityCount, tool: nil, arguments: [],
                    deadlineSeconds: 60, inputs: [payload], outputs: []
                ),
            ]
            let settings = noneStorage(.none)
            let plan = try fixture.writePlan(
                steps, manifestPin: manifest.pin, storage: settings.storage, clumping: settings.clumping, pins: pins
            )
            let run = try fixture.run(plan, ["--image-manifest", manifest.path])
            XCTAssertEqual(run.status, ExecutorExitCode.succeeded, "\(winner): \(run.stderr)")
            let record = try XCTUnwrap(run.record, winner)
            XCTAssertEqual(record.outcome, .succeeded, "\(winner): \(record.reason ?? "")")
            let bytes = try Data(contentsOf: URL(fileURLWithPath: folder + "/" + payload))
            let stored = ExecutorFileDigest(relativePath: payload, sha256: PortableDigest.sha256Hex(of: bytes), size: Int64(bytes.count))
            XCTAssertEqual(record.payloads.first?.recordCount, 3, winner)
            XCTAssertEqual(record.steps.first?.outputReadCount, 3, winner)
            XCTAssertEqual(record.steps.last?.qualityCounts, ExecutorQualityCounts(
                baseCount: 10, q20Count: 6, q30Count: 3, recordCount: 3, file: stored
            ), winner)
            for id in readers {
                XCTAssertEqual(fixture.exists("logs/\(id).used"), id == winner, "\(winner) row, logs/\(id).used")
            }
            let used = fixture.text("logs/\(winner).used").split(separator: "\n").map(String.init)
            XCTAssertFalse(used.isEmpty, "\(winner) never read the payload")
            for line in used {
                XCTAssertTrue(line.hasPrefix("-dc ") && line.hasSuffix(payload), "\(winner): \(line)")
            }
        }
    }

    /// M4 item 1. The route `none` with a binning scheme runs `reformat.sh` with the argv of the Mac's
    /// `reformatQuantize`, after the writer probe, and records the writer, the level and the binning.
    func testStorageRouteNoneBinsWithReformatAsTheMacDoes() throws {
        var fixture = try RunPlanFixture()
        let reformat = try fixture.addTool("reformat.sh", """
        for a in "$@"; do case "$a" in in=*) IN="${a#in=}" ;; out=*) OUT="${a#out=}" ;; esac; done
        printf '%s\\n' "$@" > logs/reformat.argv
        gzip -c < "$IN" > "$OUT"
        """)
        // BIO N3. The plan pins the bgzip BBTools writes through, and it answers `bgzip -h` as BBTools' probe asks.
        let bgzip = try fixture.addTool("bgzip", "[ \"$1\" = \"-h\" ]")
        let gzip = try fixture.addLoggingGzip()
        let manifest = try fixture.writeManifest()
        let settings = noneStorage(.illumina4)
        let step = PlanStep(
            id: "storage", title: "Store reads", kind: .storage, tool: reformat, arguments: [], deadlineSeconds: 60,
            inputs: ["inputs/R1.fastq"], outputs: ["out/sample.fastq.gz"]
        )
        let plan = try fixture.writePlan(
            [step], manifestPin: manifest.pin, storage: settings.storage, clumping: settings.clumping, pins: [bgzip, gzip]
        )
        let run = try fixture.run(plan, ["--image-manifest", manifest.path])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        let stored = try XCTUnwrap(run.record?.steps.first)
        XCTAssertEqual(stored.outcome, .succeeded, stored.reason ?? "")
        let argv = fixture.text("logs/reformat.argv").split(separator: "\n").map(String.init)
        XCTAssertEqual(argv, [
            "in=inputs/R1.fastq", "out=out/sample.fastq.gz", "ow=t", "pigz=t", "zl=4", "threads=1", "interleaved=f",
            "quantize=0,8,13,22,27,32,37",
        ])
        XCTAssertEqual(stored.argv, [fixture.tools[0].path] + argv)
        XCTAssertEqual(stored.storage?.clumpingRan, false)
        XCTAssertEqual(stored.storage?.qualityBinning, .illumina4)
        XCTAssertEqual(stored.storage?.writer?.name, "bgzip")
        XCTAssertEqual(stored.storage?.writer?.tool?.id, "bgzip")
        XCTAssertEqual(stored.storage?.launches?.map(\.tool.id), ["bgzip", "reformat.sh"])
        XCTAssertEqual(stored.storage?.effectiveCompressionLevel, 4)
        XCTAssertEqual(stored.outputReadCount, 1)
        XCTAssertEqual(run.record?.payloads.first?.recordCount, 1)
    }
}
