// LiveNextflowRun.swift - One live Nextflow run: its root, key, folders, archive input and teardown
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner direction O5 (Phase 2.9). The shared helper of every live Nextflow class (S10's container
// cleanup class, U10's progress class, Q1b's parity class). A live class calls `begin()` in its
// test, or in `setUp`, and `teardown()` in `tearDown`. `begin()`
//
//   1. asks LiveNextflowSwitch whether the class runs, and with which managed root,
//   2. gates the root, the managed Nextflow in it and a Docker that answers `docker info` within
//      30 s through ToolAvailability, so a Mac without them skips and LUNGFISH_REQUIRE_TOOLS=1 fails,
//   3. gives the run a key and a folder made by TestTempDirectory. The key is in the folder name, so
//      `ps` finds the run's processes by it, and the work folder is the run's own.
//
// `installDemoProject` copies the input out of a demo archive into that folder, so a run never reads
// or writes the cache. `teardown()` removes the containers whose mounts hold the run's work folder,
// or the work folder of an engine the class names with `engineWorkFolders`, and then the run's
// folder. It touches no other container. Nothing here starts Docker Desktop.

import Foundation
import LungfishCore
import LungfishWorkflow
import XCTest

/// A live class that cannot run for a reason no skip should hide.
public enum LiveNextflowError: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    /// A switch is set and cannot be honoured, or a fixed fact of the repository is wrong.
    case misconfigured(String)
    /// The Mac lacks something the class needs. `ToolAvailability` turns this into a skip or a failure.
    case unavailable(String)

    public var description: String {
        switch self {
        case .misconfigured(let message), .unavailable(let message): message
        }
    }

    public var errorDescription: String? { description }
}

/// One live run, from its switch to its teardown.
public final class LiveNextflowRun: Sendable {
    /// A live run gets 10 minutes, about twice the slowest warm run of one sample in the Q15 evidence.
    public static let runTimeout: TimeInterval = 600

    /// `<key>` is in the name of the run's folder, so `ps` finds the run's processes by it.
    public let key: String
    /// The managed root the run uses, from `LUNGFISH_LIVE_NEXTFLOW_ROOT` or `LUNGFISH_STORAGE_ROOT`.
    public let root: URL
    public let source: LiveNextflowSwitch.Source
    /// The run's own folder, made by `TestTempDirectory`.
    public let directory: URL
    public let docker: LiveNextflowDocker
    private let environment: [String: String]

    /// The work folder of an engine the class launches itself with -w. A TaxTriage launch picks its own, see ownedContainers.
    public var workDirectory: URL { directory.appendingPathComponent("work", isDirectory: true) }
    public var outputDirectory: URL { directory.appendingPathComponent("output", isDirectory: true) }
    /// Where `installDemoProject` puts the input.
    public var inputDirectory: URL { directory.appendingPathComponent("inputs", isDirectory: true) }

    private init(
        key: String,
        root: URL,
        source: LiveNextflowSwitch.Source,
        directory: URL,
        docker: LiveNextflowDocker,
        environment: [String: String]
    ) {
        self.key = key
        self.root = root
        self.source = source
        self.directory = directory
        self.docker = docker
        self.environment = environment
    }

    // MARK: - Beginning a run

