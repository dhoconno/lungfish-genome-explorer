import Foundation
import LungfishIO

public struct ONTFluidigmAmpliconMaterializationRequest: Sendable {
    public let inputURL: URL
    public let barcodeDefinitionsURL: URL
    public let outputDirectory: URL
    public let forwardPrimer: String
    public let reversePrimer: String
    public let primerMismatches: Int
    public let minimumInsertLength: Int
    public let canonicalizeReverseComplements: Bool
    public let force: Bool

    public init(
        inputURL: URL,
        barcodeDefinitionsURL: URL,
        outputDirectory: URL,
        forwardPrimer: String = ONTFluidigmAmpliconMaterializer.defaultForwardPrimer,
        reversePrimer: String = ONTFluidigmAmpliconMaterializer.defaultReversePrimer,
        primerMismatches: Int = 2,
        minimumInsertLength: Int = 20,
        canonicalizeReverseComplements: Bool = true,
        force: Bool = false
    ) {
        self.inputURL = inputURL.standardizedFileURL
        self.barcodeDefinitionsURL = barcodeDefinitionsURL.standardizedFileURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.forwardPrimer = ONTFluidigmAmpliconMaterializer.normalizedDNA(forwardPrimer)
        self.reversePrimer = ONTFluidigmAmpliconMaterializer.normalizedDNA(reversePrimer)
        self.primerMismatches = max(0, primerMismatches)
        self.minimumInsertLength = max(1, minimumInsertLength)
        self.canonicalizeReverseComplements = canonicalizeReverseComplements
        self.force = force
    }
}

public struct ONTFluidigmAmpliconMaterializationResult: Sendable {
    public let outputDirectory: URL
    public let manifestURL: URL
    public let outputBundleURLs: [URL]
    public let inputReadCount: Int
    public let assignedReadCount: Int
    public let extractedReadCount: Int
    public let uniqueSequenceCount: Int
    public let unassignedReadCount: Int
    public let unextractedReadCount: Int
}

public enum ONTFluidigmAmpliconMaterializerError: LocalizedError, Sendable, Equatable {
    case missingInput(URL)
    case missingBarcodeDefinitions(URL)
    case outputExists(URL)
    case noBarcodeRows(URL)
    case noInputFASTQs(URL)
    case compressionFailed(URL, Int32)
    /// R3-R3H-5: two barcode-sheet rows resolve to the same effective
    /// barcode sequence (identical strings, or one row's forward barcode
    /// equal to another's reverse-complement). BarcodeMatcher.findFirst()
    /// would otherwise silently resolve this collision to whichever sample
    /// happened to load first.
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
            return "Failed to gzip counted amplicon FASTQ \(url.path) (exit \(status))."
        case .duplicateBarcodeSequence(let firstSampleID, let secondSampleID, let barcode):
            return "Barcode sheet assigns the same effective barcode '\(barcode)' to both '\(firstSampleID)' and '\(secondSampleID)'. Every matching read would be silently misattributed to whichever sample loaded first; fix the barcode sheet so each sample has a unique barcode (forward or reverse-complement)."
        }
    }
}

public final class ONTFluidigmAmpliconMaterializer: Sendable {
    public static let defaultForwardPrimer = "ACACTGACGACATGGTTCTACA"
    public static let defaultReversePrimer = "TACGGTAGCAGAGACTTGGTCT"
    public static let manifestFilename = "ont-fluidigm-counted-samples-manifest.json"

    public init() {}

