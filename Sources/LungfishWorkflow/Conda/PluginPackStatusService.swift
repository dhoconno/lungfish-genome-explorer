@preconcurrency import Foundation
import LungfishCore
import os.log

private let logger = Logger(
    subsystem: LogSubsystem.workflow,
    category: "PluginPackStatusService"
)

public enum PluginPackState: String, Sendable, Codable, Hashable {
    case ready
    case needsInstall
    case installing
    case failed
}

public struct PackToolStatus: Sendable, Codable, Hashable, Identifiable {
    public let requirement: PackToolRequirement
    public let missingExecutables: [String]

    public var id: String { requirement.id }
    public var isReady: Bool { missingExecutables.isEmpty }
}

public struct PluginPackStatus: Sendable, Codable, Hashable, Identifiable {
    public let pack: PluginPack
    public let state: PluginPackState
    public let toolStatuses: [PackToolStatus]
    public let failureMessage: String?

    public var id: String { pack.id }
}

public protocol PluginPackStatusProviding: Sendable {
    func visibleStatuses() async -> [PluginPackStatus]
    func status(for pack: PluginPack) async -> PluginPackStatus
    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws
}

public actor PluginPackStatusService: PluginPackStatusProviding {
    public typealias InstallAction = @Sendable (
        _ packages: [String],
        _ environment: String,
        _ reinstall: Bool,
        _ progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> Void

    public static let shared = PluginPackStatusService(condaManager: .shared)

    private let condaManager: CondaManager
    private let installAction: InstallAction

    public init(
        condaManager: CondaManager,
        installAction: InstallAction? = nil
    ) {
        self.condaManager = condaManager
        self.installAction = installAction ?? { [condaManager] packages, environment, reinstall, progress in
            if reinstall {
                try await condaManager.reinstall(packages: packages, environment: environment, progress: progress)
            } else {
                try await condaManager.install(packages: packages, environment: environment, progress: progress)
            }
        }
    }

    public func visibleStatuses() async -> [PluginPackStatus] {
        var statuses: [PluginPackStatus] = []
        statuses.reserveCapacity(PluginPack.visibleForCLI.count)
        for pack in PluginPack.visibleForCLI {
            statuses.append(await status(for: pack))
        }
        return statuses
    }

    public func status(for pack: PluginPack) async -> PluginPackStatus {
        var toolStatuses: [PackToolStatus] = []
        toolStatuses.reserveCapacity(pack.toolRequirements.count)

        for requirement in pack.toolRequirements {
            let envURL = await condaManager.environmentURL(named: requirement.environment)
            let binDir = envURL.appendingPathComponent("bin", isDirectory: true)
            let missingExecutables = requirement.executables.filter {
                !FileManager.default.isExecutableFile(atPath: binDir.appendingPathComponent($0).path)
            }
            toolStatuses.append(PackToolStatus(
                requirement: requirement,
                missingExecutables: missingExecutables
            ))
        }

        let bootstrapReady: Bool
        if pack.isRequiredBeforeLaunch {
            let micromambaPath = await condaManager.micromambaPath
            bootstrapReady = FileManager.default.fileExists(atPath: micromambaPath.path)
                && FileManager.default.isExecutableFile(atPath: micromambaPath.path)
        } else {
            bootstrapReady = true
        }

        let state: PluginPackState = toolStatuses.allSatisfy(\.isReady) && bootstrapReady ? .ready : .needsInstall

        return PluginPackStatus(
            pack: pack,
            state: state,
            toolStatuses: toolStatuses,
            failureMessage: nil
        )
    }

    public func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws {
        let installTargets = pack.toolRequirements.map { ($0.installPackages, $0.environment) }
        let totalSteps = max(installTargets.count, 1)
        for (index, target) in installTargets.enumerated() {
            let base = Double(index) / Double(totalSteps)
            try await installAction(target.0, target.1, reinstall) { fraction, message in
                let scaled = base + (fraction / Double(totalSteps))
                progress?(scaled, message)
            }
        }
        await runPostInstallHooks(for: pack)
        progress?(1.0, "\(pack.name) ready")
    }

    private func runPostInstallHooks(for pack: PluginPack) async {
        guard !pack.postInstallHooks.isEmpty else { return }

        for hook in pack.postInstallHooks {
            let envURL = await condaManager.environmentURL(named: hook.environment)
            guard FileManager.default.fileExists(atPath: envURL.path) else {
                logger.warning(
                    "Skipping hook '\(hook.description, privacy: .public)': environment '\(hook.environment, privacy: .public)' not installed"
                )
                continue
            }

            guard let tool = hook.command.first else { continue }
            let arguments = Array(hook.command.dropFirst())
            do {
                _ = try await condaManager.runTool(
                    name: tool,
                    arguments: arguments,
                    environment: hook.environment,
                    timeout: 600
                )
                logger.info(
                    "Hook '\(hook.description, privacy: .public)' completed successfully"
                )
            } catch {
                logger.error(
                    "Hook '\(hook.description, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
