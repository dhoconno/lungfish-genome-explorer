import Foundation

public enum ViralReconSamplesheetBuilder {
    public enum ValidationError: Error, Sendable, Equatable {
        case unsupportedIlluminaFASTQ(URL)
    }

    public struct NanoporeStagingResult: Sendable, Equatable {
        public let samplesheetURL: URL
        public let fastqPassDirectory: URL
    }

    public static func writeIlluminaSamplesheet(
        samples: [ViralReconSample],
        in directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("samplesheet.csv")
        var lines = ["sample,fastq_1,fastq_2"]
        for sample in samples {
            for fastqURL in sample.fastqURLs {
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

    public static func stageNanoporeInputs(
        samples: [ViralReconSample],
        in directory: URL
    ) throws -> NanoporeStagingResult {
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