    public func run(
        _ request: ONTFluidigmAmpliconMaterializationRequest,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws
        -> ONTFluidigmAmpliconMaterializationResult
    {
        let fm = FileManager.default
        progress?(0.02, "Preparing ONT Fluidigm sample split.")
        guard fm.fileExists(atPath: request.inputURL.path) else {
            throw ONTFluidigmAmpliconMaterializerError.missingInput(request.inputURL)
        }
        guard fm.fileExists(atPath: request.barcodeDefinitionsURL.path) else {
            throw ONTFluidigmAmpliconMaterializerError.missingBarcodeDefinitions(request.barcodeDefinitionsURL)
        }
        if fm.fileExists(atPath: request.outputDirectory.path) {
            guard request.force else {
                throw ONTFluidigmAmpliconMaterializerError.outputExists(request.outputDirectory)
            }
            try fm.removeItem(at: request.outputDirectory)
        }
        try fm.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)

        let barcodeEntries = try Self.loadBarcodeEntries(from: request.barcodeDefinitionsURL)
        guard !barcodeEntries.isEmpty else {
            throw ONTFluidigmAmpliconMaterializerError.noBarcodeRows(request.barcodeDefinitionsURL)
        }
        let inputFASTQs = try ONTBarcodeDemuxGenotypingPipeline.resolveInputFASTQURLs(for: request.inputURL)
        guard !inputFASTQs.isEmpty else {
            throw ONTFluidigmAmpliconMaterializerError.noInputFASTQs(request.inputURL)
        }
        progress?(
            0.08,
            "Found \(inputFASTQs.count) ONT FASTQ chunk\(inputFASTQs.count == 1 ? "" : "s")."
        )
        guard let barcodeMatcher = BarcodeMatcher(entries: barcodeEntries) else {
            throw ONTFluidigmAmpliconMaterializerError.noBarcodeRows(request.barcodeDefinitionsURL)
        }
        var accumulators = Dictionary(uniqueKeysWithValues: barcodeEntries.map { entry in
            (entry.sampleID, SampleAccumulator(entry: entry))
        })
        var inputReadCount = 0
        var assignedReadCount = 0
        var extractedReadCount = 0
        var unassignedReadCount = 0
        var unextractedReadCount = 0
        let reader = FASTQReader(validateSequence: false)
        let extractor = InsertExtractor(
            forwardPrimer: request.forwardPrimer,
            reversePrimer: request.reversePrimer,
            maxMismatches: request.primerMismatches,
            minimumInsertLength: request.minimumInsertLength,
            canonicalizeReverseComplements: request.canonicalizeReverseComplements
        )

        for (chunkIndex, fastqURL) in inputFASTQs.enumerated() {
            let chunkNumber = chunkIndex + 1
            let chunkStartProgress = 0.10 + (0.70 * Double(chunkIndex) / Double(inputFASTQs.count))
            let chunkEndProgress = 0.10 + (0.70 * Double(chunkNumber) / Double(inputFASTQs.count))
            progress?(
                chunkStartProgress,
                "Scanning chunk \(chunkNumber)/\(inputFASTQs.count): \(fastqURL.lastPathComponent)"
            )
            var chunkReadCount = 0
            for try await record in reader.records(from: fastqURL) {
                inputReadCount += 1
                chunkReadCount += 1
                if chunkReadCount.isMultiple(of: 10_000) {
                    progress?(
                        min(chunkEndProgress - 0.001, chunkStartProgress + 0.01),
                        "Scanning chunk \(chunkNumber)/\(inputFASTQs.count): \(chunkReadCount) reads..."
                    )
                }
                let bases = Self.normalizedDNABases(record.sequence)
                let primerExclusionRanges = Self.primerExclusionRanges(
                    in: bases,
                    forwardPrimer: request.forwardPrimer,
                    reversePrimer: request.reversePrimer,
                    maxMismatches: request.primerMismatches
                )
                guard let entry = barcodeMatcher.assign(
                    bases: bases,
                    excluding: primerExclusionRanges
                ) else {
                    unassignedReadCount += 1
                    continue
                }
                assignedReadCount += 1
                accumulators[entry.sampleID]?.recordAssignedRead()
                guard let sequence = extractor.extract(from: bases) else {
                    unextractedReadCount += 1
                    continue
                }
                extractedReadCount += 1
                accumulators[entry.sampleID]?.recordExtracted(sequence: sequence)
            }
            progress?(
                chunkEndProgress,
                "Scanned chunk \(chunkNumber)/\(inputFASTQs.count): \(chunkReadCount) reads."
            )
        }

        let nonEmptySampleCount = accumulators.values.filter { $0.uniqueSequenceCount > 0 }.count
        progress?(
            0.84,
            "Writing \(nonEmptySampleCount) sample bundle\(nonEmptySampleCount == 1 ? "" : "s")."
        )
        let sampleOutputs: [SampleOutput] = try barcodeEntries.compactMap { entry -> SampleOutput? in
            guard let accumulator = accumulators[entry.sampleID],
                  accumulator.uniqueSequenceCount > 0 else {
                return nil
            }
            return try writeSampleBundle(
                accumulator: accumulator,
                request: request,
                inputURL: request.inputURL
            )
        }

        progress?(0.92, "Writing ONT Fluidigm sample manifest.")
        let manifestURL = request.outputDirectory.appendingPathComponent(Self.manifestFilename)
        let sampleTotals = Dictionary<String, Int>(uniqueKeysWithValues: sampleOutputs.map { output in
            (output.sampleID, output.rawReadCount)
        })
        let sampleItems = sampleOutputs.map { output -> [String: Any] in
            [
                "sample": output.sampleID,
                "barcode": output.barcode,
                "bundle": output.bundleURL.lastPathComponent,
                "fastq": output.fastqURL.path,
                "readCount": output.rawReadCount,
                "extractedReadCount": output.extractedReadCount,
                "uniqueSequenceCount": output.uniqueSequenceCount,
                "baseCount": output.uniqueBaseCount,
                "weightedBaseCount": output.weightedBaseCount,
            ]
        }
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "toolName": "lungfish fastq ont-fluidigm-samples",
            "input": request.inputURL.path,
            "barcodes": request.barcodeDefinitionsURL.path,
            "outputDirectory": request.outputDirectory.path,
            "forwardPrimer": request.forwardPrimer,
            "reversePrimer": request.reversePrimer,
            "primerMismatches": request.primerMismatches,
            "minimumInsertLength": request.minimumInsertLength,
            "canonicalizeReverseComplements": request.canonicalizeReverseComplements,
            "payloadRepresentation": "deduplicated gzip-compressed CS1-CS2 insert FASTQ",
            "duplicateCountEncoding": "size=N",
            "inputReadCount": inputReadCount,
            "assignedReadCount": assignedReadCount,
            "unassignedReadCount": unassignedReadCount,
            "extractedReadCount": extractedReadCount,
            "unextractedReadCount": unextractedReadCount,
            "uniqueSequenceCount": sampleOutputs.reduce(0) { $0 + $1.uniqueSequenceCount },
            "sampleTotals": sampleTotals,
            "samples": sampleItems,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: manifestURL, options: .atomic)
        progress?(1.0, "ONT Fluidigm sample split complete.")

