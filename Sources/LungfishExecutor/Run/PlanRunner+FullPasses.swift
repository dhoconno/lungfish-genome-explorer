// PlanRunner+FullPasses.swift - The full passes of run --plan over the stored payload (CHTC lane K4, milestone M4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The three full passes of tally K4.1 over the stored payload. The record count stays inside the storage step it
/// verifies, as on the Mac (BIO N6), and reaches the payload's entry. `seqkit stats -a -T` keeps its standard output
/// byte for byte and names the file it read. The Q20 and Q30 count is the executor's own step, which names the executor
/// as its tool and reads a gzip payload through the plan's decompressor.
extension PlanRunner {
    /// The most bytes of a kept standard output the record holds. `seqkit stats -a -T` of one file prints two lines.
    static let keptStandardOutputLimit = 16 << 20

    /// The path the count step names for the running executor, a label on every OS (SWIFT ruling N8). The record states
    /// the binary itself by `tool.sha256`, the digest of the file the self-check read, so a replay on the Mac never
    /// writes the folder it started the executor from.
    static let runningExecutorPath = "/proc/self/exe"

    /// The payload entries of a storage step that succeeded: each output's digest, with the record count the step's own
    /// pass took of that file (tally K4.1).
    static func payloads(of step: ExecutorStepRecord) -> [ExecutorPayloadRecord] {
        guard step.kind == .storage, step.outcome == .succeeded else { return [] }
        return step.outputs.map { output in
            let file = ExecutorFileDigest(relativePath: output.path, sha256: output.sha256, size: Int64(output.bytes))
            return ExecutorPayloadRecord(
                relativePath: output.path, sha256: output.sha256, size: Int64(output.bytes),
                recordCount: step.outputReadCount, recordCountFile: step.outputReadCount == nil ? nil : file
            )
        }
    }

    /// Fills a `statistics` step that succeeded with its standard output byte for byte, the SHA-256 and size of those
    /// bytes, and the file seqkit read (tally K4.1, BIO K4A fix 2). A step whose output cannot be read fails.
    func captureStatistics(_ step: PlanStep, standardOutput: PlanOutputFile, into record: inout ExecutorStepRecord) {
        guard record.outcome == .succeeded else { return }
        do {
            let bytes = try Self.readKept(standardOutput, workRoot: resolver.workRoot)
            record.standardOutput = ExecutorCapturedOutput(
                text: String(decoding: bytes, as: UTF8.self), sha256: PortableDigest.sha256Hex(of: bytes),
                size: Int64(bytes.count)
            )
            guard step.inputs.count == 1, let input = step.inputs.first else {
                throw ExecutorSpawn.Failure(reason: "Step \(step.id) must name the one stored file seqkit reads.")
            }
            record.inputFile = try fileDigest(input)
        } catch {
            record.outcome = .failed
            record.outputs = []
            record.reason = "The executor could not keep the statistics of step \(step.id). \(Self.describe(error))"
        }
    }

