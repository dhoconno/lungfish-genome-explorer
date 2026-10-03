@preconcurrency import Foundation

extension PackToolSpec {
    func requestedSourceOverlay() throws -> PackToolSourceOverlay? {
        guard let sourceBuild else { return nil }
        guard let kind = PackToolSourceOverlay.Kind(rawValue: toolID),
              let url = URL(string: sourceBuild.url),
              !sourceBuild.toolchainPackages.isEmpty,
              sourceBuild.toolchainPackages.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CondaLockfileError.invalidSpecification("Unsupported source-build recipe or missing toolchain for '\(toolID)'.")
        }
        let overlay = PackToolSourceOverlay(kind: kind, version: sourceBuild.version,
            sourceURL: url, sha256: sourceBuild.sha256)
        try overlay.validateRequestedIdentity()
        return overlay
    }
}

public struct PluginPack: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let description: String
    public let sfSymbol: String
    public let packages: [String]
    public let category: String
    public let kind: PluginPackKind
    public let isActive: Bool
    public let isExperimental: Bool
    public let requirements: [PackToolRequirement]
    public let postInstallHooks: [PostInstallHook]
    public let estimatedSizeMB: Int

    public init(
        id: String,
        name: String,
        description: String,
        sfSymbol: String,
        packages: [String],
        category: String,
        kind: PluginPackKind = .optionalTools,
        isActive: Bool = false,
        isExperimental: Bool = false,
        requirements: [PackToolRequirement] = [],
        postInstallHooks: [PostInstallHook] = [],
        estimatedSizeMB: Int = 0
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.sfSymbol = sfSymbol
        self.packages = packages
        self.category = category
        self.kind = kind
        self.isActive = isActive
        self.isExperimental = isExperimental
        self.requirements = requirements
        self.postInstallHooks = postInstallHooks
        self.estimatedSizeMB = estimatedSizeMB
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case sfSymbol
        case packages
        case category
        case kind
        case isActive
        case isExperimental
        case requirements
        case postInstallHooks
        case estimatedSizeMB
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decode(String.self, forKey: .description)
        self.sfSymbol = try container.decode(String.self, forKey: .sfSymbol)
        self.packages = try container.decode([String].self, forKey: .packages)
        self.category = try container.decode(String.self, forKey: .category)
        self.kind = try container.decodeIfPresent(PluginPackKind.self, forKey: .kind) ?? .optionalTools
        self.isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        self.isExperimental = try container.decodeIfPresent(Bool.self, forKey: .isExperimental) ?? false
        self.requirements = try container.decodeIfPresent([PackToolRequirement].self, forKey: .requirements) ?? []
        self.postInstallHooks = try container.decodeIfPresent([PostInstallHook].self, forKey: .postInstallHooks) ?? []
        self.estimatedSizeMB = try container.decodeIfPresent(Int.self, forKey: .estimatedSizeMB) ?? 0
    }

    public var isRequiredBeforeLaunch: Bool {
        kind == .requiredSetup
    }

    public var toolRequirements: [PackToolRequirement] {
        requirements.isEmpty ? packages.map { PackToolRequirement.package($0) } : requirements
    }
}

public extension PluginPack {
    static func builtInPack(id packID: String) -> PluginPack? {
        builtIn.first { $0.id == packID }
    }

    static let requiredSetupPack: PluginPack = makeRequiredSetupPack {
        try ManagedToolLock.loadFromBundle()
    }

    internal static func makeRequiredSetupPack(
        lockLoader: () throws -> ManagedToolLock
    ) -> PluginPack {
        do {
            return requiredSetupPack(from: try lockLoader())
        } catch {
            return fallbackRequiredSetupPack(loadError: error)
        }
    }

    /// What the required setup pack is for. Projects open with the built-in
    /// viewers before anything is installed; the pack gates analyses, not
    /// project creation or opening.
    static let requiredSetupDescription =
        "Needed to run analyses. Projects open with the built-in viewers before it is installed."

