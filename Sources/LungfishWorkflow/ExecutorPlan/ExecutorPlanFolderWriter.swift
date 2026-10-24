// ExecutorPlanFolderWriter.swift - Stages a plan's files into a new folder and writes the plan file last (CHTC lanes K4 and C4 F)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishPortable

/// The image a job runs in, as the launcher states it: its file name, SHA-256 and size. The shared mode writes it into
/// `staging.json` and never into `plan.json`, an argv or a step's environment. The executor checks the image by the
/// plan's tool manifest pin alone (ARCH Q-C4-5).
package struct ExecutorPlanImageFile: Codable, Sendable, Equatable {
    package var fileName: String
    package var sha256: String
    package var size: Int64

    package init(fileName: String, sha256: String, size: Int64) {
        self.fileName = fileName
        self.sha256 = sha256
        self.size = size
    }
}

/// A file the plan pins that a shared folder does not hold. It is kept once in the group's staging folder under a name
/// that holds its SHA-256, and the job puts it at `relativePath` (ARCH point 2).
package struct ExecutorPlanSharedFile: Codable, Sendable, Equatable {
    package var role: PlanEntryRole
    package var relativePath: String
    package var sha256: String
    package var size: Int64

    package init(role: PlanEntryRole, relativePath: String, sha256: String, size: Int64) {
        self.role = role
        self.relativePath = relativePath
        self.sha256 = sha256
        self.size = size
    }
}

/// `staging.json` of a shared plan folder: each file the folder does not hold, by SHA-256 and size, and the image.
package struct ExecutorPlanStaging: Codable, Sendable, Equatable {
    package static let fileName = "staging.json"
    package static let currentSchemaVersion = 1

    package var schemaVersion: Int
    /// The plan's `executor` and `database` entries, in plan order.
    package var sharedFiles: [ExecutorPlanSharedFile]
    package var image: ExecutorPlanImageFile

    package init(schemaVersion: Int = ExecutorPlanStaging.currentSchemaVersion, sharedFiles: [ExecutorPlanSharedFile],
                 image: ExecutorPlanImageFile) {
        self.schemaVersion = schemaVersion
        self.sharedFiles = sharedFiles
        self.image = image
    }

    /// The file's bytes, keys sorted as the plan file's are.
    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}

