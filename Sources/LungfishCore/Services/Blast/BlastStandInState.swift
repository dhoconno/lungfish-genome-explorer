// BlastStandInState.swift - What a debug stand-in run reads beside its origin
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let standInLogger = Logger(subsystem: LogSubsystem.core, category: "BlastStandInState")

/// The two values a debug build reads beside ``BlastServiceEndpoints/standInOriginVariable``.
///
/// A release build reads neither, and in a debug build they count only with the origin set. So a stand-in run never
/// touches the real root, and two children given one state folder share the files that keep a search going across
/// processes (ARCH-BLAST-RESILIENCE item 21 and section 7). No option, project file, defaults key or downloaded field
/// can set them.
package struct BlastStandInState: Sendable, Equatable {
    /// Names the folder that takes the place of `<root>/blast/`.
    package static let stateVariable = "LUNGFISH_BLAST_STAND_IN_STATE"
    /// Names how many times faster than the wall clock the search clock runs.
    package static let timeScaleVariable = "LUNGFISH_BLAST_STAND_IN_TIME_SCALE"
    /// The empty file in a stand-in's shared folder whose date is the moment a scaled clock starts from.
    package static let clockAnchorFileName = "clock-anchor"

    /// The folder of a stand-in run that names none. It lasts as long as the temporary folder does and no longer.
    package static let processFolder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "lungfish-blast-stand-in-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)

    /// The folder this run's environment names, or ``processFolder`` when it names none.
    package let folder: URL
    /// How many times faster than the wall clock the search clock runs, 1 unless the environment names a positive number.
    package let timeScale: Double

    /// The stand-in values `environment` names, or nil for a run that talks to NCBI. A release build is always such a run.
    package init?(environment: [String: String]) {
        #if DEBUG
        guard BlastServiceEndpoints(environment: environment).isStandIn else { return nil }
        if let named = environment[Self.stateVariable], !named.isEmpty {
            self.folder = URL(fileURLWithPath: named, isDirectory: true)
        } else {
            self.folder = Self.processFolder
        }
        let scale = environment[Self.timeScaleVariable].flatMap(Double.init) ?? 1
        self.timeScale = scale.isFinite && scale > 0 ? scale : 1
        #else
        return nil
        #endif
    }

    /// Where this run keeps the files BLAST shares across processes: `<root>/blast/` for a run that talks to NCBI,
    /// and the stand-in's folder otherwise. A state folder named inside the root reads as no name at all, since a
    /// stand-in run never touches the real root.
    package static func sharedFolder(environment: [String: String], storageRoot: URL) -> URL {
        guard let standIn = BlastStandInState(environment: environment) else {
            return storageRoot.appendingPathComponent(FileBlastSubmissionLedger.directoryName, isDirectory: true)
        }
        let rootPath = resolvedPath(storageRoot)
        let folderPath = resolvedPath(standIn.folder)
        guard folderPath == rootPath || folderPath.hasPrefix(rootPath + "/") else { return standIn.folder }
        standInLogger.warning("The BLAST stand-in state folder names the storage root, so this run uses a temporary folder")
        return processFolder
    }

    /// The path of `url` with every link in its existing part resolved, since a state folder may not exist yet.
    private static func resolvedPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        guard let resolved = realpath(existing.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return missing.reduce(String(cString: resolved)) { $0 + "/" + $1 }
    }

    /// The moment a scaled clock in `sharedFolder` starts from, the date of the anchor file there. The first process
    /// to ask creates the file, which is what every later process reads, so two children read one time. Nothing is
    /// ever written to the file, so no reader can catch it half written and no later process can move its date.
    package static func clockAnchor(in sharedFolder: URL) -> Date {
        let anchor = sharedFolder.appendingPathComponent(clockAnchorFileName, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true)
            let descriptor = open(anchor.path, O_CREAT | O_RDONLY | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            close(descriptor)
            let attributes = try FileManager.default.attributesOfItem(atPath: anchor.path)
            if let date = attributes[.modificationDate] as? Date { return date }
        } catch {
            standInLogger.warning("Could not read the BLAST stand-in clock anchor: \(error.localizedDescription, privacy: .public)")
        }
        return Date()
    }
}
