import Foundation

public enum ViralReconSamplesheetBuilder {
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
            let barcode = sample.barcode ?? "01"
            let barcodeDirectory = fastqPassDirectory.appendingPathComponent("barcode\(barcode)", isDirectory: true)
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
            lines.append([sample.sampleName, sample.barcode ?? "01"].map(escapeCSVField).joined(separator: ","))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: samplesheetURL, atomically: true, encoding: .utf8)
        return NanoporeStagingResult(samplesheetURL: samplesheetURL, fastqPassDirectory: fastqPassDirectory)
    }

    private static func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
