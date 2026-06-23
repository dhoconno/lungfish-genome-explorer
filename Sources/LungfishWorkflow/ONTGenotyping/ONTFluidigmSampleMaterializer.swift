import Foundation
import LungfishIO

public struct ONTFluidigmSampleMaterializationRequest: Sendable {
    public let inputURL: URL
    public let barcodeDefinitionsURL: URL
    public let outputDirectory: URL
    public let force: Bool

    public init(
        inputURL: URL,
        barcodeDefinitionsURL: URL,
        outputDirectory: URL,
        force: Bool = false
    ) {
        self.inputURL = inputURL.standardizedFileURL
        self.barcodeDefinitionsURL = barcodeDefinitionsURL.standardizedFileURL
        self.outputDirectory = outputDirectory.standardizedFileURL
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

public enum ONTFluidigmSampleMaterializerError: LocalizedError, Sendable {
    case missingInput(URL)
    case missingBarcodeDefinitions(URL)
    case outputExists(URL)
    case noBarcodeRows(URL)
    case noInputFASTQs(URL)
    case compressionFailed(URL, Int32)

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
                guard let entry = matcher.assign(sequence: record.sequence) else {
                    unassignedReadCount += weight
                    continue
                }
                assignedReadCount += weight
                accumulators[entry.sampleID]?.record(sequence: record.sequence, count: weight)
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
        return text.components(separatedBy: .newlines)
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

    private struct BarcodeMatcher: Sendable {
        private struct Candidate: Sendable {
            let entry: BarcodeEntry
        }

        private let mapsByLength: [Int: [UInt64: [Candidate]]]
        private let lengths: [Int]

        init?(entries: [BarcodeEntry]) {
            var mapsByLength: [Int: [UInt64: [Candidate]]] = [:]
            for entry in entries {
                for barcode in [entry.barcode, entry.reverseComplementBarcode] where !barcode.isEmpty {
                    guard let code = Self.twoBitCode(barcode) else { return nil }
                    mapsByLength[barcode.utf8.count, default: [:]][code, default: []]
                        .append(Candidate(entry: entry))
                }
            }
            guard !mapsByLength.isEmpty else { return nil }
            self.mapsByLength = mapsByLength
            self.lengths = mapsByLength.keys.sorted()
        }

        func assign(sequence: String) -> BarcodeEntry? {
            let bytes = Array(sequence.utf8)
            var bestStart: Int?
            var bestEntry: BarcodeEntry?
            for length in lengths {
                guard length <= bytes.count,
                      let map = mapsByLength[length],
                      let match = findFirst(in: bytes, length: length, map: map) else {
                    continue
                }
                if bestStart == nil || match.start < bestStart! {
                    bestStart = match.start
                    bestEntry = match.entry
                }
            }
            return bestEntry
        }

        private func findFirst(
            in bytes: [UInt8],
            length: Int,
            map: [UInt64: [Candidate]]
        ) -> (start: Int, entry: BarcodeEntry)? {
            guard length > 0, length <= 31 else { return nil }
            var code: UInt64 = 0
            var validBases = 0
            let mask = length == 31 ? UInt64.max >> 2 : (UInt64(1) << UInt64(length * 2)) - 1

            for (index, byte) in bytes.enumerated() {
                guard let bits = Self.baseBits(byte) else {
                    code = 0
                    validBases = 0
                    continue
                }
                code = ((code << 2) | UInt64(bits)) & mask
                validBases += 1
                guard validBases >= length else { continue }

                let start = index - length + 1
                guard let candidate = map[code]?.first else { continue }
                return (start, candidate.entry)
            }
            return nil
        }

        private static func twoBitCode(_ sequence: String) -> UInt64? {
            guard !sequence.isEmpty, sequence.utf8.count <= 31 else { return nil }
            var code: UInt64 = 0
            for byte in sequence.utf8 {
                guard let bits = baseBits(byte) else { return nil }
                code = (code << 2) | UInt64(bits)
            }
            return code
        }

        private static func baseBits(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "A"), UInt8(ascii: "a"): return 0
            case UInt8(ascii: "C"), UInt8(ascii: "c"): return 1
            case UInt8(ascii: "G"), UInt8(ascii: "g"): return 2
            case UInt8(ascii: "T"), UInt8(ascii: "t"): return 3
            default: return nil
            }
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
        guard baseCount > 0 else { return 0 }
        let target = baseCount / 2
        var cumulative: Int64 = 0
        for length in histogram.keys.sorted(by: >) {
            cumulative += Int64(length) * Int64(histogram[length] ?? 0)
            if cumulative >= target {
                return length
            }
        }
        return 0
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
