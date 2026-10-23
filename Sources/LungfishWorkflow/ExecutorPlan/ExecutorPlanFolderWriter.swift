// ExecutorPlanFolderWriter.swift - Stages a plan's files into a new folder and writes the plan file last (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishPortable

/// The one component that creates a plan's folder (ARCH round 3, ruling 2). It refuses a plan that names a signing
/// key (tally K4.10) or that the decoder refuses, copies every entry's Mac file into the folder and checks its SHA-256
/// and size, and writes `plan.json` last, so a folder with a plan file holds every file the plan pins.
package enum ExecutorPlanFolderWriter {
    package static let planFileName = "plan.json"
    /// The prefix of `ProvenanceSigning`'s two variables. No plan, job environment or plan folder holds one.
    package static let signingVariablePrefix = "LUNGFISH_PROVENANCE_SIGNING"

    package static let signingKeyRefusal = "This plan carries a provenance signing key variable. A plan and the job it describes never hold a signing key, its file or its name."

    /// Writes `emission` into `folder`, which must not exist yet, and returns the plan file's URL. On any refusal or
    /// failure the folder it created is removed, so no plan file is left behind.
    @discardableResult
    package static func write(_ emission: ExecutorPlanEmission, into folder: URL) throws -> URL {
        let plan = emission.plan
        let data = try plan.encoded()
        if String(decoding: data, as: UTF8.self).contains(signingVariablePrefix) {
            throw ExecutorPlanError(field: "steps.environment", reason: signingKeyRefusal)
        }
        // The node's own decoder, so the Mac refuses a plan with the node's words (tally-r2 K4-13).
        _ = try ExecutionPlan.decode(data)
        for (index, entry) in plan.entries.enumerated() where emission.sources[entry.relativePath] == nil {
            throw ExecutorPlanError(field: "entries[\(index)]", reason: "The plan pins \(entry.relativePath), and no Mac file was given for it.")
        }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: folder.path) else {
            throw ExecutorPlanError(field: "folder", reason: "The plan folder \(folder.lastPathComponent) already exists. A plan is written into a new folder.")
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            for entry in plan.entries {
                guard let source = emission.sources[entry.relativePath] else { continue }
                let destination = folder.appendingPathComponent(entry.relativePath)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: destination)
                let staged = try ExecutorPlanSourceFile.measuring(destination)
                guard staged.sha256 == entry.sha256, staged.size == entry.size else {
                    throw ExecutorPlanError(field: "entries", reason: "The staged copy of \(entry.relativePath) differs from the SHA-256 or size the plan pins. Its Mac file changed after the plan was made.")
                }
            }
            try DurableReplace.replace(data, named: planFileName, in: folder)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return folder.appendingPathComponent(planFileName)
    }
}
