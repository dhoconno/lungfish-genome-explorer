// ViralReconReadPairing.swift - Hand interleaved pairs to viralrecon as fastq_1/fastq_2
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// LGE stores a paired Illumina import as ONE interleaved FASTQ inside a
// `.lungfishfastq` bundle. nf-core/viralrecon reads pairs only through the
// samplesheet's fastq_1/fastq_2 columns, so a bundle row with one file used
// to run single-end and every R2 read was thrown away at mapping. The repo's
// read-layout contract (FASTQInputLayout.swift) is to hand pairs to a tool
// that can take them: a strictly interleaved file is split into two gzip
// mate files (the same split Kraken 2 and TaxTriage use, compressed because
// viralrecon accepts only `.fastq.gz`) and both go in the samplesheet. A file
// that mixes merged reads with pairs, or holds single reads, stays a
// single-end row, because a positional split would mis-pair it.
//
// The split is part of the RUN, not of the wizard's request builder: the
// GUI and `lungfish-cli workflow run nf-core/viralrecon` both call
// `prepareIlluminaSamples` from inside the operation, and every decision is
// recorded next to the run bundle and in its provenance.

import Foundation
import LungfishIO

// MARK: - Decision

/// What one samplesheet row's reads looked like and how viralrecon gets them.
public struct ViralReconReadPairingDecision: Codable, Sendable, Equatable {
    public let sampleName: String
    /// The FASTQ file(s) the row started from, as the user chose them.
    public let sourceFASTQURLs: [URL]
    public let layout: FASTQInputLayout
    public let handling: FASTQReadLayoutHandling
    /// Plain-language reason for the layout (the resolver's evidence).
    public let reason: String
    /// Pairs written to the split mate files; nil until the split has run.
    public let pairCount: Int?
    /// The temporary R1/R2 files a split produced; removed once the run ends.
    public let splitR1URL: URL?
    public let splitR2URL: URL?

    public init(
        sampleName: String,
        sourceFASTQURLs: [URL],
        layout: FASTQInputLayout,
        handling: FASTQReadLayoutHandling,
        reason: String,
        pairCount: Int? = nil,
        splitR1URL: URL? = nil,
        splitR2URL: URL? = nil
    ) {
        self.sampleName = sampleName
        self.sourceFASTQURLs = sourceFASTQURLs
        self.layout = layout
        self.handling = handling
        self.reason = reason
        self.pairCount = pairCount
        self.splitR1URL = splitR1URL
        self.splitR2URL = splitR2URL
    }

    /// Whether viralrecon sees this row as paired-end.
    public var runsPaired: Bool { handling != .asSingle }

    /// Whether the row's reads must be split before the run.
    public var needsSplit: Bool { handling == .splitToR1R2 }

    /// One line for the run log and the run summary.
    public var summary: String {
        switch handling {
        case .splitToR1R2:
            if let pairCount {
                return "\(sampleName): \(layout.displayName), split into R1/R2 (\(pairCount) pairs), runs paired-end"
            }
            return "\(sampleName): \(layout.displayName), will be split into R1/R2 and run paired-end"
        case .asPairs:
            return "\(sampleName): \(layout.displayName), runs paired-end"
        case .asSingle:
            return "\(sampleName): \(layout.displayName), runs single-end"
        }
    }

    /// A caution for a row whose mates could not be handed over as pairs.
    public var warning: String? {
        switch layout {
        case .mixedMergedAndPairs:
            return "\(sampleName) mixes merged reads with pairs, so viralrecon runs it single-end; a positional split would mis-pair its mates."
        case .singleEnd, .strictlyInterleaved, .pairedFiles:
            return nil
        }
    }

    /// Provenance record for the run's parameters.
    public var provenanceValue: ParameterValue {
        var fields: [String: ParameterValue] = [
            "sample": .string(sampleName),
            "sources": .array(sourceFASTQURLs.map { .file($0) }),
            "readLayout": .string(layout.rawValue),
            "handling": .string(handling.rawValue),
            "readLayoutReason": .string(reason),
        ]
        if let pairCount { fields["pairs"] = .integer(pairCount) }
        if let splitR1URL { fields["splitR1"] = .file(splitR1URL) }
        if let splitR2URL { fields["splitR2"] = .file(splitR2URL) }
        return .dictionary(fields)
    }
}

