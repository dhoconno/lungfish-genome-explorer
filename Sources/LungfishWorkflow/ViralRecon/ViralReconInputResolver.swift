import Foundation
import LungfishIO

public struct ViralReconResolvedInput: Sendable, Equatable {
    public let bundleURL: URL
    public let sampleName: String
    public let fastqURLs: [URL]
    public let platform: ViralReconPlatform
    public let barcode: String?
    public let sequencingSummaryURL: URL?

    public init(
        bundleURL: URL,
        sampleName: String,
        fastqURLs: [URL],
        platform: ViralReconPlatform,
        barcode: String?,
        sequencingSummaryURL: URL?
    ) {
        self.bundleURL = bundleURL
        self.sampleName = sampleName
        self.fastqURLs = fastqURLs
        self.platform = platform
        self.barcode = barcode
        self.sequencingSummaryURL = sequencingSummaryURL
    }
}

public enum ViralReconInputResolver {
    public enum ResolveError: Error, Sendable, Equatable {
        case noInputs
        case noFASTQ(URL)
        case unsupportedPlatform(URL)
        case mixedPlatforms
    }

    public static func makeSamples(from resolvedInputs: [ViralReconResolvedInput]) throws -> [ViralReconSample] {
        guard !resolvedInputs.isEmpty else { throw ResolveError.noInputs }
        let platforms = Set(resolvedInputs.map(\.platform))
        guard platforms.count == 1 else { throw ResolveError.mixedPlatforms }

        return resolvedInputs.enumerated().map { index, input in
            let barcode: String?
            if input.platform == .nanopore {
                barcode = input.barcode ?? String(format: "%02d", index + 1)
            } else {
                barcode = input.barcode
            }
            return ViralReconSample(
                sampleName: input.sampleName,
                sourceBundleURL: input.bundleURL,
                fastqURLs: input.fastqURLs,
                barcode: barcode,
                sequencingSummaryURL: input.sequencingSummaryURL
            )
        }
    }

    public static func resolveInputs(from urls: [URL]) throws -> [ViralReconResolvedInput] {
        guard !urls.isEmpty else { throw ResolveError.noInputs }
        var resolved: [ViralReconResolvedInput] = []
        for url in urls {
            resolved.append(try resolveInput(from: url))
        }
        _ = try makeSamples(from: resolved)
        return resolved
    }

    private static func resolveInput(from url: URL) throws -> ViralReconResolvedInput {
        let fastqURLs: [URL]
        let sourceURL: URL
        if FASTQBundle.isBundleURL(url) {
            guard let urls = FASTQBundle.resolveAllFASTQURLs(for: url), !urls.isEmpty else {
                throw ResolveError.noFASTQ(url)
            }
            fastqURLs = urls
            sourceURL = url
        } else if FASTQBundle.isFASTQFileURL(url) {
            fastqURLs = [url]
            sourceURL = url
        } else {
            throw ResolveError.noFASTQ(url)
        }

        guard let platform = resolvePlatform(for: sourceURL, fastqURLs: fastqURLs) else {
            throw ResolveError.unsupportedPlatform(url)
        }

        return ViralReconResolvedInput(
            bundleURL: sourceURL,
            sampleName: sampleName(for: sourceURL),
            fastqURLs: fastqURLs,
            platform: platform,
            barcode: barcode(for: sourceURL),
            sequencingSummaryURL: sequencingSummaryURL(in: sourceURL)
        )
    }