/// The one component that creates a plan's folder (ARCH round 3, ruling 2). It refuses a plan that names a signing
/// key (tally K4.10) or that the decoder refuses, copies each entry's Mac file into the folder, a symbolic link as the
/// file it names, checks each copy with the node's own `PlanResourceResolver`, and writes `plan.json` last, so a folder
/// with a plan file holds every file it copied as a regular file the node accepts. `write(_:into:)` copies every entry,
/// for a replay on the Mac. `writeShared(_:image:into:)` copies no `executor` or `database` entry and names each in
/// `staging.json` (C4 lane F, ARCH point 2).
package enum ExecutorPlanFolderWriter {
    package static let planFileName = "plan.json"
    /// The prefix of `ProvenanceSigning`'s two variables. No plan, job environment or plan folder holds one.
    package static let signingVariablePrefix = "LUNGFISH_PROVENANCE_SIGNING"

    package static let signingKeyRefusal = "This plan carries a provenance signing key variable. A plan and the job it describes never hold a signing key, its file or its name."

    /// The roles a shared folder never holds, since one copy of each such file per SHA-256 serves every sample.
    package static let sharedRoles: Set<PlanEntryRole> = [.executor, .database]

    /// Writes `emission` into `folder`, which must not exist yet, and returns the plan file's URL. On any refusal or
    /// failure the folder it created is removed, so no plan file is left behind.
    @discardableResult
    package static func write(_ emission: ExecutorPlanEmission, into folder: URL) throws -> URL {
        try write(emission, into: folder, sharedImage: nil)
    }

    /// The shared mode: writes `emission` into `folder` as `write(_:into:)` does, but copies no `executor` or
    /// `database` entry, and writes `staging.json`, which names each of those by SHA-256 and size and states `image`,
    /// before `plan.json`. The plan file's bytes are those the per-sample folder gets.
    ///
    /// With `stagedInputs`, the folder of a CHTC batch (C4 lane F M2), it copies no `input` entry either, since each
    /// sample's reads are staged beside its plan tar and the job wrapper places them, and `staging.json` names them too.
    @discardableResult
    package static func writeShared(
        _ emission: ExecutorPlanEmission, image: ExecutorPlanImageFile, stagedInputs: Bool = false, into folder: URL
    ) throws -> URL {
        try write(emission, into: folder, sharedImage: image, stagedInputs: stagedInputs)
    }

    private static func write(
        _ emission: ExecutorPlanEmission, into folder: URL, sharedImage: ExecutorPlanImageFile?, stagedInputs: Bool = false
    ) throws -> URL {
        let plan = emission.plan
        let data = try plan.encoded()
        if String(decoding: data, as: UTF8.self).contains(signingVariablePrefix) {
            throw ExecutorPlanError(field: "steps.environment", reason: signingKeyRefusal)
        }
        // The node's own decoder, so the Mac refuses a plan with the node's words (tally-r2 K4-13).
        _ = try ExecutionPlan.decode(data)
        func copies(_ entry: PlanEntry) -> Bool {
            sharedImage == nil || !(sharedRoles.contains(entry.role) || (stagedInputs && entry.role == .input))
        }
        var staging: Data?
        if let sharedImage {
            try check(sharedImage)
            staging = try ExecutorPlanStaging(
                sharedFiles: plan.entries.filter { !copies($0) }.map {
                    ExecutorPlanSharedFile(role: $0.role, relativePath: $0.relativePath, sha256: $0.sha256, size: $0.size)
                },
                image: sharedImage
            ).encoded()
        }
        for (index, entry) in plan.entries.enumerated() where copies(entry) && emission.sources[entry.relativePath] == nil {
            throw ExecutorPlanError(field: "entries[\(index)]", reason: "The plan pins \(entry.relativePath), and no Mac file was given for it.")
        }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: folder.path) else {
            throw ExecutorPlanError(field: "folder", reason: "The plan folder \(folder.lastPathComponent) already exists. A plan is written into a new folder.")
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            let resolver = try PlanResourceResolver(workRoot: folder)
            for (index, entry) in plan.entries.enumerated() where copies(entry) {
                guard let source = emission.sources[entry.relativePath] else { continue }
                let destination = folder.appendingPathComponent(entry.relativePath)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                // A link is copied as the file it names, since the node refuses a link that leads out of the folder and
                // a transfer may carry a link as a link.
                try fileManager.copyItem(at: source.resolvingSymlinksInPath(), to: destination)
                do {
                    _ = try resolver.verify(entry)
                } catch let refusal as PlanResourceRefusal {
                    throw ExecutorPlanError(field: "entries[\(index)]", reason: refusal.reason)
                }
            }
            if let staging {
                try DurableReplace.replace(staging, named: ExecutorPlanStaging.fileName, in: folder)
            }
            try DurableReplace.replace(data, named: planFileName, in: folder)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return folder.appendingPathComponent(planFileName)
    }

    /// The image's values are a plain file name, a lowercase hexadecimal SHA-256 and a size above 0.
    private static func check(_ image: ExecutorPlanImageFile) throws {
        let name = image.fileName
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw ExecutorPlanError(field: "staging.image.fileName", reason: "The image's file name \(name) is not a plain file name.")
        }
        guard image.sha256.count == 64, image.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ExecutorPlanError(field: "staging.image.sha256", reason: "The image's SHA-256 \(image.sha256) is not 64 lowercase hexadecimal digits.")
        }
        guard image.size > 0 else {
            throw ExecutorPlanError(field: "staging.image.size", reason: "The image's size \(image.size) is not above 0.")
        }
    }
}
