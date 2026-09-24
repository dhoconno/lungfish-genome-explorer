import Foundation
import LungfishIO

public struct ONTFluidigmSampleMaterializationRequest: Sendable {
    public let inputURL: URL
    public let barcodeDefinitionsURL: URL
    public let outputDirectory: URL
    public let force: Bool
    /// GEN-01 (2026-09-23 best-practices audit): the CS1 Fluidigm adapter
    /// that precedes the amplicon insert in the sequenced read. Used to
    /// anchor barcode assignment to the short window after rc(reversePrimer)
    /// so the barcode can never match inside the amplicon itself. Defaults
    /// to the same CS1 sequence as `ONTFluidigmAmpliconMaterializer`.
    public let forwardPrimer: String
    /// GEN-01: the CS2 Fluidigm adapter. Its reverse complement appears
    /// immediately before the barcode in the sequenced (CS1-first) read.
    public let reversePrimer: String

    public init(
        inputURL: URL,
        barcodeDefinitionsURL: URL,
        outputDirectory: URL,
        forwardPrimer: String = ONTFluidigmAmpliconMaterializer.defaultForwardPrimer,
        reversePrimer: String = ONTFluidigmAmpliconMaterializer.defaultReversePrimer,
        force: Bool = false
    ) {
        self.inputURL = inputURL.standardizedFileURL
        self.barcodeDefinitionsURL = barcodeDefinitionsURL.standardizedFileURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.forwardPrimer = ONTFluidigmSampleMaterializer.normalizedDNA(forwardPrimer)
        self.reversePrimer = ONTFluidigmSampleMaterializer.normalizedDNA(reversePrimer)
        self.force = force
    }
}

public struct ONTFluidigmSampleMaterializationResult: Sendable {
    public let outputDirectory: URL
    public let manifestURL: URL
    public let outputBundleURLs: [URL]
    public let inputReadCount: Int
    public let assignedReadCount: Int
    public let unassignedReadCount: Int
}

public enum ONTFluidigmSampleMaterializerError: LocalizedError, Sendable, Equatable {
    case missingInput(URL)
    case missingBarcodeDefinitions(URL)
    case outputExists(URL)
    case noBarcodeRows(URL)
    case noInputFASTQs(URL)
    case compressionFailed(URL, Int32)
    /// R3-R3H-6: duplicate of ONTFluidigmAmpliconMaterializerError's
    /// .duplicateBarcodeSequence case for this near-identical sibling
    /// materializer -- see ONTFluidigmBarcodeCollisionValidation.swift.
    case duplicateBarcodeSequence(firstSampleID: String, secondSampleID: String, barcode: String)

    public var errorDescription: String? {
        switch self {
        case .missingInput(let url):
            return "Input FASTQ or .lungfishfastq bundle does not exist: \(url.path)"
        case .missingBarcodeDefinitions(let url):
            return "Barcode definition CSV does not exist: \(url.path)"
        case .outputExists(let url):
            return "Output directory already exists: \(url.path). Use --force to replace it."
        case .noBarcodeRows(let url):
            return "No sample/barcode rows were found in \(url.path). Expected columns: sample,barcode."
        case .noInputFASTQs(let url):
            return "No physical FASTQ payloads could be resolved from \(url.path)."
        case .compressionFailed(let url, let status):
            return "Failed to gzip sample FASTQ \(url.path) (exit \(status))."
        case .duplicateBarcodeSequence(let firstSampleID, let secondSampleID, let barcode):
            return "Barcode sheet assigns the same effective barcode '\(barcode)' to both '\(firstSampleID)' and '\(secondSampleID)'. Every matching read would be silently misattributed to whichever sample loaded first; fix the barcode sheet so each sample has a unique barcode (forward or reverse-complement)."
        }
    }
}

public final class ONTFluidigmSampleMaterializer: Sendable {
    public static let manifestFilename = "ont-fluidigm-samples-manifest.json"

    public init() {}

    public func run(_ request: ONTFluidigmSampleMaterializationRequest) async throws
        -> ONTFluidigmSampleMaterializationResult
    {
        let fm = FileManager.default
        guard fm.fileExists(atPath: request.inputURL.path) else {
            throw ONTFluidigmSampleMaterializerError.missingInput(request.inputURL)
        }
        guard fm.fileExists(atPath: request.barcodeDefinitionsURL.path) else {
            throw ONTFluidigmSampleMaterializerError.missingBarcodeDefinitions(request.barcodeDefinitionsURL)
        }
        if fm.fileExists(atPath: request.outputDirectory.path) {
            guard request.force else {
                throw ONTFluidigmSampleMaterializerError.outputExists(request.outputDirectory)
            }
            try fm.removeItem(at: request.outputDirectory)
        }
        try fm.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)

