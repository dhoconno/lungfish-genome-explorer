@preconcurrency import Foundation

public enum PluginPackKind: String, Sendable, Codable, Hashable {
    case requiredSetup
    case optionalTools
}

public struct PackToolSmokeTest: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case command
        case bbtoolsReformat
    }

    public let kind: Kind
    public let executable: String?
    public let arguments: [String]
    public let timeoutSeconds: Double
    public let acceptedExitCodes: [Int32]
    public let requiredOutputSubstring: String?

    public init(
        kind: Kind,
        executable: String? = nil,
        arguments: [String] = [],
        timeoutSeconds: Double = 30,
        acceptedExitCodes: [Int32] = [0],
        requiredOutputSubstring: String? = nil
    ) {
        self.kind = kind
        self.executable = executable
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
        self.acceptedExitCodes = acceptedExitCodes
        self.requiredOutputSubstring = requiredOutputSubstring
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case executable
        case arguments
        case timeoutSeconds
        case acceptedExitCodes
        case requiredOutputSubstring
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(Kind.self, forKey: .kind)
        self.executable = try container.decodeIfPresent(String.self, forKey: .executable)
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 30
        self.acceptedExitCodes = try container.decodeIfPresent([Int32].self, forKey: .acceptedExitCodes) ?? [0]
        self.requiredOutputSubstring = try container.decodeIfPresent(String.self, forKey: .requiredOutputSubstring)
    }

    public static func command(
        executable: String? = nil,
        arguments: [String],
        timeoutSeconds: Double = 30,
        acceptedExitCodes: [Int32] = [0],
        requiredOutputSubstring: String? = nil
    ) -> PackToolSmokeTest {
        PackToolSmokeTest(
            kind: .command,
            executable: executable,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            acceptedExitCodes: acceptedExitCodes,
            requiredOutputSubstring: requiredOutputSubstring
        )
    }

    public static func usage(
        executable: String? = nil,
        timeoutSeconds: Double = 30,
        acceptedExitCodes: [Int32] = [255],
        requiredOutputSubstring: String = "usage:"
    ) -> PackToolSmokeTest {
        PackToolSmokeTest(
            kind: .command,
            executable: executable,
            arguments: [],
            timeoutSeconds: timeoutSeconds,
            acceptedExitCodes: acceptedExitCodes,
            requiredOutputSubstring: requiredOutputSubstring
        )
    }

    public static let bbtoolsReformat = PackToolSmokeTest(
        kind: .bbtoolsReformat,
        executable: "reformat.sh",
        timeoutSeconds: 30
    )
}

public struct PackToolRequirement: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let environment: String
    public let installPackages: [String]
    public let executables: [String]
    public let fallbackExecutablePaths: [String: [String]]
    public let smokeTest: PackToolSmokeTest?
    public let managedDatabaseID: String?
    public let version: String?
    public let license: String?
    public let sourceURL: String?

    public init(
        id: String,
        displayName: String,
        environment: String,
        installPackages: [String]? = nil,
        executables: [String],
        fallbackExecutablePaths: [String: [String]] = [:],
        smokeTest: PackToolSmokeTest? = nil,
        managedDatabaseID: String? = nil,
        version: String? = nil,
        license: String? = nil,
        sourceURL: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.environment = environment
        self.installPackages = installPackages ?? [id]
        self.executables = executables
        self.fallbackExecutablePaths = fallbackExecutablePaths
        self.smokeTest = smokeTest
        self.managedDatabaseID = managedDatabaseID
        self.version = version
        self.license = license
        self.sourceURL = sourceURL
    }

    public static func package(
        _ name: String,
        displayName: String? = nil,
        executableName: String? = nil,
        smokeTest: PackToolSmokeTest? = nil
    ) -> PackToolRequirement {
        PackToolRequirement(
            id: name,
            displayName: displayName ?? name.capitalized,
            environment: name,
            executables: [executableName ?? name],
            smokeTest: smokeTest
        )
    }

    public static func managedDatabase(
        _ databaseID: String,
        displayName: String
    ) -> PackToolRequirement {
        PackToolRequirement(
            id: databaseID,
            displayName: displayName,
            environment: databaseID,
            installPackages: [],
            executables: [],
            managedDatabaseID: databaseID
        )
    }

    public static let bbtools = PackToolRequirement(
        id: "bbtools",
        displayName: "BBTools",
        environment: "bbtools",
        installPackages: ["bbmap"],
        executables: [
            "clumpify.sh", "bbduk.sh", "bbmerge.sh",
            "repair.sh", "tadpole.sh", "reformat.sh", "bbmap.sh", "mapPacBio.sh", "java",
        ],
        fallbackExecutablePaths: [
            "java": ["lib/jvm/bin/java"],
        ],
        smokeTest: .bbtoolsReformat
    )
}

public struct PostInstallHook: Sendable, Codable, Hashable {
    public let description: String
    public let environment: String
    public let command: [String]
    public let requiresNetwork: Bool
    public let refreshIntervalDays: Int?
    public let estimatedDownloadSize: String?

