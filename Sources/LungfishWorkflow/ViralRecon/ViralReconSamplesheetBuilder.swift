import Foundation
import LungfishIO

public enum ViralReconSamplesheetBuilder {
    public enum ValidationError: Error, LocalizedError, Sendable, Equatable {
        case unsupportedIlluminaFASTQ(URL)
        /// A virtual bundle holds no FASTQ file to copy into `fastq_pass`.
        case virtualNanoporeBundle(URL)
        /// viralrecon's samplesheet refuses a `sample` cell that holds
        /// whitespace (`^\S+$` in `assets/schema_input.json`), and then the
        /// whole run fails, so LGE refuses the name before launch.
        case sampleNameHoldsSpace(String)
        /// viralrecon refuses a `fastq_1` or `fastq_2` whose file name holds
        /// whitespace (its folders may hold some).
        case readFileNameHoldsSpace(sampleName: String, URL)

        public var errorDescription: String? {
            switch self {
            case .sampleNameHoldsSpace(let name):
                return "The sample name “\(name)” holds a space, and viralrecon's samplesheet does not accept one. "
                    + "Rename the sample, for example to “\(ViralReconSamplesheetBuilder.replacingWhitespace(in: name))”, "
                    + "and run again."
            case .readFileNameHoldsSpace(let sampleName, let url):
                let name = url.lastPathComponent
                return "The read file “\(name)” of sample “\(sampleName)” holds a space in its name, "
                    + "and viralrecon's samplesheet does not accept one. Rename the file, "
                    + "for example to “\(ViralReconSamplesheetBuilder.replacingWhitespace(in: name))”, and run again."
            case .unsupportedIlluminaFASTQ(let url):
                return "The read file “\(url.lastPathComponent)” does not end in .fastq.gz or .fq.gz, "
                    + "which viralrecon's samplesheet requires. Compress a plain FASTQ file with gzip, "
                    + "or rename a gzip file to end in .fastq.gz, and run again."
            case .virtualNanoporeBundle(let url):
                return """
                    \(url.lastPathComponent) is a virtual bundle, so it holds no FASTQ file for viralrecon's \
                    Nanopore mode to read, and its preview is only part of the sample. Write its reads first \
                    with lungfish-cli fastq materialize "\(url.path)" -o <reads.fastq>, then run on that file.
                    """
            }
        }
    }

    public struct NanoporeStagingResult: Sendable, Equatable {
        public let samplesheetURL: URL
        public let fastqPassDirectory: URL
    }

