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
    case freyja = "skip_freyja"
    case freyjaBoot = "skip_freyja_boot"

    /// Steps this pipeline can never run here, whatever the caller asked for.
    ///
    /// Lungfish ships for Apple Silicon only, and viralrecon pins Freyja to an
    /// amd64-only container. Under Rosetta its bootstrap workers are killed
    /// outright, which fails the whole run after every other output has been
    /// written, and there is no configuration in which running it here helps.
    /// Both parameters are therefore forced rather than defaulted.
    ///
    /// This is a statement about the pipeline's container pin, not about the
    /// tool: Lungfish runs Freyja natively from the wastewater-surveillance
    /// pack, where bioconda ships a real arm64 build that demixes and
    /// bootstraps without trouble.
    public static let alwaysSkipped: Set<ViralReconSkipOption> = [
        .freyja,
        .freyjaBoot,
    ]

    /// The skips a new run starts with, over and above `alwaysSkipped`.
    public static let defaultSelection: Set<ViralReconSkipOption> = [
        .assembly,
        .kraken2,
    ]

    /// Skips the user can choose, i.e. everything not forced.
    public static var selectable: [ViralReconSkipOption] {
        allCases.filter { !alwaysSkipped.contains($0) }
    }
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
    /// A GFF3 annotation chosen in the wizard, overriding the one the reference
    /// bundle carries. Kept out of `advancedParams` because `gff` is structural
    /// there and would be refused.
    public let gffURL: URL?
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
        case .local(let fastaURL, let referenceGFFURL):
            params["fasta"] = fastaURL.path
            if let referenceGFFURL {
                params["gff"] = referenceGFFURL.path
            }
        }
        if let gffURL {
            params["gff"] = gffURL.path
        }

        for option in Set(skipOptions).union(ViralReconSkipOption.alwaysSkipped) {
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
        gffURL: URL? = nil,
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
        self.gffURL = gffURL
        self.fastqPassDirectoryURL = fastqPassDirectoryURL
        self.sequencingSummaryURL = resolvedSequencingSummaryURL
    }

    /// Keys an advanced user may override. These change how the pipeline runs
    /// without changing what the wizard is describing.
    public static var overridableAdvancedKeys: Set<String> {
        var keys: Set<String> = ["variant_caller", "consensus_caller", "min_mapped_reads",
                                 "max_cpus", "max_memory"]
        for option in ViralReconSkipOption.allCases
        where !ViralReconSkipOption.alwaysSkipped.contains(option) {
            keys.insert(option.rawValue)
        }
        return keys
    }

    /// Keys the wizard owns. Overriding these would contradict the inputs the
    /// user selected, so they are refused with the owning control named.
    public static var structuralAdvancedKeys: Set<String> {
        var keys: Set<String> = ["input", "outdir", "platform", "protocol",
                                 "primer_bed", "primer_fasta", "primer_left_suffix",
                                 "primer_right_suffix", "genome", "fasta", "gff",
                                 "fastq_dir", "sequencing_summary"]
        for option in ViralReconSkipOption.alwaysSkipped {
            keys.insert(option.rawValue)
        }
        return keys
    }

    public static func validateAdvancedParams(_ params: [String: String]) throws {
        for key in params.keys.sorted() where structuralAdvancedKeys.contains(key) {
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

        args += ["--expected-output", outputDirectory.path]

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