    public init(
        description: String,
        environment: String,
        command: [String],
        requiresNetwork: Bool = true,
        refreshIntervalDays: Int? = nil,
        estimatedDownloadSize: String? = nil
    ) {
        self.description = description
        self.environment = environment
        self.command = command
        self.requiresNetwork = requiresNetwork
        self.refreshIntervalDays = refreshIntervalDays
        self.estimatedDownloadSize = estimatedDownloadSize
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
        self.requirements = requirements
        self.postInstallHooks = postInstallHooks
        self.estimatedSizeMB = estimatedSizeMB
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

    static let requiredSetupPack: PluginPack = {
        let lock = try! ManagedToolLock.loadFromBundle()
        return PluginPack(
            id: lock.packID,
            name: lock.displayName,
            description: "Needed before you can create or open a project",
            sfSymbol: "checklist",
            packages: lock.tools.map(\.environment),
            category: "Required Setup",
            kind: .requiredSetup,
            isActive: true,
            requirements: PackToolRequirement.from(lock: lock),
            estimatedSizeMB: 2600
        )
    }()

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
                PackToolRequirement(
                    id: "minimap2",
                    displayName: "minimap2",
                    environment: "minimap2",
                    installPackages: ["bioconda::minimap2=2.30"],
                    executables: ["minimap2"],
                    smokeTest: .command(
                        executable: "minimap2",
                        arguments: ["--help"],
                        timeoutSeconds: 10,
                        acceptedExitCodes: [0, 1],
                        requiredOutputSubstring: "Usage"
                    ),
                    version: "2.30",
                    license: "MIT",
                    sourceURL: "https://github.com/lh3/minimap2"
                ),
                PackToolRequirement(
                    id: "bwa-mem2",
                    displayName: "BWA-MEM2",
                    environment: "bwa-mem2",
                    installPackages: ["bioconda::bwa-mem2=2.3"],
                    executables: ["bwa-mem2"],
                    smokeTest: .command(
                        executable: "bwa-mem2",
                        arguments: [],
                        timeoutSeconds: 10,
                        acceptedExitCodes: [1],
                        requiredOutputSubstring: "Usage: bwa-mem2"
                    ),
                    version: "2.3",
                    license: "MIT",
                    sourceURL: "https://github.com/bwa-mem2/bwa-mem2"
                ),
                PackToolRequirement(
                    id: "bowtie2",
                    displayName: "Bowtie2",
                    environment: "bowtie2",
                    installPackages: ["bioconda::bowtie2=2.5.4"],
                    executables: ["bowtie2", "bowtie2-build"],
                    smokeTest: .command(
                        executable: "bowtie2",
                        arguments: ["--help"],
                        timeoutSeconds: 10,
                        acceptedExitCodes: [0, 1],
                        requiredOutputSubstring: "bowtie2"
                    ),
                    version: "2.5.4",
                    license: "GPL-3.0",
                    sourceURL: "https://bowtie-bio.sourceforge.net/bowtie2/manual.shtml"
                ),
            ],
            estimatedSizeMB: 260
        ),
        PluginPack(
            id: "variant-calling",
            name: "Variant Calling",
            description: "Viral BAM variant calling from bundle-owned alignment tracks",
            sfSymbol: "diamond.fill",
            packages: ["lofreq", "ivar", "medaka"],
            category: "Variant Calling",
            isActive: true,
            requirements: [
                PackToolRequirement(
                    id: "lofreq",
                    displayName: "LoFreq",
                    environment: "lofreq",
                    installPackages: ["bioconda::lofreq=2.1.5"],
                    executables: ["lofreq"],
                    smokeTest: .command(
                        arguments: ["version"],
                        requiredOutputSubstring: "version:"
                    ),
                    version: "2.1.5",
                    license: "MIT",
                    sourceURL: "https://csb5.github.io/lofreq/"
                ),
                PackToolRequirement(
                    id: "ivar",
                    displayName: "iVar",
                    environment: "ivar",
                    installPackages: ["bioconda::ivar=1.4.4"],
                    executables: ["ivar"],
                    smokeTest: .command(arguments: ["version"]),
                    version: "1.4.4",
                    license: "GPL-3.0-or-later",
                    sourceURL: "https://andersen-lab.github.io/ivar/html/"
                ),
                PackToolRequirement(
                    id: "medaka",
                    displayName: "Medaka",
                    environment: "medaka",
                    installPackages: ["bioconda::medaka=2.1.1"],
                    executables: ["medaka"],
                    smokeTest: .command(arguments: ["--help"]),
                    version: "2.1.1",
                    license: "MPL-2.0",
                    sourceURL: "https://github.com/nanoporetech/medaka"
                ),
            ],
            estimatedSizeMB: 260
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
                PackToolRequirement(
                    id: "spades",
                    displayName: "SPAdes",
                    environment: "spades",
                    installPackages: ["bioconda::spades=4.2.0"],
                    executables: ["spades.py"],
                    smokeTest: .command(executable: "spades.py", arguments: ["--version"], timeoutSeconds: 10),
                    version: "4.2.0",
                    license: "GPL-2.0-only",
                    sourceURL: "https://github.com/ablab/spades"
                ),
                PackToolRequirement(
                    id: "megahit",
                    displayName: "MEGAHIT",
                    environment: "megahit",
                    installPackages: ["bioconda::megahit=1.2.9"],
                    executables: ["megahit"],
                    smokeTest: .command(executable: "megahit", arguments: ["--help"], timeoutSeconds: 10),
                    version: "1.2.9",
                    license: "GPL-3.0",
                    sourceURL: "https://github.com/voutcn/megahit"
                ),
                PackToolRequirement(
                    id: "skesa",
                    displayName: "SKESA",
                    environment: "skesa",
                    installPackages: ["bioconda::skesa=2.5.1"],
                    executables: ["skesa"],
                    smokeTest: .command(executable: "skesa", arguments: ["--help"], timeoutSeconds: 10),
                    version: "2.5.1",
                    license: "Public Domain",
                    sourceURL: "https://github.com/ncbi/SKESA"
                ),
                PackToolRequirement(
                    id: "flye",
                    displayName: "Flye",
                    environment: "flye",
                    installPackages: ["bioconda::flye=2.9.6"],
                    executables: ["flye"],
                    smokeTest: .command(executable: "flye", arguments: ["--help"], timeoutSeconds: 10),
                    version: "2.9.6",
                    license: "BSD",
                    sourceURL: "https://github.com/mikolmogorov/Flye"
                ),
                PackToolRequirement(
                    id: "hifiasm",
                    displayName: "hifiasm",
                    environment: "hifiasm",
                    installPackages: ["bioconda::hifiasm=0.25.0"],
                    executables: ["hifiasm"],
                    smokeTest: .command(executable: "hifiasm", arguments: ["-h"], timeoutSeconds: 10),
                    version: "0.25.0",
                    license: "MIT",
                    sourceURL: "https://github.com/chhylp123/hifiasm"
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
                PackToolRequirement(
                    id: "mafft",
                    displayName: "MAFFT",
                    environment: "mafft",
                    installPackages: ["conda-forge::mafft=7.526"],
                    executables: ["mafft"],
                    smokeTest: .command(
                        executable: "mafft",
                        arguments: ["--help"],
                        timeoutSeconds: 10,
                        acceptedExitCodes: [0, 1],
                        requiredOutputSubstring: "MAFFT"
                    ),
                    version: "7.526",
                    license: "BSD-3-Clause",
                    sourceURL: "https://mafft.cbrc.jp/alignment/software/"
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
                PackToolRequirement(
                    id: "iqtree",
                    displayName: "IQ-TREE",
                    environment: "iqtree",
                    installPackages: ["bioconda::iqtree=3.1.1"],
                    executables: ["iqtree3"],
                    smokeTest: .command(
                        executable: "iqtree3",
                        arguments: ["--help"],
                        timeoutSeconds: 10,
                        requiredOutputSubstring: "IQ-TREE"
                    ),
                    version: "3.1.1",
                    license: "GPL-2.0-or-later",
                    sourceURL: "https://github.com/iqtree/iqtree3"
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
                PackToolRequirement(
                    id: "kraken2",
                    displayName: "Kraken 2",
                    environment: "kraken2",
                    installPackages: ["bioconda::kraken2=2.17.1"],
                    executables: ["kraken2"],
                    smokeTest: .command(arguments: ["--version"]),
                    version: "2.17.1",
                    license: "GPL-3.0-or-later",
                    sourceURL: "https://github.com/DerrickWood/kraken2"
                ),
                PackToolRequirement(
                    id: "bracken",
                    displayName: "Bracken",
                    environment: "bracken",
                    installPackages: ["bioconda::bracken=1.0.0"],
                    executables: ["bracken"],
                    smokeTest: .command(arguments: ["--help"]),
                    version: "1.0.0",
                    license: "GPL-3.0",
                    sourceURL: "https://github.com/jenniferlu717/Bracken"
                ),
                PackToolRequirement(
                    id: "esviritu",
                    displayName: "EsViritu",
                    environment: "esviritu",
                    installPackages: ["bioconda::esviritu=1.2.0"],
                    executables: ["EsViritu"],
                    smokeTest: .command(arguments: ["--help"]),
                    version: "1.2.0",
                    license: "MIT",
                    sourceURL: "https://github.com/cmmr/EsViritu"
                ),
                PackToolRequirement(
                    id: "ribodetector",
                    displayName: "RiboDetector",
                    environment: "ribodetector",
                    installPackages: ["bioconda::ribodetector=0.3.3"],
                    executables: ["ribodetector_cpu"],
                    smokeTest: .command(
                        executable: "ribodetector_cpu",
                        arguments: ["--help"],
                        timeoutSeconds: 10,
                        requiredOutputSubstring: "usage:"
                    ),
                    version: "0.3.3",
                    license: "GPL-3.0-or-later",
                    sourceURL: "https://github.com/hzi-bifo/RiboDetector"
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
        builtIn.filter { $0.kind == .optionalTools && $0.isActive }
    }

    static var visibleForCLI: [PluginPack] {
        [requiredSetupPack] + activeOptionalPacks
    }
}