    /// Writes `sample,fastq_1,fastq_2` rows: a sample's files are paired by
    /// position, so `[R1, R2]` becomes one paired row and `[single]` a
    /// single-end row. A strictly interleaved bundle file must be split into
    /// R1/R2 first (``ViralReconReadPairing/prepareIlluminaSamples(_:splitRoot:materializer:progress:)``)
    /// or its mates run single-end. A row may name one `.lungfishfastq`
    /// bundle, which the run plans and stages as gzip files before
    /// viralrecon starts.
    public static func writeIlluminaSamplesheet(
        samples: [ViralReconSample],
        in directory: URL,
        filename: String = "samplesheet.csv"
    ) throws -> URL {
        try refuseNamesViralReconRefuses(in: samples)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        var lines = ["sample,fastq_1,fastq_2"]
        for sample in samples {
            for fastqURL in sample.fastqURLs where !ViralReconReadPairing.namesBundle(sample.fastqURLs) {
                guard isCompressedFASTQ(fastqURL) else {
                    throw ValidationError.unsupportedIlluminaFASTQ(fastqURL)
                }
            }
            for index in stride(from: 0, to: sample.fastqURLs.count, by: 2) {
                let first = sample.fastqURLs[index].path
                let second = index + 1 < sample.fastqURLs.count ? sample.fastqURLs[index + 1].path : ""
                lines.append([sample.sampleName, first, second].map(escapeCSVField).joined(separator: ","))
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Copies each sample's FASTQ files into `fastq_pass/barcodeNN` and
    /// writes the `sample,barcode` samplesheet. A virtual bundle is refused
    /// before anything is written, because its listed file is its preview.
    public static func stageNanoporeInputs(
        samples: [ViralReconSample],
        in directory: URL
    ) throws -> NanoporeStagingResult {
        if let virtual = samples.first(where: { ViralReconReadPairing.isVirtualBundle($0.sourceBundleURL) }) {
            throw ValidationError.virtualNanoporeBundle(virtual.sourceBundleURL)
        }
        try refuseSampleNamesWithSpace(samples.map(\.sampleName))
        let fastqPassDirectory = directory.appendingPathComponent("fastq_pass", isDirectory: true)
        try FileManager.default.createDirectory(at: fastqPassDirectory, withIntermediateDirectories: true)

        for sample in samples {
            let barcode = normalizedBarcode(sample.barcode)
            let barcodeDirectory = fastqPassDirectory.appendingPathComponent("barcode\(barcode.directoryValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: barcodeDirectory, withIntermediateDirectories: true)
            for fastqURL in sample.fastqURLs {
                let destination = barcodeDirectory.appendingPathComponent(fastqURL.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: fastqURL, to: destination)
            }
        }

        let samplesheetURL = directory.appendingPathComponent("samplesheet.csv")
        var lines = ["sample,barcode"]
        for sample in samples {
            let barcode = normalizedBarcode(sample.barcode)
            lines.append([sample.sampleName, barcode.samplesheetValue].map(escapeCSVField).joined(separator: ","))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: samplesheetURL, atomically: true, encoding: .utf8)
        return NanoporeStagingResult(samplesheetURL: samplesheetURL, fastqPassDirectory: fastqPassDirectory)
    }

    /// Refuses the first sample name that holds whitespace, which
    /// viralrecon's samplesheet refuses (`^\S+$`). The wizard, the app's Run
    /// and `workflow run` with bundle inputs reach this through
    /// ``ViralReconInputResolver/makeSamples(from:)``, so the run stops
    /// before any read is split or staged, and both samplesheet writers call
    /// it again (trust session FIX-VR, F1). A samplesheet that a caller wrote
    /// by hand is not read for names. The run checks it only when it writes
    /// the samplesheet again for a split read.
    ///
    /// The name is refused, not mapped. A mapped name would stay inside the
    /// files the ingest copies byte for byte (the consensus header, Pangolin's
    /// `taxon`, Nextclade's `seqName`) while the bundle carries the user's
    /// name, so one sample would go by two labels (ruling BIO, SWEEP-1 B2).
    public static func refuseSampleNamesWithSpace(_ names: [String]) throws {
        if let name = names.first(where: holdsWhitespace) {
            throw ValidationError.sampleNameHoldsSpace(name)
        }
    }

    /// Refuses a sample name with whitespace, then a read file of a paired
    /// row whose name holds whitespace. A paired row goes to viralrecon as
    /// named. A row of one file is left alone, because the run may split it
    /// and the split names its halves without whitespace
    /// (``ViralReconReadPairing/splitInterleavedInput(_:into:)``).
    public static func refuseNamesViralReconRefuses(in samples: [ViralReconSample]) throws {
        try refuseSampleNamesWithSpace(samples.map(\.sampleName))
        for sample in samples where !ViralReconReadPairing.namesBundle(sample.fastqURLs) {
            for index in stride(from: 0, to: sample.fastqURLs.count, by: 2) where index + 1 < sample.fastqURLs.count {
                for url in sample.fastqURLs[index...(index + 1)] where holdsWhitespace(url.lastPathComponent) {
                    throw ValidationError.readFileNameHoldsSpace(sampleName: sample.sampleName, url)
                }
            }
        }
    }

    static func holdsWhitespace(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }

    /// `text` with each whitespace character replaced by `_`.
    static func replacingWhitespace(in text: String) -> String {
        String(text.unicodeScalars.map { CharacterSet.whitespacesAndNewlines.contains($0) ? "_" : Character($0) })
    }

    private static func isCompressedFASTQ(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.hasSuffix(".fastq.gz") || path.hasSuffix(".fq.gz")
    }

    private static func normalizedBarcode(_ value: String?) -> (samplesheetValue: String, directoryValue: String) {
        let rawValue = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "1"
        let withoutPrefix: String
        if rawValue.hasPrefix("barcode") {
            withoutPrefix = String(rawValue.dropFirst("barcode".count))
        } else if rawValue.hasPrefix("bc") {
            withoutPrefix = String(rawValue.dropFirst("bc".count))
        } else {
            withoutPrefix = rawValue
        }

        if let number = Int(withoutPrefix), number > 0 {
            return (String(number), String(format: "%02d", number))
        }
        let fallback = withoutPrefix.isEmpty ? "1" : withoutPrefix
        return (fallback, fallback)
    }

    private static func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
