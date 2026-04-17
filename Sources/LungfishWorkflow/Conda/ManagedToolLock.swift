@preconcurrency import Foundation

public struct ManagedToolLock: Sendable, Codable, Hashable {
    public struct ToolSpec: Sendable, Codable, Hashable, Identifiable {
        public let id: String
        public let environment: String
        public let packageSpec: String
        public let executables: [String]

        public init(id: String, environment: String, packageSpec: String, executables: [String]) {
            self.id = id
            self.environment = environment
            self.packageSpec = packageSpec
            self.executables = executables
        }

        public var displayName: String {
            switch id {
            case "nextflow": return "Nextflow"
            case "snakemake": return "Snakemake"
            case "bbtools": return "BBTools"
            case "fastp": return "Fastp"
            case "deacon": return "Deacon"
            case "samtools": return "Samtools"
            case "bcftools": return "BCFtools"
            case "htslib": return "HTSlib"
            case "seqkit": return "SeqKit"
            case "cutadapt": return "Cutadapt"
            case "vsearch": return "VSEARCH"
            case "pigz": return "pigz"
            case "sra-tools": return "SRA Tools"
            case "ucsc-bedtobigbed": return "UCSC bedToBigBed"
            case "ucsc-bedgraphtobigwig": return "UCSC bedGraphToBigWig"
            default:
                return id.replacingOccurrences(of: "-", with: " ").capitalized
            }
        }

        fileprivate var requirement: PackToolRequirement {
            PackToolRequirement(
                id: id,
                displayName: displayName,
                environment: environment,
                installPackages: [packageSpec],
                executables: executables,
                smokeTest: smokeTest
            )
        }

        private var smokeTest: PackToolSmokeTest? {
            switch id {
            case "bbtools":
                return .bbtoolsReformat
            case "nextflow":
                return .command(arguments: ["-version"], timeoutSeconds: 10)
            case "snakemake":
                return .command(arguments: ["--help"], timeoutSeconds: 5)
            case "fastp", "deacon":
                return .command(arguments: ["--help"], timeoutSeconds: 5)
            default:
                return executables.first.map { executable in
                    .command(executable: executable, arguments: ["--help"], timeoutSeconds: 5)
                }
            }
        }
    }

    public struct ManagedDataSpec: Sendable, Codable, Hashable, Identifiable {
        public let id: String
        public let displayName: String

        public init(id: String, displayName: String) {
            self.id = id
            self.displayName = displayName
        }
    }

    public let packID: String
    public let displayName: String
    public let version: String
    public let tools: [ToolSpec]
    public let managedData: [ManagedDataSpec]

    public init(
        packID: String,
        displayName: String,
        version: String,
        tools: [ToolSpec],
        managedData: [ManagedDataSpec]
    ) {
        self.packID = packID
        self.displayName = displayName
        self.version = version
        self.tools = tools
        self.managedData = managedData
    }

    public func tool(named id: String) -> ToolSpec? {
        tools.first(where: { $0.id == id })
    }

    public func managedData(named id: String) -> ManagedDataSpec? {
        managedData.first(where: { $0.id == id })
    }

    public static func loadFromBundle() throws -> ManagedToolLock {
        let url = try resourceURL()
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ManagedToolLock.self, from: data)
    }

    private static func resourceURL() throws -> URL {
        if let url = Bundle.module.url(
            forResource: "third-party-tools-lock",
            withExtension: "json",
            subdirectory: "ManagedTools"
        ) {
            return url
        }

        if let fallback = Bundle.module.resourceURL?
            .appendingPathComponent("ManagedTools")
            .appendingPathComponent("third-party-tools-lock.json"),
           FileManager.default.fileExists(atPath: fallback.path)
        {
            return fallback
        }

        throw NSError(
            domain: "ManagedToolLock",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Managed tool lock manifest not found in workflow resources."]
        )
    }
}

public extension PackToolRequirement {
    static func from(lock: ManagedToolLock) -> [PackToolRequirement] {
        lock.tools.map(\.requirement) + lock.managedData.map {
            .managedDatabase($0.id, displayName: $0.displayName)
        }
    }
}
