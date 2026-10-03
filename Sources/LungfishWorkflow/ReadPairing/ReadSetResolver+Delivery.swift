// ReadSetResolver+Delivery.swift - Shapes a sample's reads for one tool's capability
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension ReadSetResolver {

    /// The plan for `source` in the form `capability` takes. Writes a split
    /// or an interleave only when the sample holds pairs and single reads.
    func deliver(
        _ source: ReadSetSource,
        inputURL: URL,
        capability: ReadPairingCapability,
        written: WrittenFiles
    ) throws -> ReadSetPlan {
        var shaped = source
        var steps: [ReadSetStep] = []
        var runs: [ReadSetRun]
        var singleReadReason: String?

        switch capability.kind {
        case .singleReadsOnly:
            // The tool reads every record on its own whatever the sample
            // holds, so handing it mates is not a choice the plan records.
            runs = [ReadSetRun(singleReads: Self.everyFileAsSingleReads(source))]

        case .pairsOnlyWhenAllPaired:
            if source.holdsPairsAndSingleReads {
                runs = [ReadSetRun(singleReads: Self.everyFileAsSingleReads(source))]
                singleReadReason = "The sample holds read pairs and single reads, and this tool cannot pair part of a sample, so every read runs as a single read. No read is left out."
            } else {
                runs = [ReadSetRun(matePairs: source.pairs, singleReads: source.singles)]
            }

        case .bothInOneRun where capability.mixedInput == .nameInterleavedStream:
            if !source.pairs.isEmpty, !source.singles.isEmpty {
                let (stream, step) = try interleaveByName(source, inputURL: inputURL, written: written)
                steps.append(step)
                runs = [ReadSetRun(mixedStreams: [stream])]
            } else {
                runs = [ReadSetRun(matePairs: source.pairs, singleReads: source.singles, mixedStreams: source.mixedStreams)]
            }

        case .bothInOneRun, .pairsOrSinglesPerRun:
            if !source.mixedStreams.isEmpty {
                var parts: [ReadSetSource.Part] = []
                for part in source.parts {
                    guard case .mixed(let stream) = part else {
                        parts.append(part)
                        continue
                    }
                    let split = try splitByName(stream, written: written)
                    steps.append(split.step)
                    parts += split.parts
                }
                shaped.parts = parts
            }
            if capability.kind == .pairsOrSinglesPerRun, !shaped.pairs.isEmpty, !shaped.singles.isEmpty {
                runs = [ReadSetRun(matePairs: shaped.pairs), ReadSetRun(singleReads: shaped.singles)]
            } else {
                runs = [ReadSetRun(matePairs: shaped.pairs, singleReads: shaped.singles)]
            }
        }

        return ReadSetPlan(
            inputURL: inputURL,
            capability: capability,
            sourceLayout: source.layout,
            layoutReason: source.reason,
            sequencingPlatform: source.platform,
            wasMaterialized: source.wasMaterialized,
            sampleHoldsPairsAndSingleReads: source.holdsPairsAndSingleReads,
            runs: runs,
            steps: steps,
            singleReadReason: singleReadReason,
            composition: shaped.composition
        )
    }

    /// Every file of the sample as single reads, mates marked as such.
    static func everyFileAsSingleReads(_ source: ReadSetSource) -> [ReadSetSingleReads] {
        source.parts.flatMap { part -> [ReadSetSingleReads] in
            switch part {
            case .single(let single):
                return [single]
            case .pair(let pair):
                let perFile: Int?
                if case .interleaved = pair.files { perFile = pair.pairCount.map { $0 * 2 } } else { perFile = pair.pairCount }
                return pair.urls.map { ReadSetSingleReads(url: $0, role: .pairsRunAsSingle, readCount: perFile) }
            case .mixed(let stream):
                let total = stream.pairCount.flatMap { pairs in stream.singleReadCount.map { pairs * 2 + $0 } }
                return [ReadSetSingleReads(url: stream.url, role: .pairsRunAsSingle, readCount: total)]
            }
        }
    }

    // MARK: - Writing

    /// Splits a mixed stream by fragment name into R1, R2 and single reads.
    private func splitByName(
        _ stream: ReadSetMixedStream,
        written: WrittenFiles
    ) throws -> (parts: [ReadSetSource.Part], step: ReadSetStep) {
        let stem = Self.outputStem(for: stream.url)
        let r1 = try newFile("\(stem).R1.fastq", written: written)
        let r2 = try newFile("\(stem).R2.fastq", written: written)
        let singles = try newFile("\(stem).single.fastq", written: written)
        let startedAt = Date()
        let counts: FASTQPairInterleaver.MixedCounts
        do {
            let handle1 = try FileHandle(forWritingTo: r1)
            defer { try? handle1.close() }
            let handle2 = try FileHandle(forWritingTo: r2)
            defer { try? handle2.close() }
            let handleSingles = try FileHandle(forWritingTo: singles)
            defer { try? handleSingles.close() }
            counts = try FASTQPairInterleaver.partitionMixed(
                interleaved: stream.url,
                r1: handle1,
                r2: handle2,
                unpaired: handleSingles
            )
        }
        var parts: [ReadSetSource.Part] = []
        var outputs: [URL] = []
        if counts.pairs > 0 {
            parts.append(.pair(ReadSetMatePair(files: .separate(r1: r1, r2: r2), pairCount: counts.pairs)))
            outputs += [r1, r2]
        } else {
            try? FileManager.default.removeItem(at: r1)
            try? FileManager.default.removeItem(at: r2)
        }
        if counts.unpaired > 0 {
            parts.append(.single(ReadSetSingleReads(url: singles, role: stream.singleReadRole, readCount: counts.unpaired)))
            outputs.append(singles)
        } else {
            try? FileManager.default.removeItem(at: singles)
        }
        let step = ReadSetStep(
            kind: .splitByName,
            inputURLs: [stream.url],
            outputURLs: outputs,
            pairCount: counts.pairs,
            singleReadCount: counts.unpaired,
            startedAt: startedAt,
            endedAt: Date()
        )
        return (parts, step)
    }

    /// Writes every pair of `source` with each R1 record followed by its R2
    /// record, mate names checked, then every single read, as one stream.
    private func interleaveByName(
        _ source: ReadSetSource,
        inputURL: URL,
        written: WrittenFiles
    ) throws -> (stream: ReadSetMixedStream, step: ReadSetStep) {
        let output = try newFile("\(Self.outputStem(for: inputURL)).interleaved.fastq", written: written)
        let startedAt = Date()
        var pairs = 0
        var singles = 0
        do {
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            for pair in source.pairs {
                switch pair.files {
                case .separate(let r1, let r2):
                    do {
                        let counts = try FASTQPairInterleaver.interleave(r1: r1, r2: r2, to: handle, requireMates: true)
                        pairs += counts.r1Records
                    } catch let error as FASTQPairInterleaver.InterleaveError {
                        throw ReadSetResolverError.mateNameMismatch(
                            r1Path: r1.path,
                            r2Path: r2.path,
                            detail: error.localizedDescription
                        )
                    }
                case .interleaved(let url):
                    pairs += try Self.copyRecords(of: url, to: handle) / 2
                }
            }
            for stream in source.mixedStreams {
                let counts = try FASTQPairInterleaver.countMixed(interleaved: stream.url)
                _ = try Self.copyRecords(of: stream.url, to: handle)
                pairs += counts.pairs
                singles += counts.unpaired
            }
            for single in source.singles {
                singles += try Self.copyRecords(of: single.url, to: handle)
            }
        }
        let roles = Set(source.singles.map(\.role) + source.mixedStreams.map(\.singleReadRole))
        let step = ReadSetStep(
            kind: .interleaveByName,
            inputURLs: source.parts.flatMap(\.urls),
            outputURLs: [output],
            pairCount: pairs,
            singleReadCount: singles,
            startedAt: startedAt,
            endedAt: Date()
        )
        let stream = ReadSetMixedStream(
            url: output,
            pairCount: pairs,
            singleReadCount: singles,
            singleReadRole: roles.count == 1 ? roles.first! : .mergedOrOrphan
        )
        return (stream, step)
    }

    /// Creates an empty file in the materialization directory.
    private func newFile(_ name: String, written: WrittenFiles) throws -> URL {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: materializationDirectory.path) {
            try fileManager.createDirectory(at: materializationDirectory, withIntermediateDirectories: true)
            written.addDirectory(materializationDirectory)
        }
        let url = materializationDirectory.appendingPathComponent(name)
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        written.add(url)
        return url
    }

    /// A unique name stem for files written for `url`.
    static func outputStem(for url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".gz", ".fastq", ".fq", ".lungfishfastq"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return "\(name)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// Copies every record of a plain or gzip FASTQ to `handle`, line by
    /// line, and returns the record count. Throws on a partial record.
    static func copyRecords(of url: URL, to handle: FileHandle) throws -> Int {
        let reader = try FASTQRawLineReader(url: url)
        defer { reader.close() }
        var buffer: [UInt8] = []
        var lines = 0
        while let line = try reader.nextLine() {
            buffer.append(contentsOf: line)
            buffer.append(0x0A)
            lines += 1
            if buffer.count >= 4 * 1_048_576 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        guard lines % 4 == 0 else {
            throw FASTQPairInterleaver.InterleaveError.malformedRecord(
                file: url.lastPathComponent,
                recordNumber: lines / 4 + 1,
                reason: "file ends inside the record"
            )
        }
        return lines / 4
    }
}