        let barcodeEntries = try Self.loadBarcodeEntries(from: request.barcodeDefinitionsURL)
        guard !barcodeEntries.isEmpty else {
            throw ONTFluidigmSampleMaterializerError.noBarcodeRows(request.barcodeDefinitionsURL)
        }
        guard let matcher = BarcodeMatcher(entries: barcodeEntries) else {
            throw ONTFluidigmSampleMaterializerError.noBarcodeRows(request.barcodeDefinitionsURL)
        }
        let inputFASTQs = try ONTBarcodeDemuxGenotypingPipeline.resolveInputFASTQURLs(for: request.inputURL)
        guard !inputFASTQs.isEmpty else {
            throw ONTFluidigmSampleMaterializerError.noInputFASTQs(request.inputURL)
        }

        var accumulators = Dictionary(uniqueKeysWithValues: barcodeEntries.map { entry in
            (entry.sampleID, SampleAccumulator(entry: entry))
        })
        var inputReadCount = 0
        var assignedReadCount = 0
        var unassignedReadCount = 0
        let reader = FASTQReader(validateSequence: false)

        for fastqURL in inputFASTQs {
            for try await record in reader.records(from: fastqURL) {
                let weight = CountedFASTQMaterializer.readCountWeight(
                    identifier: record.identifier,
                    description: record.description
                )
                inputReadCount += weight
                guard let sampleID = matcher.assignAnchored(
                    sequence: record.sequence,
                    forwardPrimer: request.forwardPrimer,
                    reversePrimer: request.reversePrimer
                ) else {
                    unassignedReadCount += weight
                    continue
                }
                assignedReadCount += weight
                accumulators[sampleID]?.record(sequence: record.sequence, count: weight)
            }
        }