    private static func resolvePlatform(for sourceURL: URL, fastqURLs: [URL]) -> ViralReconPlatform? {
        for fastqURL in fastqURLs {
            if let persisted = FASTQMetadataStore.load(for: fastqURL) {
                if let platform = persisted.sequencingPlatform,
                   let normalized = normalize(platform: platform) {
                    return normalized
                }
                if let assemblyReadType = persisted.assemblyReadType,
                   let normalized = normalize(assemblyReadType: assemblyReadType) {
                    return normalized
                }
            }
        }

        if FASTQBundle.isBundleURL(sourceURL),
           let metadata = FASTQBundleCSVMetadata.load(from: sourceURL) {
            let sampleMetadata = FASTQSampleMetadata(from: metadata, fallbackName: fallbackSampleName(for: sourceURL))
            for value in persistedPlatformValues(from: sampleMetadata, legacy: metadata) {
                if let platform = normalize(platform: LungfishIO.SequencingPlatform(vendor: value)) {
                    return platform
                }
            }
        }

        for fastqURL in fastqURLs {
            if let detected = LungfishIO.SequencingPlatform.detect(fromFASTQ: fastqURL),
               let platform = normalize(platform: detected) {
                return platform
            }
        }
        return nil
    }

    private static func normalize(platform: LungfishIO.SequencingPlatform) -> ViralReconPlatform? {
        switch platform {
        case .illumina, .element, .ultima, .mgi:
            return .illumina
        case .oxfordNanopore:
            return .nanopore
        case .pacbio, .unknown:
            return nil
        }
    }

    private static func normalize(assemblyReadType: FASTQAssemblyReadType) -> ViralReconPlatform? {
        switch assemblyReadType {
        case .illuminaShortReads:
            return .illumina
        case .ontReads:
            return .nanopore
        case .pacBioHiFi:
            return nil
        }
    }

    private static func sampleName(for sourceURL: URL) -> String {
        if FASTQBundle.isBundleURL(sourceURL),
           let metadata = FASTQBundleCSVMetadata.load(from: sourceURL),
           let sampleName = typedSampleName(from: metadata, fallbackName: fallbackSampleName(for: sourceURL)) {
            return sampleName
        }
        let name = fallbackSampleName(for: sourceURL)
        return name.isEmpty ? "sample" : name
    }

    private static func fallbackSampleName(for sourceURL: URL) -> String {
        var name = sourceURL.deletingPathExtension().lastPathComponent
        if name.hasSuffix(".fastq") || name.hasSuffix(".fq") {
            name = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        }
        return name
    }

    private static func typedSampleName(from metadata: FASTQBundleCSVMetadata, fallbackName: String) -> String? {
        let sampleMetadata = FASTQSampleMetadata(from: metadata, fallbackName: fallbackName)
        if !sampleMetadata.sampleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           sampleMetadata.sampleName != fallbackName {
            return sampleMetadata.sampleName
        }
        if let label = metadata.displayLabel, !label.isEmpty {
            return label
        }
        return nil
    }

    private static func persistedPlatformValues(
        from sampleMetadata: FASTQSampleMetadata,
        legacy: FASTQBundleCSVMetadata
    ) -> [String] {
        let keys = ["sequencing_platform", "platform", "vendor", "read_type", "assembly_read_type"]
        var values: [String] = []
        for key in keys {
            if let value = sampleMetadata.customFields[key], !value.isEmpty {
                values.append(value)
            }
            if let value = legacy.value(forKey: key), !value.isEmpty {
                values.append(value)
            }
        }
        if let libraryStrategy = sampleMetadata.libraryStrategy, !libraryStrategy.isEmpty {
            values.append(libraryStrategy)
        }
        return values
    }

    private static func barcode(for sourceURL: URL) -> String? {
        guard FASTQBundle.isBundleURL(sourceURL),
              let metadata = FASTQBundleCSVMetadata.load(from: sourceURL) else {
            return nil
        }
        return metadata.value(forKey: "barcode")
            ?? metadata.value(forKey: "barcode_id")
            ?? metadata.value(forKey: "barcode_alias")
    }

    private static func sequencingSummaryURL(in sourceURL: URL) -> URL? {
        guard FASTQBundle.isBundleURL(sourceURL) else { return nil }
        let candidateNames = ["sequencing_summary.txt", "sequencing_summary.tsv"]
        for name in candidateNames {
            let url = sourceURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