    /// The executor's own Q20 and Q30 count of the stored payload (BIO N6). It names the tool `lungfish-executor` with the
    /// build the plan pins and the SHA-256 of the running binary, and the executor's own argv as run, since the counter
    /// has none. The file is read through `FASTQQualityByteCounter`, a gzip file through the plan's decompressor child.
    func runQualityCount(_ step: PlanStep, run: ExecutorRunRecord) -> ExecutorStepRecord {
        let build = prepared.plan.executor
        var record = ExecutorStepRecord(
            id: step.id, kind: step.kind,
            tool: ExecutorToolRecord(
                id: "lungfish-executor", version: build.lgeVersion, build: build.lgeCommit, path: Self.runningExecutorPath,
                versionSource: .planPin, sha256: run.executor.sha256
            ),
            outcome: .failed, argv: run.executorArguments, environmentNames: [],
            graceSeconds: prepared.plan.graceSeconds, deadlineSeconds: step.deadlineSeconds,
            startedAt: ExecutorRunRecord.timestamp(Date()), endedAt: "", wallSeconds: 0
        )
        let started = ContinuousClock.now
        let launcher = ExecutorChildLauncher(
            controller: controller, decompressor: prepared.decompressor,
            allowedPrograms: Set(prepared.manifest.tools.map(\.path)), graceSeconds: prepared.plan.graceSeconds
        )
        do {
            guard step.inputs.count == 1, let input = step.inputs.first else {
                throw ExecutorSpawn.Failure(reason: "Step \(step.id) must name the one stored file it counts.")
            }
            let deadline = started.advanced(by: .milliseconds(Int64(step.deadlineSeconds * 1000)))
            let counted = try Self.countQualities(
                URL(fileURLWithPath: resolver.workRoot).appendingPathComponent(input), launcher: launcher,
                controller: controller, deadline: deadline, stepID: step.id
            )
            record.qualityCounts = ExecutorQualityCounts(
                baseCount: counted.fractions.baseCount, q20Count: counted.fractions.q20Count,
                q30Count: counted.fractions.q30Count, recordCount: counted.records, file: try fileDigest(input)
            )
            record.outcome = .succeeded
        } catch {
            record.reason = "The executor could not count the Q20 and Q30 bases of step \(step.id). \(Self.describe(error))"
        }
        if let signal = controller.interruptSignal {
            record.outcome = .interrupted
            record.signal = signal
            record.signalName = ExecutorSignals.name(signal)
            record.qualityCounts = nil
            record.reason = "The executor received \(ExecutorSignals.name(signal)) and stopped the step."
        }
        record.wallSeconds = StepController.seconds(since: started)
        record.endedAt = ExecutorRunRecord.timestamp(Date())
        return record
    }

    /// One pass over `url` that feeds every byte to `FASTQQualityByteCounter`, the Mac's exact counter, and takes the
    /// records it began. It stops at a termination signal or at the step's deadline.
    static func countQualities(
        _ url: URL, launcher: any PortableChildLauncher, controller: StepController,
        deadline: ContinuousClock.Instant, stepID: String
    ) throws -> (fractions: FASTQQualityFractions, records: Int64) {
        let reader = try FASTQRawLineReader(url: url, launcher: launcher)
        defer { reader.close() }
        var counter = FASTQQualityByteCounter()
        while let chunk = try reader.readChunk() {
            if controller.interruptSignal != nil { throw CancellationError() }
            guard ContinuousClock.now < deadline else {
                throw ExecutorSpawn.Failure(reason: "Step \(stepID) passed its deadline from the plan.")
            }
            try chunk.withUnsafeBytes { try counter.consume($0) }
        }
        let fractions = try counter.finish()
        return (fractions, counter.recordCount)
    }

    /// The SHA-256 and size of a work-root file, stated by its work-root path.
    func fileDigest(_ relativePath: String) throws -> ExecutorFileDigest {
        let url = URL(fileURLWithPath: resolver.workRoot).appendingPathComponent(relativePath)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        return ExecutorFileDigest(relativePath: relativePath, sha256: try PortableDigest.sha256Hex(ofFileAt: url), size: size)
    }

    /// Every byte of a step's kept output, read through a new descriptor only when it names the file the step wrote, by
    /// device and inode, as `stderrTail` reads.
    static func readKept(_ file: PlanOutputFile, workRoot: String, limit: Int = keptStandardOutputLimit) throws -> Data {
        let fd = open(workRoot + "/" + file.relativePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ExecutorSpawn.Failure(reason: "\(file.relativePath) cannot be opened.") }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, UInt64(truncatingIfNeeded: status.st_dev) == file.device,
              UInt64(truncatingIfNeeded: status.st_ino) == file.inode else {
            throw ExecutorSpawn.Failure(reason: "\(file.relativePath) is not the file the step wrote.")
        }
        guard status.st_size <= off_t(limit) else {
            throw ExecutorSpawn.Failure(reason: "\(file.relativePath) holds \(status.st_size) bytes, over the \(limit) the record keeps.")
        }
        var buffer = [UInt8](repeating: 0, count: Int(status.st_size))
        var filled = 0
        while filled < buffer.count {
            let count = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + filled, raw.count - filled, off_t(filled))
            }
            if count > 0 {
                filled += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                throw ExecutorSpawn.Failure(reason: "\(file.relativePath) ended before its size.")
            }
        }
        return Data(buffer)
    }

    static func describe(_ error: any Error) -> String {
        if let failure = error as? ExecutorSpawn.Failure { return failure.reason }
        if error is CancellationError { return "The step was stopped." }
        return "\(error)"
    }
}
