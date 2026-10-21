// ProvenanceReplayArguments.swift - The argv a provenance export replays, read from one record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.45 (SW2 R-REPLAY), ARCH-13.45 C2 to C5. A record keeps the argv it ran (R-B2, BIO 4), so after a
// rename, a Move or a Duplicate its argv names a folder that is gone or a source the replay must never write. The rule
// below runs once for each step, inside the exporter's one replay selection, so every format replays the same argv.
// For each path word, in this order:
// 1. An output word names an output descriptor of the record, or lies (after the relocation moves it) under the record's
//    own folder and names no input descriptor. It becomes the fresh-folder token plus its path relative to the record's
//    folder, or to the project when it lies outside that folder. A replay writes nothing anywhere else.
// 2. An input word, moved by the relocation, names an input descriptor. It becomes that descriptor's path.
// 3. Any other word goes out as recorded (C4), such as a reference database, a managed tool or a file outside the project.
// The record is never written (D1). The function reads no file.

import Foundation
import LungfishCore

/// The replay argv rule of one record: its relocation, its descriptors and its folder.
public struct ProvenanceReplayArguments: Sendable, Equatable {
    /// The path a replay writes below its fresh output folder starts with this, and each renderer spells it as its
    /// output root (`$OUTDIR` in a shell script).
    public static let freshFolder = "<replay-output>"

    public let relocation: [ProvenanceFolderRename]
    /// The input descriptors' paths, each with its recorded SHA-256 or nil.
    public let inputs: [String: String?]
    public let outputs: Set<String>
    public let recordFolder: String?
    public let project: String?

    public init(
        relocation: [ProvenanceFolderRename],
        inputs: [String: String?],
        outputs: Set<String>,
        recordFolder: URL?,
        projectURL: URL?
    ) {
        self.relocation = relocation
        self.inputs = inputs
        self.outputs = outputs
        self.recordFolder = recordFolder?.standardizedFileURL.path
        self.project = projectURL?.standardizedFileURL.path
    }

    /// The rule of `envelope`, read at `recordURL` (its relocation and folder). With no record URL nothing moves and
    /// only the descriptors count.
    public init(envelope: ProvenanceEnvelope, recordURL: URL?) {
        let descriptors = envelope.files + envelope.outputs + [envelope.output].compactMap { $0 }
            + envelope.steps.flatMap { $0.inputs + $0.outputs }
        var inputs: [String: String?] = [:]
        for file in descriptors where file.role == .input { inputs[Self.standardized(file.path)] = file.checksumSHA256 }
        self.init(
            relocation: recordURL.map { ProvenanceCommandPresentation.folderRenames(of: envelope, recordURL: $0) } ?? [],
            inputs: inputs,
            outputs: Set(descriptors.filter { $0.role == .output }.map { Self.standardized($0.path) }),
            recordFolder: recordURL?.deletingLastPathComponent(),
            projectURL: recordURL.flatMap { PortablePath.anchors(for: $0).project }
        )
    }

    /// `argv` as the replay runs it. A word that holds no absolute or project path is left as it is.
    public func arguments(_ argv: [String]) -> [String] {
        argv.map { word in
            guard let part = Self.pathPart(of: word), let path = resolved(part.path) else { return word }
            switch place(of: path) {
            case .output(let relative): return part.prefix + Self.freshFolder + (relative.isEmpty ? "" : "/" + relative)
            case .input(let moved): return part.prefix + moved
            case .recorded: return word
            }
        }
    }

    /// The inputs the replay of `argv` reads, each with the SHA-256 its descriptor recorded or nil for a legacy record,
    /// in argv order, once each (C3).
    public func checkedInputs(_ argv: [String]) -> [(path: String, sha256: String?)] {
        var seen = Set<String>()
        return argv.compactMap { word in
            guard let part = Self.pathPart(of: word), let path = resolved(part.path),
                  case .input(let moved) = place(of: path), seen.insert(moved).inserted else { return nil }
            return (moved, inputs[moved] ?? nil)
        }
    }

    enum Place: Equatable {
        case output(String)
        case input(String)
        case recorded
    }

    func place(of path: String) -> Place {
        let moved = relocation.lazy.compactMap { $0.moving(path) }.first ?? path
        if outputs.contains(moved) || outputs.contains(path) {
            return .output(relative(moved))
        }
        if let folder = recordFolder, moved == folder || moved.hasPrefix(folder + "/"), inputs[moved] == nil {
            return .output(relative(moved))
        }
        return inputs[moved] != nil ? .input(moved) : .recorded
    }

    /// `path` below the record's folder, or below the project, or its last name.
    private func relative(_ path: String) -> String {
        for root in [recordFolder, project].compactMap({ $0 }) {
            if path == root { return "" }
            if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func resolved(_ path: String) -> String? {
        if path.hasPrefix(PortablePath.projectPrefix) {
            guard let project else { return nil }
            return Self.standardized(project + "/" + path.dropFirst(PortablePath.projectPrefix.count))
        }
        return path.hasPrefix("/") ? Self.standardized(path) : nil
    }

    private static func standardized(_ path: String) -> String {
        path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL.path : path
    }

    /// A whole path word, or the path after the first `=` of an option such as `--out=/path`.
    private static func pathPart(of word: String) -> (prefix: String, path: String)? {
        if word.hasPrefix("/") || word.hasPrefix(PortablePath.projectPrefix) { return ("", word) }
        guard word.hasPrefix("-"), let equals = word.firstIndex(of: "=") else { return nil }
        let value = String(word[word.index(after: equals)...])
        guard value.hasPrefix("/") || value.hasPrefix(PortablePath.projectPrefix) else { return nil }
        return (String(word[...equals]), value)
    }
}
