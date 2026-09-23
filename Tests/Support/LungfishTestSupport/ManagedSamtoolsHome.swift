import Foundation
import LungfishCore
import LungfishWorkflow

public struct ManagedSamtoolsHome: Sendable {
    public enum HomeError: Error, LocalizedError {
        case samtoolsNotFound

        public var errorDescription: String? {
            switch self {
            case .samtoolsNotFound:
                return "A real samtools executable is required for this test."
            }
        }
    }

    public let homeURL: URL
    public let managedRootURL: URL
    public let samtoolsPath: URL

    public init(homeURL: URL, managedRootURL: URL, samtoolsPath: URL) {
        self.homeURL = homeURL
        self.managedRootURL = managedRootURL
        self.samtoolsPath = samtoolsPath
    }

    public static func makeReal(
        rootURL: URL = FileManager.default.temporaryDirectory,
        appIdentity: LungfishAppIdentity = .current
    ) throws -> ManagedSamtoolsHome {
        guard let realSamtoolsPath = BamFixtureBuilder.locateSamtools() else {
            throw HomeError.samtoolsNotFound
        }

        let fileManager = FileManager.default
        let homeURL = rootURL
            .appendingPathComponent("ManagedSamtoolsHome-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)

        let managedRootURL = ManagedStorageConfigStore(homeDirectory: homeURL, appIdentity: appIdentity)
            .defaultLocation.rootURL
        let samtoolsPath = CoreToolLocator.executableURL(
            environment: "samtools",
            executableName: "samtools",
            homeDirectory: homeURL,
            appIdentity: appIdentity
        )
        try fileManager.createDirectory(
            at: samtoolsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: samtoolsPath.path) {
            try fileManager.removeItem(at: samtoolsPath)
        }
        try fileManager.createSymbolicLink(
            at: samtoolsPath,
            withDestinationURL: URL(fileURLWithPath: realSamtoolsPath)
        )

        return ManagedSamtoolsHome(
            homeURL: homeURL,
            managedRootURL: managedRootURL,
            samtoolsPath: samtoolsPath
        )
    }

    /// Builds a fake home with a stub samtools executable at the managed path
    /// for the given app identity, without requiring a real samtools binary.
    ///
    /// Resolves the samtools path through ``CoreToolLocator`` (the same
    /// resolver production code uses) rather than hard-coding
    /// `.lungfish/conda/...`, so the fixture tracks whichever namespace the
    /// test process's app identity actually resolves to. See TST-04 in
    /// docs/reports/2026-09-23-best-practices-audit/testing-ci.md: tests that
    /// hard-coded `.lungfish` broke when the test process started resolving
    /// the Stable namespace (`.lungfish-stable`).
    ///
    /// - Parameters:
    ///   - script: The shell script contents written to the stub executable.
    ///     Defaults to a no-op success (`exit 0`), matching the common case
    ///     of tests that only assert path resolution.
    public static func makeStub(
        rootURL: URL = FileManager.default.temporaryDirectory,
        namePrefix: String = "ManagedSamtoolsHome",
        appIdentity: LungfishAppIdentity = .current,
        script: String = "#!/bin/sh\nexit 0\n"
    ) throws -> ManagedSamtoolsHome {
        let fileManager = FileManager.default
        let homeURL = rootURL
            .appendingPathComponent("\(namePrefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)

        let managedRootURL = ManagedStorageConfigStore(homeDirectory: homeURL, appIdentity: appIdentity)
            .defaultLocation.rootURL
        let samtoolsPath = CoreToolLocator.executableURL(
            environment: "samtools",
            executableName: "samtools",
            homeDirectory: homeURL,
            appIdentity: appIdentity
        )
        try fileManager.createDirectory(
            at: samtoolsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try script.write(to: samtoolsPath, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtoolsPath.path)

        return ManagedSamtoolsHome(
            homeURL: homeURL,
            managedRootURL: managedRootURL,
            samtoolsPath: samtoolsPath
        )
    }
}
