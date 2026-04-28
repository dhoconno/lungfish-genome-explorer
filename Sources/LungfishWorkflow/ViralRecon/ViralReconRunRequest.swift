import Foundation

public enum ViralReconPlatform: String, Codable, Sendable, Equatable, CaseIterable {
    case illumina
    case nanopore
}

public enum ViralReconProtocol: String, Codable, Sendable, Equatable {
    case amplicon
}

public enum ViralReconVariantCaller: String, Codable, Sendable, Equatable, CaseIterable {
    case ivar
    case bcftools
}

public enum ViralReconConsensusCaller: String, Codable, Sendable, Equatable, CaseIterable {
    case ivar
    case bcftools
}

public enum ViralReconSkipOption: String, Codable, Sendable, Equatable, CaseIterable {
    case assembly = "skip_assembly"
    case variants = "skip_variants"
    case consensus = "skip_consensus"
    case fastQC = "skip_fastqc"
    case kraken2 = "skip_kraken2"
    case fastp = "skip_fastp"
    case cutadapt = "skip_cutadapt"
    case ivarTrim = "skip_ivar_trim"
    case multiQC = "skip_multiqc"
}

public struct ViralReconSample: Codable, Sendable, Equatable {
    public let sampleName: String
    public let sourceBundleURL: URL
    public let fastqURLs: [URL]
    public let barcode: String?
    public let sequencingSummaryURL: URL?

    public init(
        sampleName: String,
        sourceBundleURL: URL,
        fastqURLs: [URL],
        barcode: String?,
        sequencingSummaryURL: URL?
    ) {
        self.sampleName = sampleName
        self.sourceBundleURL = sourceBundleURL
        self.fastqURLs = fastqURLs
        self.barcode = barcode
        self.sequencingSummaryURL = sequencingSummaryURL
    }
}

public enum ViralReconReference: Codable, Sendable, Equatable {
    case genome(String)
    case local(fastaURL: URL, gffURL: URL?)
}

public struct ViralReconPrimerSelection: Codable, Sendable, Equatable {
    public let bundleURL: URL
    public let displayName: String
    public let bedURL: URL
    public let fastaURL: URL
    public let leftSuffix: String
    public let rightSuffix: String
    public let derivedFasta: Bool

    public init(
        bundleURL: URL,
        displayName: String,
        bedURL: URL,
        fastaURL: URL,
        leftSuffix: String,
        rightSuffix: String,
        derivedFasta: Bool
    ) {
        self.bundleURL = bundleURL
        self.displayName = displayName
        self.bedURL = bedURL
        self.fastaURL = fastaURL
        self.leftSuffix = leftSuffix
        self.rightSuffix = rightSuffix
        self.derivedFasta = derivedFasta
    }
}

public struct ViralReconRunRequest: Codable, Sendable, Equatable {
    public enum ValidationError: Error, Sendable, Equatable {
        case conflictingAdvancedParam(String)
        case emptySamples
    }

    public let samples: [ViralReconSample]
    public let platform: ViralReconPlatform
    public let `protocol`: ViralReconProtocol
    public let samplesheetURL: URL
    public let outputDirectory: URL
    public let executor: NFCoreExecutor
    public let version: String
    public let reference: ViralReconReference
    public let primer: ViralReconPrimerSelection
    public let minimumMappedReads: Int
    public let variantCaller: ViralReconVariantCaller
    public let consensusCaller: ViralReconConsensusCaller
    public let skipOptions: [ViralReconSkipOption]
    public let advancedParams: [String: String]
    public let fastqPassDirectoryURL: URL?
    public let sequencingSummaryURL: URL?