    /// Starts a live run, or skips the test, or fails it.
    ///
    /// - Parameters:
    ///   - environment: The switch and the archive folder. The process environment by default. A unit
    ///     test passes a dictionary.
    ///   - docker: A client in place of the installed `docker`, for a unit test.
    public static func begin(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        docker: LiveNextflowDocker? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> LiveNextflowRun {
        let root: URL
        let source: LiveNextflowSwitch.Source
        switch LiveNextflowSwitch.decide(environment: environment) {
        case .skip(let reason):
            throw XCTSkip(reason, file: file, line: line)
        case .misconfigured(let reason):
            throw LiveNextflowError.misconfigured(reason)
        case .run(let decidedRoot, let decidedSource):
            root = decidedRoot
            source = decidedSource
        }
        if let problem = rootProblem(root, source: source) {
            try ToolAvailability.skipOrFail(problem, file: file, line: line)
        }
        if let problem = nextflowProblem(in: root) {
            try ToolAvailability.skipOrFail(problem, file: file, line: line)
        }
        let client: LiveNextflowDocker
        if let docker {
            client = docker
        } else if let executable = LiveNextflowDocker.locateExecutable() {
            client = .system(executable: executable)
        } else {
            try ToolAvailability.skipOrFail("docker is not installed on this Mac.", file: file, line: line)
        }
        if let problem = client.probe().problem {
            try ToolAvailability.skipOrFail(problem, file: file, line: line)
        }
        let key = makeKey()
        let directory = try TestTempDirectory.make(prefix: key)
        return LiveNextflowRun(
            key: key,
            root: root,
            source: source,
            directory: directory,
            docker: client,
            environment: environment
        )
    }

    /// `live-` and eight hex digits.
    public static func makeKey() -> String {
        "live-" + String(UUID().uuidString.lowercased().prefix(8))
    }

    /// Why `root` cannot be a managed root for a child process, or nil.
    ///
    /// The CLI reads the root from `LUNGFISH_STORAGE_ROOT` and ignores one that has a space, so a root
    /// with a space would quietly send the run to another root. `ManagedStorageLocation.validateSelection`
    /// checks the same and also writes a probe file, which a live run must not do in the Stable root.
    public static func rootProblem(_ root: URL, source: LiveNextflowSwitch.Source) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "\(source.variable) names \(root.path), which is not a folder."
        }
        if root.path.firstIndex(of: " ") != nil {
            return "\(source.variable) names \(root.path), which has a space. "
                + "The CLI ignores a storage root with a space and would use another root."
        }
        return nil
    }

    /// The managed Nextflow of `root`.
    public static func nextflowExecutable(in root: URL) -> URL {
        ManagedStorageLocation(rootURL: root).condaRootURL.appendingPathComponent("envs/nextflow/bin/nextflow")
    }

    /// Why `root` holds no managed Nextflow, or nil.
    public static func nextflowProblem(in root: URL) -> String? {
        let executable = nextflowExecutable(in: root)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return "Nextflow is not installed in the managed root \(root.path). Expected \(executable.path)."
        }
        return nil
    }

    // MARK: - The root for the engine

    /// The environment for a `lungfish-cli` subprocess so that it resolves the managed tools from this
    /// run's root, whatever `LUNGFISH_STORAGE_ROOT` says in this process.
    public func childEnvironment(base: [String: String]? = nil) -> [String: String] {
        var result = base ?? ProcessInfo.processInfo.environment
        result[LiveNextflowSwitch.storageRootVariable] = root.path
        result["LUNGFISH_CONDA_ROOT"] = ManagedStorageLocation(rootURL: root).condaRootURL.path
        return result
    }

    /// Why an engine started in this process would use another root than the run's, or nil.
    ///
    /// An in-process launch resolves the managed tools from this process's own environment. A live class
    /// that starts the engine in process (not through the CLI) skips on a difference and fails under
    /// LUNGFISH_REQUIRE_TOOLS=1, through `requireProcessRoot()`.
    public func processRootProblem(
        processRoot: URL = ManagedStorageConfigStore().currentLocation().rootURL
    ) -> String? {
        let live = root.standardizedFileURL.path
        let process = processRoot.standardizedFileURL.path
        guard live != process else { return nil }
        return "An engine started in this process resolves its managed tools from \(process), "
            + "but the live root is \(live). Set \(LiveNextflowSwitch.storageRootVariable) to the live root, "
            + "or start the engine through the CLI with childEnvironment()."
    }

    public func requireProcessRoot(file: StaticString = #filePath, line: UInt = #line) throws {
        if let problem = processRootProblem() {
            try ToolAvailability.skipOrFail(problem, file: file, line: line)
        }
    }

    // MARK: - The archive input

    /// The archive the catalogue names for `project`, in `folder`.
    public static func locateArchive(for project: DemoProject, in folder: URL?) throws -> URL {
        let name = project.archive.url.lastPathComponent
        guard let folder else {
            throw LiveNextflowError.unavailable(
                "Set \(LiveNextflowSwitch.archiveFolderVariable) to the folder that holds \(name)."
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LiveNextflowError.unavailable("The demo archive folder \(folder.path) is not a folder.")
        }
        let archive = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw LiveNextflowError.unavailable("\(folder.path) holds no \(name), the archive of the \(project.title) demo.")
        }
        return archive
    }

    /// The catalogue entry of a demo project in the bundled catalogue.
    public static func demoProject(id: String) throws -> DemoProject {
        let catalogue = try DemoProjectManifest.loadBundled()
        guard let project = catalogue.projects.first(where: { $0.id == id }) else {
            throw LiveNextflowError.misconfigured("The bundled demo catalogue lists no project \"\(id)\".")
        }
        return project
    }

    /// Copies a demo project out of its archive into `inputDirectory` with the real installer, which
    /// checks the archive's size and SHA-256 first. The archive in the folder is read and never changed.
    ///
    /// - Parameter archiveFolder: The folder that holds the archive under the catalogue's file name.
    ///   `LUNGFISH_DEMO_ARCHIVE_DIR` by default. A missing folder, a missing archive and an archive that
    ///   does not match the catalogue go to `ToolAvailability.skipOrFail`.
    /// - Returns: The installed project folder.
    public func installDemoProject(
        _ project: DemoProject,
        from archiveFolder: URL? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> URL {
        let folder = archiveFolder ?? configuredArchiveFolder()
        let archive: URL
        do {
            archive = try Self.locateArchive(for: project, in: folder)
        } catch let error as LiveNextflowError {
            try ToolAvailability.skipOrFail(error.description, file: file, line: line)
        }
        let installer = DemoProjectInstaller(
            loader: LocalCopyArchiveLoader(source: archive),
            appVersion: project.minimumAppVersion ?? project.version
        )
        do {
            let result = try await installer.install(project, into: inputDirectory, replaceExisting: false)
            return result.projectURL
        } catch let error as DemoProjectError {
            switch error {
            case .sizeMismatch, .checksumMismatch:
                try ToolAvailability.skipOrFail(
                    "\(archive.path) does not match the catalogue: \(error.localizedDescription)",
                    file: file,
                    line: line
                )
            default:
                throw error
            }
        }
    }

    /// The Pathogen Detection demo project, which holds SRR12486983 and SRR12486989.
    public func installPathogenDetection(
        from archiveFolder: URL? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> URL {
        let project = try Self.demoProject(id: "pathogen-detection")
        return try await installDemoProject(project, from: archiveFolder, file: file, line: line)
    }

    private func configuredArchiveFolder() -> URL? {
        guard let path = environment[LiveNextflowSwitch.archiveFolderVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - The run's containers and teardown

    /// The containers whose mounts hold `workDirectory` or one of `engineWorkFolders`. A TaxTriage launch
    /// makes its own work folder, the `-w` argument of its launch command (TaxTriagePipeline.swift:1089),
    /// in the system temporary folder for the Pathogen Detection demo, so a class that runs TaxTriage
    /// passes that folder here, to `waitForOwnedContainers` and to `teardown`.
    public func ownedContainers(
        includingStopped: Bool = true,
        engineWorkFolders: [URL] = []
    ) throws -> [LiveNextflowDocker.Container] {
        let everything = try docker.containers(includingStopped: includingStopped)
        return LiveNextflowDocker.filter(everything, holdingAny: [workDirectory] + engineWorkFolders)
    }

    /// Waits until a container of the run is running and returns the running ones. A live class calls it
    /// while a task runs and before it checks that a cancel or a teardown left none, so a work folder the
    /// engine does not use fails here instead of passing that check with nothing to find.
    public func waitForOwnedContainers(
        engineWorkFolders: [URL] = [],
        timeout: TimeInterval = 120
    ) async throws -> [LiveNextflowDocker.Container] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let running = try ownedContainers(includingStopped: false, engineWorkFolders: engineWorkFolders)
            if !running.isEmpty { return running }
            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let folders = ([workDirectory] + engineWorkFolders).map(\.path)
        throw LiveNextflowError.misconfigured(
            "No container of the run was running within \(Int(timeout)) s under \(folders). "
                + "The engine's work folder is not one the class gave the helper."
        )
    }

    /// What a teardown did.
    public struct Teardown: Equatable, Sendable {
        /// The containers it removed, all of them holding the run's work folder or an engine work folder.
        public let removedContainerIDs: [String]
        /// Anything that went wrong. A live class asserts this is empty.
        public let problems: [String]
    }

    /// Removes the containers whose mounts hold the run's work folder or one of `engineWorkFolders`,
    /// checks that none is left, and removes the run's folder. It removes no other container. A second
    /// call finds nothing to do. A class that launches an engine with a work folder of its own passes
    /// that folder, see `ownedContainers`, and never a folder that holds other runs.
    @discardableResult
    public func teardown(engineWorkFolders: [URL] = []) -> Teardown {
        var removed: [String] = []
        var problems: [String] = []
        do {
            let owned = try ownedContainers(engineWorkFolders: engineWorkFolders)
            try docker.remove(owned)
            removed = owned.map(\.id)
            let left = try ownedContainers(engineWorkFolders: engineWorkFolders)
            if !left.isEmpty {
                problems.append("containers of the run remain: \(left.map { String($0.id.prefix(12)) })")
            }
        } catch {
            problems.append("docker teardown: \(error)")
        }
        TestTempDirectory.cleanup(directory)
        return Teardown(removedContainerIDs: removed, problems: problems)
    }
}

/// Serves a local archive to `DemoProjectInstaller` in place of a download. The copy is a clone on APFS.
private struct LocalCopyArchiveLoader: DemoProjectArchiveLoading, Sendable {
    let source: URL

    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        try FileManager.default.copyItem(at: source, to: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        progress(size, size)
    }
}