// MARK: - Prepared samples

/// The samples viralrecon should see, with the decision behind each row.
public struct ViralReconPreparedIlluminaSamples: Sendable, Equatable {
    public let samples: [ViralReconSample]
    public let decisions: [ViralReconReadPairingDecision]

    public var didSplit: Bool { decisions.contains { $0.splitR1URL != nil } }
    public var needsSplit: Bool { decisions.contains(where: \.needsSplit) }
}

// MARK: - ViralReconReadPairing

public enum ViralReconReadPairing {

    public enum PairingError: Error, LocalizedError, Equatable {
        case interleavedSplitFailed(sampleName: String, reason: String)
        case malformedSamplesheet(URL, reason: String)

        public var errorDescription: String? {
            switch self {
            case .interleavedSplitFailed(let sampleName, let reason):
                return "Could not split the interleaved pairs of \(sampleName) into R1/R2 for viralrecon: \(reason)"
            case .malformedSamplesheet(let url, let reason):
                return "Cannot read the viralrecon samplesheet \(url.path): \(reason)"
            }
        }
    }

    /// The consumer declared in `FASTQConsumerRegistry`.
    public static let consumerID = "viralrecon.illumina"

    /// Directory (under a whitespace-free scratch) holding the split mate files.
    public static let splitDirectoryName = "interleaved-split"

    /// JSON next to the run bundle's inputs that records every decision.
    public static let decisionsFilename = "read-pairing.json"

    /// The samplesheet viralrecon is launched with once interleaved rows
    /// were split, kept beside the caller's samplesheet in the run bundle.
    public static let pairedSamplesheetFilename = "samplesheet.paired.csv"

    // MARK: Decisions without touching the reads

    /// Resolves how viralrecon gets each sample's reads, without splitting.
    ///
    /// Two files are R1/R2. One file is resolved through
    /// ``FASTQInputLayoutResolver`` (bundle metadata, then a bounded scan of
    /// the records). More than two files keep the builder's row pairing.
    public static func decisions(for samples: [ViralReconSample]) -> [ViralReconReadPairingDecision] {
        samples.map(decision(for:))
    }

    public static func decision(for sample: ViralReconSample) -> ViralReconReadPairingDecision {
        switch sample.fastqURLs.count {
        case 1:
            let resolution = FASTQInputLayoutResolver.resolve(inputURLs: sample.fastqURLs)
            let handling: FASTQReadLayoutHandling = resolution.layout == .strictlyInterleaved
                ? .splitToR1R2
                : .asSingle
            return ViralReconReadPairingDecision(
                sampleName: sample.sampleName,
                sourceFASTQURLs: sample.fastqURLs,
                layout: resolution.layout,
                handling: handling,
                reason: resolution.reason
            )
        case 2:
            let resolution = FASTQInputLayoutResolver.resolve(inputURLs: sample.fastqURLs, pairedFiles: true)
            return ViralReconReadPairingDecision(
                sampleName: sample.sampleName,
                sourceFASTQURLs: sample.fastqURLs,
                layout: resolution.layout,
                handling: .asPairs,
                reason: resolution.reason
            )
        default:
            let count = sample.fastqURLs.count
            if count.isMultiple(of: 2) {
                return ViralReconReadPairingDecision(
                    sampleName: sample.sampleName,
                    sourceFASTQURLs: sample.fastqURLs,
                    layout: .pairedFiles,
                    handling: .asPairs,
                    reason: "\(count) input files are written as \(count / 2) R1/R2 rows."
                )
            }
            return ViralReconReadPairingDecision(
                sampleName: sample.sampleName,
                sourceFASTQURLs: sample.fastqURLs,
                layout: .singleEnd,
                handling: .asSingle,
                reason: count == 0
                    ? "No input file."
                    : "\(count) input files are written as adjacent rows; the last one is single-end."
            )
        }
    }

    // MARK: Split inside the run