        let sampleOutputs = try barcodeEntries.compactMap { entry -> SampleOutput? in
            guard let accumulator = accumulators[entry.sampleID],
                  accumulator.readCount > 0 else {
                return nil
            }
            return try Self.writeSampleBundle(
                accumulator: accumulator,
                outputDirectory: request.outputDirectory
            )
        }
        let manifestURL = request.outputDirectory.appendingPathComponent(Self.manifestFilename)
        let sampleTotals = Dictionary<String, Int>(uniqueKeysWithValues: sampleOutputs.map { output in
            (output.sampleID, output.readCount)
        })
        let sampleItems = sampleOutputs.map { output -> [String: Any] in
            [
                "sample": output.sampleID,
                "barcode": output.barcode,
                "bundle": output.bundleURL.lastPathComponent,
                "fastq": output.fastqURL.path,
                "readCount": output.readCount,
                "baseCount": output.baseCount,
            ]
        }
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "toolName": "lungfish fastq ont-fluidigm-samples",
            "input": request.inputURL.path,
            "barcodes": request.barcodeDefinitionsURL.path,
            "outputDirectory": request.outputDirectory.path,
            "inputReadCount": inputReadCount,
            "assignedReadCount": assignedReadCount,
            "unassignedReadCount": unassignedReadCount,
            "payloadRepresentation": "deduplicated gzip-compressed sample FASTQ",
            "duplicateCountEncoding": "size=N",
            "sampleTotals": sampleTotals,
            "samples": sampleItems,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: manifestURL, options: .atomic)

        return ONTFluidigmSampleMaterializationResult(
            outputDirectory: request.outputDirectory,
            manifestURL: manifestURL,
            outputBundleURLs: sampleOutputs.map(\.bundleURL),
            inputReadCount: inputReadCount,
            assignedReadCount: assignedReadCount,
            unassignedReadCount: unassignedReadCount
        )
    }

    public static func normalizedDNA(_ sequence: String) -> String {
        sequence
            .uppercased()
            .replacingOccurrences(of: "U", with: "T")
            .filter { "ACGTN".contains($0) }
    }

    private static func loadBarcodeEntries(from url: URL) throws -> [BarcodeEntry] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let entries = text.components(separatedBy: .newlines)
            .compactMap { line -> BarcodeEntry? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                let columns = splitDelimitedLine(trimmed)
                guard columns.count >= 2 else { return nil }
                let sample = columns[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let barcode = columns[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sample.isEmpty, !barcode.isEmpty else { return nil }
                let normalizedHeader = sample.lowercased().replacingOccurrences(of: " ", with: "_")
                if ["sample", "sample_id", "id", "barcodeid", "barcode_id"].contains(normalizedHeader) {
                    return nil
                }
                return BarcodeEntry(sampleID: sanitizedSampleID(sample), barcode: normalizedDNA(barcode))
            }

        // R3-R3H-6: reject colliding barcode sequences before they reach
        // BarcodeMatcher -- see ONTFluidigmBarcodeCollisionValidation.swift
        // and the identical guard in ONTFluidigmAmpliconMaterializer (R3-R3H-5).
        try ONTFluidigmBarcodeCollisionValidation.validateNoDuplicateBarcodeSequences(
            entries.map {
                .init(sampleID: $0.sampleID, barcode: $0.barcode, reverseComplementBarcode: $0.reverseComplementBarcode)
            }
        ) { firstSampleID, secondSampleID, barcode in
            ONTFluidigmSampleMaterializerError.duplicateBarcodeSequence(
                firstSampleID: firstSampleID,
                secondSampleID: secondSampleID,
                barcode: barcode
            )
        }

        return entries
    }

    private static func splitDelimitedLine(_ line: String) -> [String] {
        if line.contains(",") {
            return line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
        if line.contains("\t") {
            return line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    private static func sanitizedSampleID(_ value: String) -> String {
        let sanitized = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }
        let collapsed = String(sanitized)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        return collapsed.isEmpty ? "sample" : collapsed
    }

    private static func reverseComplement(_ sequence: String) -> String {
        let table: [UInt8: UInt8] = [
            UInt8(ascii: "A"): UInt8(ascii: "T"),
            UInt8(ascii: "C"): UInt8(ascii: "G"),
            UInt8(ascii: "G"): UInt8(ascii: "C"),
            UInt8(ascii: "T"): UInt8(ascii: "A"),
            UInt8(ascii: "N"): UInt8(ascii: "N"),
        ]
        return String(decoding: sequence.utf8.reversed().map { table[$0] ?? UInt8(ascii: "N") }, as: UTF8.self)
    }

    private struct BarcodeEntry: Sendable {
        let sampleID: String
        let barcode: String

        var reverseComplementBarcode: String {
            ONTFluidigmSampleMaterializer.reverseComplement(barcode)
        }
    }

    /// GEN-01 (2026-09-23 best-practices audit): previously a free two-bit
    /// leftmost k-mer scan over the whole read with no CS1/CS2 awareness at
    /// all, so it matched barcode-length substrings inside the amplicon
    /// insert itself. Replaced with `ONTFluidigmAnchoredBarcodeAssigner`,
    /// which only looks in the short window immediately after the CS1/
    /// rc(CS2) anchor and refuses to guess when zero or multiple samples
    /// match there.
    private struct BarcodeMatcher: Sendable {
        private let barcodesBySample: [(sampleID: String, barcode: [UInt8])]

        init?(entries: [BarcodeEntry]) {
            guard !entries.isEmpty else { return nil }
            self.barcodesBySample = entries.map { ($0.sampleID, Array($0.barcode.utf8)) }
        }

        /// Assigns `sequence` (already normalized to uppercase ACGTN) to the
        /// unique sample whose barcode is found in the anchored window.
        /// Tries the as-sequenced orientation first, then the reverse
        /// complement of the whole read.
        func assignAnchored(
            sequence: String,
            forwardPrimer: String,
            reversePrimer: String
        ) -> String? {
            let bases = Array(sequence.utf8)
            let forward = Array(forwardPrimer.utf8)
            let reverse = Array(reversePrimer.utf8)

            if case .success(let assignment) = ONTFluidigmAnchoredBarcodeAssigner.assign(
                bases: bases,
                forwardPrimer: forward,
                reversePrimer: reverse,
                barcodes: barcodesBySample
            ) {
                return assignment.sampleID
            }

            let rc = ONTFluidigmAnchoredBarcodeAssigner.reverseComplementBytes(bases)
            if case .success(let assignment) = ONTFluidigmAnchoredBarcodeAssigner.assign(
                bases: rc,
                forwardPrimer: forward,
                reversePrimer: reverse,
                barcodes: barcodesBySample
            ) {
                return assignment.sampleID
            }
            return nil
        }
    }

    private struct SampleAccumulator {
        let entry: BarcodeEntry
        private(set) var sequenceCounts: [String: Int] = [:]
        private(set) var readCount = 0
        private(set) var baseCount = 0

        init(entry: BarcodeEntry) {
            self.entry = entry
        }

        mutating func record(sequence: String, count: Int) {
            guard count > 0 else { return }
            let normalized = CountedFASTQMaterializer.normalized(sequence, normalization: .uppercase)
            sequenceCounts[normalized, default: 0] += count
            readCount += count
            baseCount += normalized.count * count
        }
    }

    private static func writeSampleBundle(
        accumulator: SampleAccumulator,
        outputDirectory: URL
    ) throws -> SampleOutput {
        let bundleURL = outputDirectory.appendingPathComponent(
            "\(accumulator.entry.sampleID).lungfishfastq",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let countedResult = try CountedFASTQMaterializer().write(
            counts: accumulator.sequenceCounts,
            outputURL: bundleURL.appendingPathComponent("deduplicated-sample-reads.fastq.gz"),
            compress: true,
            inputRecordCount: accumulator.sequenceCounts.count,
            totalReadCount: accumulator.readCount
        )
        let fastqURL = countedResult.outputURL
        let checksum = try PayloadChecksum.sha256Hex(fileAt: fastqURL)
        let operation = FASTQDerivativeOperation(
            kind: .demultiplex,
            barcodeID: accumulator.entry.sampleID,
            sampleName: accumulator.entry.sampleID,
            toolUsed: "lungfish",
            toolVersion: WorkflowRun.currentAppVersion,
            toolCommand: "lungfish fastq ont-fluidigm-samples"
        )
        let manifest = FASTQDerivedBundleManifest(
            name: accumulator.entry.sampleID,
            parentBundleRelativePath: ".",
            rootBundleRelativePath: ".",
            rootFASTQFilename: fastqURL.lastPathComponent,
            payload: .full(fastqFilename: fastqURL.lastPathComponent),
            lineage: [operation],
            operation: operation,
            cachedStatistics: countedSampleStatistics(for: accumulator.sequenceCounts),
            pairingMode: nil,
            sequenceFormat: .fastq,
            provenance: SampleProvenance(
                sampleID: accumulator.entry.sampleID,
                libraryPrep: "Fluidigm Access Array",
                notes: "Materialized gzip-compressed per-sample read exemplars after exact Fluidigm barcode assignment; duplicate counts encoded as size=N."
            ),
            payloadChecksums: PayloadChecksum(checksums: [fastqURL.lastPathComponent: checksum]),
            materializationState: .materialized(checksum: checksum)
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)

        return SampleOutput(
            sampleID: accumulator.entry.sampleID,
            barcode: accumulator.entry.barcode,
            bundleURL: bundleURL.standardizedFileURL,
            fastqURL: fastqURL.standardizedFileURL,
            readCount: accumulator.readCount,
            baseCount: accumulator.baseCount
        )
    }

    private static func countedSampleStatistics(for sequenceCounts: [String: Int]) -> FASTQDatasetStatistics {
        var readCount = 0
        var baseCount: Int64 = 0
        var gcCount: Int64 = 0
        var minReadLength = Int.max
        var maxReadLength = 0
        var readLengthHistogram: [Int: Int] = [:]

        for (sequence, count) in sequenceCounts where count > 0 {
            let length = sequence.count
            readCount += count
            baseCount += Int64(length * count)
            minReadLength = min(minReadLength, length)
            maxReadLength = max(maxReadLength, length)
            readLengthHistogram[length, default: 0] += count
            for byte in sequence.utf8 {
                let upper = byte & 0xDF
                if upper == UInt8(ascii: "G") || upper == UInt8(ascii: "C") {
                    gcCount += Int64(count)
                }
            }
        }

        guard readCount > 0 else {
            return .empty
        }

        let trackedPositions = min(maxReadLength, 1_000)
        let perPositionQuality = (0..<trackedPositions).map { position in
            PositionQualitySummary(
                position: position,
                mean: 40,
                median: 40,
                lowerQuartile: 40,
                upperQuartile: 40,
                percentile10: 40,
                percentile90: 40
            )
        }

        return FASTQDatasetStatistics(
            readCount: readCount,
            baseCount: baseCount,
            meanReadLength: Double(baseCount) / Double(readCount),
            minReadLength: minReadLength == Int.max ? 0 : minReadLength,
            maxReadLength: maxReadLength,
            medianReadLength: medianReadLength(from: readLengthHistogram, readCount: readCount),
            n50ReadLength: n50ReadLength(from: readLengthHistogram, baseCount: baseCount),
            meanQuality: 40,
            q20Percentage: 100,
            q30Percentage: 100,
            gcContent: baseCount > 0 ? Double(gcCount) / Double(baseCount) : 0,
            readLengthHistogram: readLengthHistogram,
            qualityScoreHistogram: [40: Int(clamping: baseCount)],
            perPositionQuality: perPositionQuality
        )
    }

    private static func medianReadLength(from histogram: [Int: Int], readCount: Int) -> Int {
        let target = (readCount + 1) / 2
        var cumulative = 0
        for length in histogram.keys.sorted() {
            cumulative += histogram[length] ?? 0
            if cumulative >= target {
                return length
            }
        }
        return 0
    }

    private static func n50ReadLength(from histogram: [Int: Int], baseCount: Int64) -> Int {
        SequenceLengthStatistics.nx(histogram: histogram, totalBases: baseCount)
    }

    private struct SampleOutput: Sendable {
        let sampleID: String
        let barcode: String
        let bundleURL: URL
        let fastqURL: URL
        let readCount: Int
        let baseCount: Int
    }
}
