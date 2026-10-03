@preconcurrency import Foundation

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
    public let sourceOverlay: PackToolSourceOverlay?
    public let pythonRuntime: ManagedPythonRuntimeSpec?
    public let explicitLock: ManagedCondaExplicitLockSpec?

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
        sourceURL: String? = nil,
        sourceOverlay: PackToolSourceOverlay? = nil,
        pythonRuntime: ManagedPythonRuntimeSpec? = nil,
        explicitLock: ManagedCondaExplicitLockSpec? = nil
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
        self.sourceOverlay = sourceOverlay
        self.pythonRuntime = pythonRuntime
        self.explicitLock = explicitLock
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

public extension PackToolRequirement {
    /// Builds a requirement whose conda spec, version, license, and source URL come from the
    /// dependency manifest. Display metadata, executables, and smoke tests stay in Swift.
    /// When the manifest entry carries a `sourceBuild`, the requirement installs the
    /// build's toolchain packages instead of `packageSpec` and applies the source
    /// overlay on top; the build's version describes what is actually installed, so it
    /// wins over the spec's. Every pin involved lives in the manifest, where the sweep
    /// tooling and the no-literal-pins guard can see it. The manifest entry remains the
    /// reconciler's conda fallback and can carry `preserveExistingInstall`, so a
    /// source-built environment is not clobbered by `tools update`.
    static func fromManifest(
        _ manifest: ManagedToolLock,
        packID: String,
        id: String,
        displayName: String,
        executables: [String],
        fallbackExecutablePaths: [String: [String]] = [:],
        smokeTest: PackToolSmokeTest? = nil
    ) -> PackToolRequirement {
        guard let spec = manifest.packTool(packID: packID, id: id) else {
            // Surface loudly in debug; keep the pack visible but uninstallable in release.
            assertionFailure(PluginPackManifestError.missingPackTool(packID: packID, id: id).description)
            return PackToolRequirement(
                id: id,
                displayName: displayName,
                environment: id,
                installPackages: [],
                executables: executables,
                fallbackExecutablePaths: fallbackExecutablePaths,
                smokeTest: smokeTest
            )
        }
        let overlay: PackToolSourceOverlay?
        do {
            overlay = try spec.requestedSourceOverlay()
            guard overlay == nil || spec.pythonRuntime == nil else {
                throw CondaLockfileError.invalidSpecification(
                    "Pack tool '\(spec.toolID)' cannot combine source and Python runtime overlays."
                )
            }
            try spec.pythonRuntime?.validateRequestedIdentity()
        } catch {
            // Decoded manifests reject this before pack construction. Programmatic
            // invalid manifests keep the pack visible but cannot silently substitute
            // a conda package for an unsupported source build.
            assertionFailure(error.localizedDescription)
            return PackToolRequirement(id: id, displayName: displayName,
                environment: spec.environment, installPackages: [], executables: executables)
        }
        return PackToolRequirement(
            id: id,
            displayName: displayName,
            environment: spec.environment,
            installPackages: spec.pythonRuntime?.basePackageSpecs
                ?? (overlay != nil ? spec.sourceBuild!.toolchainPackages : [spec.packageSpec]),
            executables: executables,
            fallbackExecutablePaths: fallbackExecutablePaths,
            smokeTest: smokeTest,
            version: overlay?.version ?? spec.version,
            license: spec.license,
            sourceURL: spec.sourceUrl,
            sourceOverlay: overlay,
            pythonRuntime: spec.pythonRuntime,
            explicitLock: manifest.explicitLock(packID: packID, toolID: id)
        )
    }
}