    /// Splits every strictly interleaved single-file sample into gzip R1/R2
    /// files under `splitRoot` and returns the samples viralrecon should see.
    ///
    /// Samples that are already R1/R2, single-end, or mixed are left alone.
    /// `splitRoot` must be whitespace-free (viralrecon's samplesheet schema
    /// rejects a FASTQ path with a space); the caller removes it once the run
    /// no longer needs the halves.
    public static func prepareIlluminaSamples(
        _ samples: [ViralReconSample],
        splitRoot: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ViralReconPreparedIlluminaSamples {
        var prepared = samples
        var decisions: [ViralReconReadPairingDecision] = []
        var usedNames = Set<String>()

        for (index, sample) in samples.enumerated() {
            try Task.checkCancellation()
            let decision = decision(for: sample)
            guard decision.needsSplit, let source = sample.fastqURLs.first else {
                decisions.append(decision)
                continue
            }
            progress?("Splitting interleaved pairs of \(sample.sampleName) into R1/R2 for viralrecon...")
            let directoryName = uniqueDirectoryName(for: sample.sampleName, usedNames: &usedNames)
            let directory = splitRoot.appendingPathComponent(directoryName, isDirectory: true)
            let split: (r1: URL, r2: URL, counts: FASTQPairInterleaver.Counts)
            do {
                split = try await splitInterleavedInput(source, into: directory)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PairingError.interleavedSplitFailed(
                    sampleName: sample.sampleName,
                    reason: error.localizedDescription
                )
            }
            prepared[index] = ViralReconSample(
                sampleName: sample.sampleName,
                sourceBundleURL: sample.sourceBundleURL,
                fastqURLs: [split.r1, split.r2],
                barcode: sample.barcode,
                sequencingSummaryURL: sample.sequencingSummaryURL
            )
            decisions.append(ViralReconReadPairingDecision(
                sampleName: sample.sampleName,
                sourceFASTQURLs: sample.fastqURLs,
                layout: decision.layout,
                handling: .splitToR1R2,
                reason: decision.reason,
                pairCount: split.counts.r1Records,
                splitR1URL: split.r1,
                splitR2URL: split.r2
            ))
        }
        return ViralReconPreparedIlluminaSamples(samples: prepared, decisions: decisions)
    }

    /// Splits a strictly interleaved FASTQ (plain or gzip) into
    /// `<stem>_R1.fastq.gz` and `<stem>_R2.fastq.gz` inside `directory`.
    ///
    /// Records are copied byte for byte through `/usr/bin/gzip -c`, so the
    /// halves never touch the disk uncompressed. `directory` is replaced if
    /// it exists and removed again if the split fails.
    public static func splitInterleavedInput(
        _ source: URL,
        into directory: URL
    ) async throws -> (r1: URL, r2: URL, counts: FASTQPairInterleaver.Counts) {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var stem = source.lastPathComponent
        for suffix in [".gz", ".fastq", ".fq"] where stem.lowercased().hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
        }
        let r1 = directory.appendingPathComponent("\(stem)_R1.fastq.gz")
        let r2 = directory.appendingPathComponent("\(stem)_R2.fastq.gz")

        let worker = Task.detached(priority: .utility) { () throws -> FASTQPairInterleaver.Counts in
            let sink1 = try GzipFileSink(destination: r1)
            let sink2 = try GzipFileSink(destination: r2)
            let counts: FASTQPairInterleaver.Counts
            do {
                counts = try FASTQPairInterleaver.deinterleave(
                    interleaved: source,
                    r1: sink1.writeHandle,
                    r2: sink2.writeHandle
                )
            } catch {
                sink1.abort()
                sink2.abort()
                throw error
            }
            try sink1.finish()
            try sink2.finish()
            return counts
        }
        do {
            let counts = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            return (r1, r2, counts)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    // MARK: Samplesheet round trip

    /// Reads an Illumina samplesheet (`sample,fastq_1,fastq_2`) back into
    /// samples so the CLI can make the same decisions the GUI makes.
    public static func parseIlluminaSamplesheet(at url: URL) throws -> [ViralReconSample] {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PairingError.malformedSamplesheet(url, reason: error.localizedDescription)
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first else {
            throw PairingError.malformedSamplesheet(url, reason: "the file is empty")
        }
        let columns = parseCSVLine(header).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let sampleIndex = columns.firstIndex(of: "sample"),
              let fastq1Index = columns.firstIndex(of: "fastq_1") else {
            throw PairingError.malformedSamplesheet(url, reason: "the header must name sample and fastq_1 columns")
        }
        let fastq2Index = columns.firstIndex(of: "fastq_2")

        var samples: [ViralReconSample] = []
        for line in lines.dropFirst() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let fields = parseCSVLine(line)
            guard fields.count > max(sampleIndex, fastq1Index) else {
                throw PairingError.malformedSamplesheet(url, reason: "row '\(line)' has too few columns")
            }
            let fastq1 = fields[fastq1Index].trimmingCharacters(in: .whitespaces)
            guard !fastq1.isEmpty else {
                throw PairingError.malformedSamplesheet(url, reason: "row '\(line)' has no fastq_1")
            }
            var urls = [URL(fileURLWithPath: fastq1).standardizedFileURL]
            if let fastq2Index, fields.count > fastq2Index {
                let fastq2 = fields[fastq2Index].trimmingCharacters(in: .whitespaces)
                if !fastq2.isEmpty {
                    urls.append(URL(fileURLWithPath: fastq2).standardizedFileURL)
                }
            }
            samples.append(ViralReconSample(
                sampleName: fields[sampleIndex].trimmingCharacters(in: .whitespaces),
                sourceBundleURL: urls[0],
                fastqURLs: urls,
                barcode: nil,
                sequencingSummaryURL: nil
            ))
        }
        return samples
    }

    // MARK: Decision records

    public static func writeDecisions(_ decisions: [ViralReconReadPairingDecision], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(decisions).write(to: url, options: .atomic)
    }

    public static func loadDecisions(from url: URL) -> [ViralReconReadPairingDecision]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([ViralReconReadPairingDecision].self, from: data)
    }

