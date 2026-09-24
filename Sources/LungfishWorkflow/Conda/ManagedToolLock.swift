@preconcurrency import Foundation
import CryptoKit
import LungfishCore

public struct ManagedCondaExplicitLockSpec: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(packID)/\(toolID)" }
    public let packID: String
    public let toolID: String
    public let platform: String
    public let resource: String
    public let sha256: String

    enum CodingKeys: String, CodingKey {
        case packID, toolID = "id", platform, resource, sha256
    }

    public init(packID: String, toolID: String, platform: String, resource: String, sha256: String) {
        self.packID = packID
        self.toolID = toolID
        self.platform = platform
        self.resource = resource
        self.sha256 = sha256.lowercased()
    }

    func validateIdentity() throws {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !packID.isEmpty, !toolID.isEmpty, platform == "osx-arm64",
              resource == URL(fileURLWithPath: resource).lastPathComponent,
              resource.hasSuffix("-osx-arm64-explicit.txt"),
              resource.unicodeScalars.allSatisfy(safe.contains),
              sha256.count == 64, sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw CondaLockfileError.invalidSpecification(
                "Explicit conda lock requires a safe bundled osx-arm64 resource and SHA-256.")
        }
    }

    func validatedResourceURL() throws -> URL {
        try validateIdentity()
        let url: URL
        if let bundled = RuntimeResourceLocator.path("ManagedTools/\(resource)", in: .workflow) {
            url = bundled
        } else {
            #if DEBUG
            let source = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/ManagedTools/\(resource)")
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw CondaLockfileError.invalidSpecification(
                    "Bundled explicit conda lock is missing: \(resource)")
            }
            url = source
            #else
            throw CondaLockfileError.invalidSpecification(
                "Bundled explicit conda lock is missing: \(resource)")
            #endif
        }
        let data = try Data(contentsOf: url)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == sha256 else {
            throw CondaLockfileError.invalidSpecification(
                "Explicit conda lock \(resource) checksum is \(actual), expected \(sha256).")
        }
        try validateContents(data)
        return url
    }

    func validateContents(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CondaLockfileError.invalidSpecification(
                "Explicit conda lock \(resource) is not UTF-8 text.")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.contains("@EXPLICIT") else {
            throw CondaLockfileError.invalidSpecification(
                "Explicit conda lock \(resource) is missing @EXPLICIT.")
        }
        let packageLines = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") && $0 != "@EXPLICIT" }
        guard !packageLines.isEmpty else {
            throw CondaLockfileError.invalidSpecification(
                "Explicit conda lock \(resource) has no captured package URLs.")
        }
        for line in packageLines {
            guard !line.localizedCaseInsensitiveContains("%2e"),
                  let url = URL(string: line),
                  url.scheme == "https", url.host == "conda.anaconda.org", url.port == nil,
                  url.user == nil, url.password == nil, url.query == nil,
                  !url.pathComponents.contains(".."),
                  url.path.hasSuffix(".conda") || url.path.hasSuffix(".tar.bz2"),
                  let digest = url.fragment,
                  [32, 64].contains(digest.count),
                  digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw CondaLockfileError.invalidSpecification(
                    "Explicit conda lock \(resource) contains an unsafe or unhashed package URL.")
            }
        }
    }
}

public struct ManagedToolLock: Sendable, Codable, Hashable {
    public struct ToolSpec: Sendable, Codable, Hashable, Identifiable {
        public let id: String
        public let environment: String
        public let packageSpec: String
        public let executables: [String]
        public let version: String?
        public let license: String?
        public let sourceUrl: String?

        public init(
            id: String,
            environment: String,
            packageSpec: String,
            executables: [String],
            version: String? = nil,
            license: String? = nil,
            sourceUrl: String? = nil
        ) {
            self.id = id
            self.environment = environment
            self.packageSpec = packageSpec
            self.executables = executables
            self.version = version
            self.license = license
            self.sourceUrl = sourceUrl
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
            case "blast": return "NCBI BLAST+"
            case "savont": return "Savont"
            case "pigz": return "pigz"
            case "sra-tools": return "SRA Tools"
            case "ucsc-bedgraphtobigwig": return "UCSC bedGraphToBigWig"
            case "pysam": return "pysam"
            case "openpyxl": return "openpyxl"
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
                fallbackExecutablePaths: fallbackExecutablePaths,
                smokeTest: smokeTest,
                version: version,
                license: license,
                sourceURL: sourceUrl
            )
        }

        private var fallbackExecutablePaths: [String: [String]] {
            switch id {
            case "bbtools":
                return ["java": ["lib/jvm/bin/java"]]
            default:
                return [:]
            }
        }