    private static func requiredSetupPack(from lock: ManagedToolLock) -> PluginPack {
        return PluginPack(
            id: lock.packID,
            name: lock.displayName,
            description: requiredSetupDescription,
            sfSymbol: "checklist",
            packages: lock.tools.map(\.environment),
            category: "Required Setup",
            kind: .requiredSetup,
            isActive: true,
            requirements: PackToolRequirement.from(lock: lock),
            estimatedSizeMB: 2700
        )
    }

    private static func fallbackRequiredSetupPack(loadError: Error) -> PluginPack {
        PluginPack(
            id: "lungfish-tools",
            name: "Third-Party Tools",
            description: "\(requiredSetupDescription) The managed tool lock manifest could not be loaded: \(loadError.localizedDescription)",
            sfSymbol: "exclamationmark.triangle",
            packages: ["managed-tool-lock-manifest"],
            category: "Required Setup",
            kind: .requiredSetup,
            isActive: true,
            requirements: [
                PackToolRequirement(
                    id: "managed-tool-lock-manifest",
                    displayName: "Managed tool lock manifest",
                    environment: "lungfish-tools-lock",
                    installPackages: ["managed-tool-lock-manifest"],
                    executables: ["third-party-tools-lock.json"]
                ),
            ],
            estimatedSizeMB: 2700
        )
    }