    /// One line summarising every decision, for an operation's completion detail.
    public static func summaryLine(for decisions: [ViralReconReadPairingDecision]) -> String? {
        guard !decisions.isEmpty else { return nil }
        return "Read pairing: " + decisions.map(\.summary).joined(separator: "; ")
    }

    // MARK: - Helpers

    static func uniqueDirectoryName(for sampleName: String, usedNames: inout Set<String>) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var base = String(sampleName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        if base.isEmpty || base.allSatisfy({ $0 == "." }) { base = "sample" }
        var candidate = base
        var suffix = 2
        while usedNames.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        usedNames.insert(candidate)
        return candidate
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            if inQuotes {
                if character == "\"" {
                    // A doubled quote inside a quoted field is a literal quote.
                    var lookahead = iterator
                    if lookahead.next() == "\"" {
                        current.append("\"")
                        iterator = lookahead
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}

// MARK: - GzipFileSink

/// A `FileHandle` that feeds `/usr/bin/gzip -c` writing to `destination`.
///
/// The interleaver writes records into `writeHandle`; `finish()` closes the
/// pipe, waits for gzip, and fails if it did. `abort()` tears everything
/// down and removes the partial file.
private final class GzipFileSink {
    let writeHandle: FileHandle
    private let destination: URL
    private let process: Process
    private let stderrPipe: Pipe
    private let outputHandle: FileHandle
    private var finished = false

    init(destination: URL) throws {
        self.destination = destination
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        fm.createFile(atPath: destination.path, contents: nil)
        outputHandle = try FileHandle(forWritingTo: destination)
        let input = Pipe()
        stderrPipe = Pipe()
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c"]
        process.standardInput = input
        process.standardOutput = outputHandle
        process.standardError = stderrPipe
        try process.run()
        writeHandle = input.fileHandleForWriting
    }

    func finish() throws {
        guard !finished else { return }
        finished = true
        try? writeHandle.close()
        process.waitUntilExit()
        try? outputHandle.close()
        guard process.terminationStatus == 0 else {
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            try? FileManager.default.removeItem(at: destination)
            throw FASTQPairInterleaver.InterleaveError.unreadableInput(
                file: destination.lastPathComponent,
                reason: "gzip exited with status \(process.terminationStatus): \(stderr)"
            )
        }
    }

    func abort() {
        guard !finished else { return }
        finished = true
        try? writeHandle.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? outputHandle.close()
        try? FileManager.default.removeItem(at: destination)
    }
}
