// ProjectRoot.swift - What identifies a project's root folder across a rename or a move
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What identifies a project's root folder, for the modules that must tell the same folder from another one at the
/// same path: the file-system refresh of LungfishOperations and the view memory of LungfishKit.
package enum ProjectRoot {
    /// Continuity evidence only; native format and write access are revalidated
    /// by the existing project-open path after a successful filesystem rebind.
    package struct RootIdentity: Equatable, Sendable {
        package let volume: String
        package let fileNumber: UInt64
        package let createdAt: Date
    }

    package nonisolated static func rootIdentity(at url: URL) throws -> RootIdentity {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: canonical.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              FileManager.default.isReadableFile(atPath: canonical.path),
              let file = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber,
              let created = attributes[.creationDate] as? Date else { throw CocoaError(.fileReadUnknown) }
        let volume = try? canonical.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return RootIdentity(volume: volume ?? "device:\(device.uint64Value)", fileNumber: file.uint64Value, createdAt: created)
    }
}