        return ONTFluidigmAmpliconMaterializationResult(
            outputDirectory: request.outputDirectory,
            manifestURL: manifestURL,
            outputBundleURLs: sampleOutputs.map(\.bundleURL),
            inputReadCount: inputReadCount,
            assignedReadCount: assignedReadCount,
            extractedReadCount: extractedReadCount,
            uniqueSequenceCount: sampleOutputs.reduce(0) { $0 + $1.uniqueSequenceCount },
            unassignedReadCount: unassignedReadCount,
            unextractedReadCount: unextractedReadCount
        )
    }

    public static func normalizedDNA(_ sequence: String) -> String {
        String(decoding: normalizedDNABases(sequence), as: UTF8.self)
    }

    private static func normalizedDNABases(_ sequence: String) -> [UInt8] {
        sequence.utf8.map { byte in
            switch byte {
            case UInt8(ascii: "A"), UInt8(ascii: "a"):
                return UInt8(ascii: "A")
            case UInt8(ascii: "C"), UInt8(ascii: "c"):
                return UInt8(ascii: "C")
            case UInt8(ascii: "G"), UInt8(ascii: "g"):
                return UInt8(ascii: "G")
            case UInt8(ascii: "T"), UInt8(ascii: "t"), UInt8(ascii: "U"), UInt8(ascii: "u"):
                return UInt8(ascii: "T")
            case UInt8(ascii: "N"), UInt8(ascii: "n"):
                return UInt8(ascii: "N")
            default:
                return UInt8(ascii: "N")
            }
        }
    }

    private static func loadBarcodeEntries(from url: URL) throws -> [BarcodeEntry] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let entries = text.components(separatedBy: .newlines)
            .compactMap { line -> BarcodeEntry? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                let columns = splitDelimitedLine(trimmed)
                guard columns.count >= 2 else { return nil }
                let first = Self.stripUTF8BOM(
                    columns[0].trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let second = columns[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !first.isEmpty, !second.isEmpty else { return nil }
                let normalizedHeader = first.lowercased().replacingOccurrences(of: " ", with: "_")
                if ["sample", "sample_id", "id", "barcodeid", "barcode_id"].contains(normalizedHeader) {
                    return nil
                }
                return BarcodeEntry(
                    sampleID: sanitizedSampleID(first),
                    barcode: normalizedDNA(second)
                )
            }

        // R3-R3H-5: reject colliding barcode sequences before they reach
        // BarcodeMatcher, which would otherwise silently resolve the
        // collision to whichever sample happened to load first.
        try ONTFluidigmBarcodeCollisionValidation.validateNoDuplicateBarcodeSequences(
            entries.map {
                .init(sampleID: $0.sampleID, barcode: $0.barcode, reverseComplementBarcode: $0.reverseComplementBarcode)
            }
        ) { firstSampleID, secondSampleID, barcode in
            ONTFluidigmAmpliconMaterializerError.duplicateBarcodeSequence(
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

    private static func stripUTF8BOM(_ value: String) -> String {
        value.hasPrefix("\u{feff}") ? String(value.dropFirst()) : value
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

    private struct InsertExtractor: Sendable {
        let forwardLeftPrimer: [UInt8]
        let forwardRightPrimer: [UInt8]
        let reverseLeftPrimer: [UInt8]
        let reverseRightPrimer: [UInt8]
        let maxMismatches: Int
        let minimumInsertLength: Int
        let canonicalizeReverseComplements: Bool

        init(
            forwardPrimer: String,
            reversePrimer: String,
            maxMismatches: Int,
            minimumInsertLength: Int,
            canonicalizeReverseComplements: Bool
        ) {
            self.forwardLeftPrimer = Array(forwardPrimer.utf8)
            self.forwardRightPrimer = reverseComplementBytes(Array(reversePrimer.utf8))
            self.reverseLeftPrimer = Array(reversePrimer.utf8)
            self.reverseRightPrimer = reverseComplementBytes(Array(forwardPrimer.utf8))
            self.maxMismatches = maxMismatches
            self.minimumInsertLength = minimumInsertLength
            self.canonicalizeReverseComplements = canonicalizeReverseComplements
        }

        func extract(from bases: [UInt8]) -> String? {
            if let insert = extractForwardInsert(
                from: bases,
                leftPrimer: forwardLeftPrimer,
                rightPrimer: forwardRightPrimer,
                maxMismatches: maxMismatches,
                minimumInsertLength: minimumInsertLength
            ) {
                return ONTFluidigmAmpliconMaterializer.canonicalized(
                    insert,
                    enabled: canonicalizeReverseComplements
                )
            }

            if let reverseInsert = extractForwardInsert(
                from: bases,
                leftPrimer: reverseLeftPrimer,
                rightPrimer: reverseRightPrimer,
                maxMismatches: maxMismatches,
                minimumInsertLength: minimumInsertLength
            ) {
                return ONTFluidigmAmpliconMaterializer.canonicalized(
                    ONTFluidigmAmpliconMaterializer.reverseComplementBytes(reverseInsert),
                    enabled: canonicalizeReverseComplements
                )
            }
            return nil
        }
    }

    private static func extractForwardInsert(
        from bases: [UInt8],
        leftPrimer: [UInt8],
        rightPrimer: [UInt8],
        maxMismatches: Int,
        minimumInsertLength: Int
    ) -> [UInt8]? {
        if let exact = exactForwardInsert(
            from: bases,
            leftPrimer: leftPrimer,
            rightPrimer: rightPrimer,
            minimumInsertLength: minimumInsertLength
        ) {
            return exact
        }
        guard maxMismatches > 0 else { return nil }
        guard let leftStart = firstApproximateMatch(
            pattern: leftPrimer,
            in: bases,
            startAt: 0,
            maxMismatches: maxMismatches
        ) else {
            return nil
        }
        let insertStart = leftStart + leftPrimer.count
        guard let rightStart = firstApproximateMatch(
            pattern: rightPrimer,
            in: bases,
            startAt: insertStart + minimumInsertLength,
            maxMismatches: maxMismatches
        ) else {
            return nil
        }
        guard rightStart >= insertStart + minimumInsertLength else { return nil }
        return Array(bases[insertStart..<rightStart])
    }

    private static func exactForwardInsert(
        from bases: [UInt8],
        leftPrimer: [UInt8],
        rightPrimer: [UInt8],
        minimumInsertLength: Int
    ) -> [UInt8]? {
        guard let leftStart = firstExactMatch(pattern: leftPrimer, in: bases, startAt: 0) else {
            return nil
        }
        let insertStart = leftStart + leftPrimer.count
        guard let rightStart = firstExactMatch(
            pattern: rightPrimer,
            in: bases,
            startAt: insertStart + minimumInsertLength
        ) else {
            return nil
        }
        return Array(bases[insertStart..<rightStart])
    }

    private static func firstExactMatch(
        pattern: [UInt8],
        in bases: [UInt8],
        startAt: Int
    ) -> Int? {
        let patternCount = pattern.count
        guard patternCount > 0, bases.count >= patternCount else { return nil }
        var offset = max(0, startAt)
        let lastOffset = bases.count - patternCount
        guard offset <= lastOffset else { return nil }
        let first = pattern[0]

        while offset <= lastOffset {
            if bases[offset] == first {
                var index = 1
                while index < patternCount, bases[offset + index] == pattern[index] {
                    index += 1
                }
                if index == patternCount {
                    return offset
                }
            }
            offset += 1
        }
        return nil
    }

    private static func firstApproximateMatch(
        pattern: [UInt8],
        in bases: [UInt8],
        startAt: Int,
        maxMismatches: Int
    ) -> Int? {
        let patternCount = pattern.count
        guard patternCount > 0, bases.count >= patternCount else { return nil }
        var offset = max(0, startAt)
        let lastOffset = bases.count - patternCount
        guard offset <= lastOffset else { return nil }

        while offset <= lastOffset {
            var mismatches = 0
            var index = 0
            while index < patternCount {
                if bases[offset + index] != pattern[index] {
                    mismatches += 1
                    if mismatches > maxMismatches {
                        break
                    }
                }
                index += 1
            }
            if mismatches <= maxMismatches {
                return offset
            }
            offset += 1
        }
        return nil
    }

    private static func canonicalized(_ sequence: [UInt8], enabled: Bool) -> String {
        guard enabled else { return String(decoding: sequence, as: UTF8.self) }
        let rc = reverseComplementBytes(sequence)
        return String(decoding: rc.lexicographicallyPrecedes(sequence) ? rc : sequence, as: UTF8.self)
    }

    private static func primerExclusionRanges(
        in bases: [UInt8],
        forwardPrimer: String,
        reversePrimer: String,
        maxMismatches: Int
    ) -> [Range<Int>] {
        let forward = Array(forwardPrimer.utf8)
        let reverse = Array(reversePrimer.utf8)
        let primers = [
            forward,
            reverseComplementBytes(reverse),
            reverse,
            reverseComplementBytes(forward),
        ]
        let ranges = primers.flatMap { primer in
            matchingRanges(pattern: primer, in: bases, maxMismatches: maxMismatches)
        }
        return mergedRanges(ranges)
    }

    private static func matchingRanges(
        pattern: [UInt8],
        in bases: [UInt8],
        maxMismatches: Int
    ) -> [Range<Int>] {
        let patternCount = pattern.count
        guard patternCount > 0, bases.count >= patternCount else { return [] }
        let lastOffset = bases.count - patternCount
        var ranges: [Range<Int>] = []

        var offset = 0
        while offset <= lastOffset {
            var mismatches = 0
            var index = 0
            while index < patternCount {
                if bases[offset + index] != pattern[index] {
                    mismatches += 1
                    if mismatches > maxMismatches {
                        break
                    }
                }
                index += 1
            }
            if mismatches <= maxMismatches {
                ranges.append(offset..<(offset + patternCount))
            }
            offset += 1
        }
        return ranges
    }

    private static func mergedRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        guard let first = ranges.sorted(by: { lhs, rhs in
            lhs.lowerBound == rhs.lowerBound
                ? lhs.upperBound < rhs.upperBound
                : lhs.lowerBound < rhs.lowerBound
        }).first else {
            return []
        }

        var merged: [Range<Int>] = []
        var currentLower = first.lowerBound
        var currentUpper = first.upperBound
        for range in ranges.sorted(by: { lhs, rhs in
            lhs.lowerBound == rhs.lowerBound
                ? lhs.upperBound < rhs.upperBound
                : lhs.lowerBound < rhs.lowerBound
        }).dropFirst() {
            if range.lowerBound <= currentUpper {
                currentUpper = max(currentUpper, range.upperBound)
            } else {
                merged.append(currentLower..<currentUpper)
                currentLower = range.lowerBound
                currentUpper = range.upperBound
            }
        }
        merged.append(currentLower..<currentUpper)
        return merged
    }

    private static func reverseComplement(_ sequence: String) -> String {
        String(decoding: reverseComplementBytes(Array(sequence.utf8)), as: UTF8.self)
    }

    private static func reverseComplementBytes(_ sequence: [UInt8]) -> [UInt8] {
        let table: [UInt8: UInt8] = [
            UInt8(ascii: "A"): UInt8(ascii: "T"),
            UInt8(ascii: "a"): UInt8(ascii: "T"),
            UInt8(ascii: "C"): UInt8(ascii: "G"),
            UInt8(ascii: "c"): UInt8(ascii: "G"),
            UInt8(ascii: "G"): UInt8(ascii: "C"),
            UInt8(ascii: "g"): UInt8(ascii: "C"),
            UInt8(ascii: "T"): UInt8(ascii: "A"),
            UInt8(ascii: "t"): UInt8(ascii: "A"),
            UInt8(ascii: "U"): UInt8(ascii: "A"),
            UInt8(ascii: "u"): UInt8(ascii: "A"),
            UInt8(ascii: "N"): UInt8(ascii: "N"),
            UInt8(ascii: "n"): UInt8(ascii: "N"),
        ]
        return sequence.reversed().map { table[$0] ?? UInt8(ascii: "N") }
    }

    private func writeSampleBundle(
        accumulator: SampleAccumulator,
        request: ONTFluidigmAmpliconMaterializationRequest,
        inputURL: URL
    ) throws -> SampleOutput {
        let bundleURL = request.outputDirectory
            .appendingPathComponent("\(accumulator.entry.sampleID).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let rawFASTQFilename = "deduplicated-sample-reads.fastq"
        let rawFASTQURL = bundleURL.appendingPathComponent(rawFASTQFilename)
        let countedResult = try CountedFASTQMaterializer().write(
            counts: accumulator.sequenceCounts,
            outputURL: rawFASTQURL.appendingPathExtension("gz"),
            compress: true,
            inputRecordCount: accumulator.extractedReadCount,
            totalReadCount: accumulator.extractedReadCount
        )
        let fastqURL = countedResult.outputURL
        let fastqFilename = fastqURL.lastPathComponent
        let checksum = try PayloadChecksum.sha256Hex(fileAt: fastqURL)
        let operation = FASTQDerivativeOperation(
            kind: .demultiplex,
            primerForwardSequence: request.forwardPrimer,
            primerReverseSequence: request.reversePrimer,
            primerErrorRate: request.primerMismatches == 0
                ? 0
                : Double(request.primerMismatches) / Double(max(request.forwardPrimer.count, request.reversePrimer.count)),
            primerSearchReverseComplement: true,
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
            rootFASTQFilename: fastqFilename,
            payload: .full(fastqFilename: fastqFilename),
            lineage: [operation],
            operation: operation,
            cachedStatistics: Self.countedInsertStatistics(for: accumulator.sequenceCounts),
            pairingMode: nil,
            sequenceFormat: .fastq,
            provenance: SampleProvenance(
                sampleID: accumulator.entry.sampleID,
                libraryPrep: "Fluidigm Access Array MHC amplicon",
                notes: "Materialized gzip-compressed CS1-CS2 insert exemplars after exact Fluidigm barcode assignment; duplicate counts encoded as size=N."
            ),
            payloadChecksums: PayloadChecksum(checksums: [fastqFilename: checksum]),
            materializationState: .materialized(checksum: checksum)
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)

        return SampleOutput(
            sampleID: accumulator.entry.sampleID,
            barcode: accumulator.entry.barcode,
            bundleURL: bundleURL.standardizedFileURL,
            fastqURL: fastqURL.standardizedFileURL,
            rawReadCount: accumulator.rawReadCount,
            extractedReadCount: accumulator.extractedReadCount,
            uniqueSequenceCount: accumulator.uniqueSequenceCount,
            uniqueBaseCount: countedResult.uniqueBaseCount,
            weightedBaseCount: countedResult.weightedBaseCount
        )
    }

    private static func countedInsertStatistics(for sequenceCounts: [String: Int]) -> FASTQDatasetStatistics {
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

    private struct BarcodeEntry: Sendable {
        let sampleID: String
        let barcode: String

        var reverseComplementBarcode: String {
            ONTFluidigmAmpliconMaterializer.reverseComplement(barcode)
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

        func assign(bases bytes: [UInt8], excluding excludedRanges: [Range<Int>] = []) -> BarcodeEntry? {
            var bestStart: Int?
            var bestEntry: BarcodeEntry?
            for length in lengths {
                guard length <= bytes.count,
                      let map = mapsByLength[length],
                      let match = findFirst(
                        in: bytes,
                        length: length,
                        map: map,
                        excluding: excludedRanges
                      ) else {
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
            map: [UInt64: [Candidate]],
            excluding excludedRanges: [Range<Int>]
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
                guard !Self.overlapsExcludedRange(
                    start: start,
                    length: length,
                    excludedRanges: excludedRanges
                ) else {
                    continue
                }
                return (start, candidate.entry)
            }
            return nil
        }

        private static func overlapsExcludedRange(
            start: Int,
            length: Int,
            excludedRanges: [Range<Int>]
        ) -> Bool {
            let end = start + length
            return excludedRanges.contains { range in
                start < range.upperBound && end > range.lowerBound
            }
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

    private struct SampleAccumulator: Sendable {
        let entry: BarcodeEntry
        private(set) var rawReadCount: Int = 0
        private(set) var extractedReadCount: Int = 0
        private(set) var sequenceCounts: [String: Int] = [:]

        init(entry: BarcodeEntry) {
            self.entry = entry
        }

        var uniqueSequenceCount: Int { sequenceCounts.count }

        mutating func recordAssignedRead() {
            rawReadCount += 1
        }

        mutating func recordExtracted(sequence: String) {
            extractedReadCount += 1
            sequenceCounts[sequence, default: 0] += 1
        }
    }

    private struct SampleOutput: Sendable {
        let sampleID: String
        let barcode: String
        let bundleURL: URL
        let fastqURL: URL
        let rawReadCount: Int
        let extractedReadCount: Int
        let uniqueSequenceCount: Int
        let uniqueBaseCount: Int
        let weightedBaseCount: Int
    }
}