    static let builtIn: [PluginPack] = [
        requiredSetupPack,
        PluginPack(
            id: "illumina-qc",
            name: "Illumina QC",
            description: "Quality control and reporting for Illumina short-read sequencing data",
            sfSymbol: "waveform.badge.magnifyingglass",
            packages: ["fastqc", "multiqc", "trimmomatic"],
            category: "Quality Control",
            estimatedSizeMB: 1000
        ),
        PluginPack(
            id: "read-mapping",
            name: "Read Mapping",
            description: "Reference-guided mapping for short and long sequencing reads",
            sfSymbol: "arrow.left.and.right.text.vertical",
            packages: ["minimap2", "bwa-mem2", "bowtie2"],
            category: "Mapping",
            isActive: true,
            requirements: [
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "read-mapping",
                    id: "minimap2",
                    displayName: "minimap2",
                    executables: ["minimap2"],
                    smokeTest: .command(
                        executable: "minimap2",
                        arguments: ["--help"],
                        timeoutSeconds: 10,
                        acceptedExitCodes: [0, 1],
                        requiredOutputSubstring: "Usage"
                    )
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "read-mapping",
                    id: "bwa-mem2",
                    displayName: "BWA-MEM2",
                    executables: ["bwa-mem2"],
                    smokeTest: .command(
                        executable: "bwa-mem2",
                        arguments: [],
                        timeoutSeconds: 10,
                        acceptedExitCodes: [1],
                        requiredOutputSubstring: "Usage: bwa-mem2"
                    )
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "read-mapping",
                    id: "bowtie2",
                    displayName: "Bowtie2",
                    executables: ["bowtie2", "bowtie2-build"],
                    smokeTest: .command(
                        executable: "bowtie2",
                        arguments: ["--help"],
                        timeoutSeconds: 10,
                        acceptedExitCodes: [0, 1],
                        requiredOutputSubstring: "bowtie2"
                    )
                ),
            ],
            estimatedSizeMB: 260
        ),
        PluginPack(
            id: "full-length-mhc-genotyping",
            name: "Full-length MHC Genotyping",
            description: "Savont clustering and local BLAST rescue for full-length ONT MHC genotyping workflows",
            sfSymbol: "scope",
            packages: ["savont", "blast"],
            category: "Specialized Workflows",
            isActive: true,
            requirements: [
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "full-length-mhc-genotyping",
                    id: "savont",
                    displayName: "Savont",
                    executables: ["savont"],
                    smokeTest: .command(
                        arguments: ["--help"],
                        timeoutSeconds: 10,
                        requiredOutputSubstring: "Turn >~ 98% accuracy long reads into ASVs"
                    )
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "full-length-mhc-genotyping",
                    id: "blast",
                    displayName: "NCBI BLAST+",
                    executables: ["blastn"],
                    smokeTest: .command(
                        executable: "blastn",
                        arguments: ["-help"],
                        timeoutSeconds: 10,
                        requiredOutputSubstring: "Nucleotide-Nucleotide BLAST"
                    )
                ),
            ],
            estimatedSizeMB: 650
        ),
        PluginPack(
            id: "pcr-primer-design",
            name: "PCR Primer Design",
            description: "Independent Primer3, PrimalScheme, Olivar, and varVAMP primer design runtimes.",
            sfSymbol: "lines.measurement.horizontal",
            packages: ["primer3", "primalscheme3", "olivar", "varvamp"],
            category: "Specialized Workflows",
            isActive: true,
            requirements: [
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "pcr-primer-design",
                    id: "primer3",
                    displayName: "Primer3",
                    executables: ["primer3_core"],
                    smokeTest: .command(
                        executable: "primer3_core",
                        arguments: ["--about"],
                        timeoutSeconds: 10,
                        acceptedExitCodes: [0],
                        requiredOutputSubstring: "libprimer3 release \(ManagedToolLock.bundled.packTool(packID: "pcr-primer-design", id: "primer3")?.version ?? "")"
                    )
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "pcr-primer-design",
                    id: "primalscheme3",
                    displayName: "PrimalScheme",
                    executables: ["primalscheme3"],
                    smokeTest: .command(
                        executable: "primalscheme3",
                        arguments: ["--version"],
                        timeoutSeconds: 10,
                        acceptedExitCodes: [0],
                        requiredOutputSubstring: "PrimalScheme3-LGE version: \(ManagedToolLock.bundled.packTool(packID: "pcr-primer-design", id: "primalscheme3")?.version ?? "")"
                    )
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "pcr-primer-design",
                    id: "olivar",
                    displayName: "Olivar",
                    executables: ["olivar"],
                    smokeTest: .command(
                        executable: "olivar",
                        arguments: ["--help"],
                        timeoutSeconds: 60,
                        acceptedExitCodes: [0]
                    )
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "pcr-primer-design",
                    id: "varvamp",
                    displayName: "varVAMP",
                    executables: ["varvamp"],
                    smokeTest: .command(
                        executable: "varvamp",
                        arguments: ["--help"],
                        timeoutSeconds: 60,
                        acceptedExitCodes: [0]
                    )
                ),
            ],
            estimatedSizeMB: 2_800
        ),
        PluginPack(
            id: "variant-calling",
            name: "Variant Calling",
            description: "Viral BAM variant calling from bundle-owned alignment tracks",
            sfSymbol: "diamond.fill",
            packages: ["lofreq", "ivar", "medaka", "clair3"],
            category: "Variant Calling",
            isActive: true,
            requirements: [
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "variant-calling",
                    id: "lofreq",
                    displayName: "LoFreq",
                    executables: ["lofreq"],
                    smokeTest: .command(
                        arguments: ["version"],
                        requiredOutputSubstring: "version:"
                    )
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "variant-calling",
                    id: "ivar",
                    displayName: "iVar",
                    executables: ["ivar"],
                    smokeTest: .command(arguments: ["version"])
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "variant-calling",
                    id: "medaka",
                    displayName: "Medaka",
                    executables: ["medaka"],
                    smokeTest: .command(arguments: ["--help"])
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "variant-calling",
                    id: "clair3",
                    displayName: "Clair3",
                    executables: ["run_clair3.sh"],
                    smokeTest: .command(
                        executable: "run_clair3.sh",
                        arguments: ["--help"],
                        timeoutSeconds: 30,
                        acceptedExitCodes: [0, 1],
                        requiredOutputSubstring: "Usage"
                    )
                ),
            ],
            estimatedSizeMB: 260
        ),
        PluginPack(
            id: "gatk-core",
            name: "GATK Core",
            description: "GATK4 command construction and dry-run support for human germline workflows",
            sfSymbol: "person.text.rectangle",
            packages: ["gatk4"],
            category: "Variant Calling",
            isActive: true,
            isExperimental: true,
            requirements: [
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "gatk-core",
                    id: "gatk4",
                    displayName: "GATK4",
                    executables: ["gatk"],
                    smokeTest: .command(
                        executable: "gatk",
                        arguments: ["--version"],
                        timeoutSeconds: 30,
                        requiredOutputSubstring: "The Genome Analysis Toolkit"
                    )
                ),
            ],
            estimatedSizeMB: 600
        ),
        PluginPack(
            id: "phasing",
            name: "Variant Phasing",
            description: "Read-backed haplotype phasing with WhatsHap",
            sfSymbol: "point.3.connected.trianglepath.dotted",
            packages: ["whatshap"],
            category: "Variant Calling",
            isActive: true,
            isExperimental: true,
            requirements: [
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "phasing",
                    id: "whatshap",
                    displayName: "WhatsHap",
                    executables: ["whatshap"],
                    smokeTest: .command(
                        executable: "whatshap",
                        arguments: ["--version"],
                        timeoutSeconds: 10
                    )
                ),
            ],
            estimatedSizeMB: 180
        ),
        PluginPack(
            id: "assembly",
            name: "Genome Assembly",
            description: "De novo genome assembly from short and long reads",
            sfSymbol: "puzzlepiece.extension.fill",
            packages: ["spades", "megahit", "skesa", "flye", "hifiasm"],
            category: "Assembly",
            isActive: true,
            requirements: [
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "assembly",
                    id: "spades",
                    displayName: "SPAdes",
                    executables: ["spades.py"],
                    smokeTest: .command(executable: "spades.py", arguments: ["--version"], timeoutSeconds: 10)
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "assembly",
                    id: "megahit",
                    displayName: "MEGAHIT",
                    executables: ["megahit"],
                    smokeTest: .command(executable: "megahit", arguments: ["--help"], timeoutSeconds: 10)
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "assembly",
                    id: "skesa",
                    displayName: "SKESA",
                    executables: ["skesa"],
                    smokeTest: .command(executable: "skesa", arguments: ["--help"], timeoutSeconds: 10)
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "assembly",
                    id: "flye",
                    displayName: "Flye",
                    executables: ["flye"],
                    smokeTest: .command(executable: "flye", arguments: ["--help"], timeoutSeconds: 10)
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "assembly",
                    id: "hifiasm",
                    displayName: "hifiasm",
                    executables: ["hifiasm"],
                    smokeTest: .command(executable: "hifiasm", arguments: ["-h"], timeoutSeconds: 10)
                ),
            ],
            estimatedSizeMB: 950
        ),
        PluginPack(
            id: "multiple-sequence-alignment",
            name: "Multiple Sequence Alignment",
            description: "Build, trim, and inspect nucleotide or protein multiple sequence alignments",
            sfSymbol: "rectangle.grid.1x2",
            packages: ["mafft"],
            category: "Phylogenetics",
            isActive: true,
            requirements: [
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "multiple-sequence-alignment",
                    id: "mafft",
                    displayName: "MAFFT",
                    executables: ["mafft"],
                    smokeTest: .command(
                        executable: "mafft",
                        arguments: ["--help"],
                        timeoutSeconds: 10,
                        acceptedExitCodes: [0, 1],
                        requiredOutputSubstring: "MAFFT"
                    )
                ),
            ],
            estimatedSizeMB: 120
        ),
        PluginPack(
            id: "phylogenetics",
            name: "Phylogenetics",
            description: "Infer, annotate, and inspect native Apple Silicon phylogenetic trees",
            sfSymbol: "tree",
            packages: ["iqtree"],
            category: "Phylogenetics",
            isActive: true,
            requirements: [
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "phylogenetics",
                    id: "iqtree",
                    displayName: "IQ-TREE",
                    executables: ["iqtree3"],
                    smokeTest: .command(
                        executable: "iqtree3",
                        arguments: ["--help"],
                        timeoutSeconds: 10,
                        requiredOutputSubstring: "IQ-TREE"
                    )
                ),
            ],
            estimatedSizeMB: 180
        ),
        PluginPack(
            id: "metagenomics",
            name: "Metagenomics",
            description: "Taxonomic classification and pathogen detection from metagenomic samples",
            sfSymbol: "leaf.fill",
            packages: ["kraken2", "bracken", "esviritu", "ribodetector"],
            category: "Metagenomics",
            isActive: true,
            requirements: [
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "metagenomics",
                    id: "kraken2",
                    displayName: "Kraken 2",
                    executables: ["kraken2", "kraken2-build"],
                    smokeTest: .command(arguments: ["--version"])
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "metagenomics",
                    id: "bracken",
                    displayName: "Bracken",
                    executables: ["bracken", "bracken-build"],
                    // Built from source: the manifest entry's sourceBuild pins the v3.1
                    // tarball and its toolchain, because bioconda's only arm64 build
                    // ships no driver. fromManifest derives the overlay from it.
                    smokeTest: .command(arguments: ["--help"])
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "metagenomics",
                    id: "esviritu",
                    displayName: "EsViritu",
                    executables: ["EsViritu"],
                    smokeTest: .command(arguments: ["--help"])
                ),
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "metagenomics",
                    id: "ribodetector",
                    displayName: "RiboDetector",
                    executables: ["ribodetector_cpu"],
                    smokeTest: .command(
                        executable: "ribodetector_cpu",
                        arguments: ["--help"],
                        timeoutSeconds: 10,
                        requiredOutputSubstring: "usage:"
                    )
                ),
            ],
            estimatedSizeMB: 1200
        ),
        PluginPack(
            id: "long-read",
            name: "Long Read Analysis",
            description: "Oxford Nanopore and PacBio long-read alignment, assembly, and polishing",
            sfSymbol: "ruler",
            packages: ["minimap2", "flye", "medaka", "hifiasm", "nanoplot"],
            category: "Long Read",
            estimatedSizeMB: 700
        ),
        PluginPack(
            id: "wastewater-surveillance",
            name: "Wastewater Surveillance",
            description: "SARS-CoV-2 and multi-pathogen lineage de-mixing from wastewater sequencing data",
            sfSymbol: "drop.triangle",
            packages: ["freyja", "ivar", "pangolin", "nextclade", "minimap2"],
            category: "Surveillance",
            isActive: true,
            isExperimental: true,
            requirements: [
                PackToolRequirement.fromManifest(
                    ManagedToolLock.bundled,
                    packID: "wastewater-surveillance",
                    id: "freyja",
                    displayName: "Freyja",
                    executables: ["freyja"],
                    smokeTest: .command(arguments: ["--help"], requiredOutputSubstring: "usage:")
                ),
                PackToolRequirement.package(
                    "ivar",
                    displayName: "iVar",
                    smokeTest: .command(arguments: ["version"])
                ),
                PackToolRequirement.package(
                    "pangolin",
                    displayName: "Pangolin",
                    smokeTest: .command(arguments: ["--version"])
                ),
                PackToolRequirement.package(
                    "nextclade",
                    displayName: "Nextclade",
                    smokeTest: .command(arguments: ["--version"])
                ),
                PackToolRequirement.package(
                    "minimap2",
                    displayName: "minimap2",
                    smokeTest: .command(arguments: ["--version"])
                ),
            ],
            postInstallHooks: [
                PostInstallHook(
                    description: "Download latest SARS-CoV-2 lineage barcodes",
                    environment: "freyja",
                    command: ["freyja", "update"],
                    refreshIntervalDays: 7,
                    estimatedDownloadSize: "~15 MB"
                ),
                PostInstallHook(
                    description: "Update Pango lineage designation data",
                    environment: "pangolin",
                    command: ["pangolin", "--update-data"],
                    refreshIntervalDays: 7,
                    estimatedDownloadSize: "~50 MB"
                ),
            ],
            estimatedSizeMB: 1500
        ),
        PluginPack(
            id: "rna-seq",
            name: "RNA-Seq Analysis",
            description: "Spliced alignment and transcript quantification for bulk RNA sequencing",
            sfSymbol: "bolt.horizontal",
            packages: ["star", "salmon", "subread", "stringtie"],
            category: "Transcriptomics",
            estimatedSizeMB: 600
        ),
        PluginPack(
            id: "single-cell",
            name: "Single-Cell Analysis",
            description: "Preprocessing and analysis of droplet-based single-cell RNA-seq data",
            sfSymbol: "circle.grid.3x3",
            packages: ["scanpy", "scvi-tools", "star"],
            category: "Single Cell",
            estimatedSizeMB: 1800
        ),
        PluginPack(
            id: "amplicon-analysis",
            name: "Amplicon Analysis",
            description: "Primer trimming, variant calling, and consensus generation for tiled-amplicon protocols",
            sfSymbol: "waveform.badge.magnifyingglass",
            packages: ["ivar", "pangolin", "nextclade"],
            category: "Amplicon",
            postInstallHooks: [
                PostInstallHook(
                    description: "Update Pango lineage designation data",
                    environment: "pangolin",
                    command: ["pangolin", "--update-data"],
                    refreshIntervalDays: 7,
                    estimatedDownloadSize: "~50 MB"
                ),
            ],
            estimatedSizeMB: 550
        ),
        PluginPack(
            id: "genome-annotation",
            name: "Genome Annotation",
            description: "Gene prediction and functional annotation for prokaryotic and viral genomes",
            sfSymbol: "tag.fill",
            packages: ["prokka", "bakta", "snpeff"],
            category: "Annotation",
            postInstallHooks: [
                PostInstallHook(
                    description: "Download Bakta light annotation database",
                    environment: "bakta",
                    command: ["bakta_db", "download", "--type", "light"],
                    refreshIntervalDays: 90,
                    estimatedDownloadSize: "~1.3 GB"
                ),
            ],
            estimatedSizeMB: 1200
        ),
        PluginPack(
            id: "data-format-utils",
            name: "Data Format Utilities",
            description: "File conversion, indexing, and interval manipulation for bioinformatics formats",
            sfSymbol: "arrow.triangle.2.circlepath",
            packages: ["bedtools", "picard"],
            category: "Utilities",
            estimatedSizeMB: 650
        ),
    ]

    static var activeOptionalPacks: [PluginPack] {
        activeOptionalPacks(includeExperimental: false)
    }

    static var experimentalOptionalPacks: [PluginPack] {
        builtIn.filter { $0.kind == .optionalTools && $0.isActive && $0.isExperimental }
    }

    static func activeOptionalPacks(includeExperimental: Bool) -> [PluginPack] {
        builtIn.filter {
            $0.kind == .optionalTools
                && $0.isActive
                && (includeExperimental || !$0.isExperimental)
        }
    }

    static var visibleForCLI: [PluginPack] {
        [requiredSetupPack] + activeOptionalPacks
    }

    static func visibleForApp(experimentalFeaturesEnabled: Bool) -> [PluginPack] {
        [requiredSetupPack] + activeOptionalPacks(includeExperimental: experimentalFeaturesEnabled)
    }
}