        private var smokeTest: PackToolSmokeTest? {
            switch id {
            case "bbtools":
                return .bbtoolsReformat
            case "nextflow":
                return .command(arguments: ["-version"], timeoutSeconds: 10)
            case "snakemake":
                return .command(arguments: ["--version"], timeoutSeconds: 15)
            case "bcftools", "samtools", "htslib":
                return .command(arguments: ["--version"], timeoutSeconds: 10)
            case "seqkit":
                return .command(
                    arguments: ["sample2", "--help"],
                    timeoutSeconds: 10,
                    requiredOutputSubstring: "sample sequences by number or proportion"
                )
            case "fastp", "deacon":
                return .command(arguments: ["--help"], timeoutSeconds: 10)
            case "savont":
                return .command(
                    arguments: ["--help"],
                    timeoutSeconds: 10,
                    requiredOutputSubstring: "Turn >~ 98% accuracy long reads into ASVs"
                )
            case "blast":
                return .command(
                    executable: "blastn",
                    arguments: ["-help"],
                    timeoutSeconds: 10,
                    requiredOutputSubstring: "Nucleotide-Nucleotide BLAST"
                )
            case "ucsc-bedgraphtobigwig":
                return .usage(executable: executables.first, timeoutSeconds: 10)
            case "pysam":
                return .command(
                    executable: "python",
                    arguments: ["-c", "import pysam; print(pysam.__version__)"],
                    timeoutSeconds: 10,
                    requiredOutputSubstring: "0.24.0"
                )
            case "openpyxl":
                return .command(
                    executable: "python",
                    arguments: ["-c", "import openpyxl; print(openpyxl.__version__)"],
                    timeoutSeconds: 10,
                    requiredOutputSubstring: "3.1.5"
                )
            default:
                return executables.first.map { executable in
                    .command(executable: executable, arguments: ["--help"], timeoutSeconds: 10)
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
    public let dependencySet: String?
    public let dependencySetDate: String?
    public let packTools: [PackToolSpec]
    public let pipelines: [PipelineSpec]
    public let databases: [DatabaseSpec]
    public let bootstrap: BootstrapSpec?
    public let explicitLocks: [ManagedCondaExplicitLockSpec]
    /// Environment names this manifest has explicitly dropped, so reconciliation may remove them.
    ///
    /// Absence from `tools`/`packTools` is NOT enough to retire an environment: the user's conda
    /// root also holds envs Lungfish never created. The sweep tooling appends a name here when a
    /// tool is dropped from the manifest, which is what licenses its removal.
    public let retiredEnvironments: [String]

    public init(
        packID: String,
        displayName: String,
        version: String,
        tools: [ToolSpec],
        managedData: [ManagedDataSpec],
        dependencySet: String? = nil,
        dependencySetDate: String? = nil,
        packTools: [PackToolSpec] = [],
        pipelines: [PipelineSpec] = [],
        databases: [DatabaseSpec] = [],
        bootstrap: BootstrapSpec? = nil,
        explicitLocks: [ManagedCondaExplicitLockSpec] = [],
        retiredEnvironments: [String] = []
    ) {
        self.packID = packID
        self.displayName = displayName
        self.version = version
        self.tools = tools
        self.managedData = managedData
        self.dependencySet = dependencySet
        self.dependencySetDate = dependencySetDate
        self.packTools = packTools
        self.pipelines = pipelines
        self.databases = databases
        self.bootstrap = bootstrap
        self.explicitLocks = explicitLocks
        self.retiredEnvironments = retiredEnvironments
    }

    enum CodingKeys: String, CodingKey {
        case packID, displayName, version, tools, managedData
        case dependencySet, dependencySetDate, packTools, pipelines, databases, bootstrap, explicitLocks
        case retiredEnvironments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packID = try c.decode(String.self, forKey: .packID)
        displayName = try c.decode(String.self, forKey: .displayName)
        version = try c.decode(String.self, forKey: .version)
        tools = try c.decode([ToolSpec].self, forKey: .tools)
        managedData = try c.decodeIfPresent([ManagedDataSpec].self, forKey: .managedData) ?? []
        dependencySet = try c.decodeIfPresent(String.self, forKey: .dependencySet)
        dependencySetDate = try c.decodeIfPresent(String.self, forKey: .dependencySetDate)
        packTools = try c.decodeIfPresent([PackToolSpec].self, forKey: .packTools) ?? []
        pipelines = try c.decodeIfPresent([PipelineSpec].self, forKey: .pipelines) ?? []
        databases = try c.decodeIfPresent([DatabaseSpec].self, forKey: .databases) ?? []
        bootstrap = try c.decodeIfPresent(BootstrapSpec.self, forKey: .bootstrap)
        explicitLocks = try c.decodeIfPresent([ManagedCondaExplicitLockSpec].self, forKey: .explicitLocks) ?? []
        retiredEnvironments = try c.decodeIfPresent([String].self, forKey: .retiredEnvironments) ?? []
        for tool in packTools {
            let sourceOverlay = try tool.requestedSourceOverlay()
            guard sourceOverlay == nil || tool.pythonRuntime == nil else {
                throw CondaLockfileError.invalidSpecification(
                    "Pack tool '\(tool.toolID)' cannot combine source and Python runtime overlays."
                )
            }
            try tool.pythonRuntime?.validateRequestedIdentity()
        }
        for database in databases { try database.validateSourceIdentity() }
        guard Set(explicitLocks.map(\.id)).count == explicitLocks.count else {
            throw CondaLockfileError.invalidSpecification("Explicit conda lock identities must be unique.")
        }
        for lock in explicitLocks {
            try lock.validateIdentity()
            guard packTools.contains(where: { $0.packID == lock.packID && $0.toolID == lock.toolID }) else {
                throw CondaLockfileError.invalidSpecification(
                    "Explicit conda lock '\(lock.id)' has no matching pack tool.")
            }
        }
    }

    public func tool(named id: String) -> ToolSpec? {
        tools.first(where: { $0.id == id })
    }

    public func managedData(named id: String) -> ManagedDataSpec? {
        managedData.first(where: { $0.id == id })
    }

    public func explicitLock(packID: String, toolID: String) -> ManagedCondaExplicitLockSpec? {
        explicitLocks.first { $0.packID == packID && $0.toolID == toolID }
    }

    public static func loadFromBundle() throws -> ManagedToolLock {
        let url = try resourceURL()
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ManagedToolLock.self, from: data)
    }

    private static func resourceURL() throws -> URL {
        if let url = RuntimeResourceLocator.path(
            "ManagedTools/third-party-tools-lock.json",
            in: .workflow
        ) {
            return url
        }
        #if DEBUG
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ManagedTools/third-party-tools-lock.json")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        #endif

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