    public var effectiveParams: [String: String] {
        var params: [String: String] = [
            "input": samplesheetURL.path,
            "outdir": outputDirectory.path,
            "platform": platform.rawValue,
            "protocol": `protocol`.rawValue,
            "primer_bed": primer.bedURL.path,
            "primer_fasta": primer.fastaURL.path,
            "primer_left_suffix": primer.leftSuffix,
            "primer_right_suffix": primer.rightSuffix,
            "min_mapped_reads": String(minimumMappedReads),
            "variant_caller": variantCaller.rawValue,
            "consensus_caller": consensusCaller.rawValue,
        ]

        if platform == .nanopore, let fastqPassDirectoryURL {
            params["fastq_dir"] = fastqPassDirectoryURL.path
        }
        if platform == .nanopore, let sequencingSummaryURL {
            params["sequencing_summary"] = sequencingSummaryURL.path
        }

        switch reference {
        case .genome(let genome):
            params["genome"] = genome
        case .local(let fastaURL, let gffURL):
            params["fasta"] = fastaURL.path
            if let gffURL {
                params["gff"] = gffURL.path
            }
        }

        for option in skipOptions {
            params[option.rawValue] = "true"
        }
        for key in advancedParams.keys.sorted() {
            params[key] = advancedParams[key]
        }
        return params
    }

    public init(
        samples: [ViralReconSample],
        platform: ViralReconPlatform,
        protocol: ViralReconProtocol,
        samplesheetURL: URL,
        outputDirectory: URL,
        executor: NFCoreExecutor,
        version: String,
        reference: ViralReconReference,
        primer: ViralReconPrimerSelection,
        minimumMappedReads: Int,
        variantCaller: ViralReconVariantCaller,
        consensusCaller: ViralReconConsensusCaller,
        skipOptions: [ViralReconSkipOption],
        advancedParams: [String: String] = [:],
        fastqPassDirectoryURL: URL? = nil,
        sequencingSummaryURL: URL? = nil
    ) throws {
        guard !samples.isEmpty else { throw ValidationError.emptySamples }
        try Self.validateAdvancedParams(advancedParams)
        let resolvedSequencingSummaryURL = Self.validSequencingSummaryURL(
            explicit: sequencingSummaryURL,
            samples: samples
        )
        self.samples = samples
        self.platform = platform
        self.protocol = `protocol`
        self.samplesheetURL = samplesheetURL
        self.outputDirectory = outputDirectory
        self.executor = executor
        self.version = version
        self.reference = reference
        self.primer = primer
        self.minimumMappedReads = minimumMappedReads
        self.variantCaller = variantCaller
        self.consensusCaller = consensusCaller
        self.skipOptions = skipOptions
        self.advancedParams = advancedParams
        self.fastqPassDirectoryURL = fastqPassDirectoryURL
        self.sequencingSummaryURL = resolvedSequencingSummaryURL
    }

    public static func validateAdvancedParams(_ params: [String: String]) throws {
        let generatedKeys = Set([
            "input", "outdir", "platform", "protocol", "genome", "fasta", "gff",
            "fastq_dir", "sequencing_summary",
            "primer_bed", "primer_fasta", "primer_left_suffix", "primer_right_suffix",
            "min_mapped_reads", "variant_caller", "consensus_caller",
        ] + ViralReconSkipOption.allCases.map(\.rawValue))

        for key in params.keys.sorted() where generatedKeys.contains(key) {
            throw ValidationError.conflictingAdvancedParam(key)
        }
    }

    private static func validSequencingSummaryURL(
        explicit: URL?,
        samples: [ViralReconSample]
    ) -> URL? {
        let candidates: [URL]
        if let explicit {
            candidates = [explicit]
        } else {
            candidates = Array(Set(samples.compactMap(\.sequencingSummaryURL)))
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }

        for url in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return url
            }
        }
        return nil
    }

    public func cliArguments(bundlePath: URL, prepareOnly: Bool = false) -> [String] {
        var args = [
            "workflow",
            "run",
            "nf-core/viralrecon",
            "--executor",
            executor.rawValue,
            "--results-dir",
            outputDirectory.path,
            "--bundle-path",
            bundlePath.path,
            "--version",
            version,
            "--input",
            samplesheetURL.path,
        ]

        for key in effectiveParams.keys.sorted() where key != "input" && key != "outdir" {
            guard let value = effectiveParams[key], !value.isEmpty else { continue }
            args += ["--param", "\(key)=\(value)"]
        }
        if prepareOnly {
            args.append("--prepare-only")
        }
        return args
    }
}
