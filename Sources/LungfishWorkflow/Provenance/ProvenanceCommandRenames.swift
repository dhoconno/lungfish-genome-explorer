// ProvenanceCommandRenames.swift - A recorded command after a rename, as a reader should see and copy it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A sidebar rename rewrites the paths a record names and keeps each command as it ran
// (`ProvenancePathRehydrator.preservesExactInvocationValue`), so the command names a folder that is gone. The record
// stays as it is (R-B2, BIO 4). At display and copy time the Inspector moves each path the rename moved into the new
// folder and says so beside the Command row (Phase 2.12 lane 12.25, T4 placed the note there, never in the copied text).
//
// The rename is read from the record alone, with no file system call. The record lies inside the folder the rename
// named, since the rehydrator rewrites the records under that folder. A command names a sibling of that folder, or for
// a Move a folder of the same name anywhere under the project, and the record's files name the same path below the new
// folder while none of them names the old one. That is the trace the rehydrator leaves and nothing else does, apart
// from a hidden working folder, which the sidebar never renames and which is left alone. Two old folders for one new
// folder map nothing. Only resolved paths inside the project count, so a placeholder, a path outside the project and
// a path that climbs out of it with `..` stay as recorded (SWIFT 6). The replay reads the same relocation (lane 13.45).

import Foundation
import LungfishCore

/// A folder that a rename moved, as one record shows it.
public struct ProvenanceFolderRename: Sendable, Equatable {
    /// The folder's path when the command ran, which the command still names.
    public let oldPath: String
    /// The folder's path now, which the record's files name.
    public let newPath: String

    public init(oldPath: String, newPath: String) {
        self.oldPath = oldPath
        self.newPath = newPath
    }

    /// `path` moved into the new folder when it is the old folder or lies under it, otherwise nil.
    func moving(_ path: String) -> String? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if standardized == oldPath { return newPath }
        guard standardized.hasPrefix(oldPath + "/") else { return nil }
        return newPath + standardized.dropFirst(oldPath.count)
    }
}

extension ProvenanceCommandPresentation {
    /// The folders a rename moved, read from one record at `recordURL` inside `projectURL`: `commands` are its
    /// recorded commands and `filePaths` the paths its file descriptors name, both resolved. Empty outside a project.
    public static func folderRenames(
        commands: [String],
        filePaths: [String],
        recordURL: URL,
        projectURL: URL?
    ) -> [ProvenanceFolderRename] {
        guard let projectURL else { return [] }
        let project = projectURL.standardizedFileURL.path
        let files = filePaths.compactMap { components(of: $0, under: project) }
        let named = Set(files.map { $0.joined(separator: "/") })
        guard let record = components(of: recordURL.path, under: project), record.count > 1 else { return [] }
        let commandPaths = commands.flatMap { pathWords(of: $0, projectURL: projectURL) }
            .compactMap { components(of: $0, under: project) }

        var renames: [ProvenanceFolderRename] = []
        // The record's own folder first, then each folder that holds it, below the project.
        for depth in stride(from: record.count - 1, through: 1, by: -1) {
            let folder = Array(record.prefix(depth))
            guard let name = folder.last, !name.hasPrefix(".") else { continue }
            for path in commandPaths {
                for old in oldFolders(in: path, for: folder) {
                    let rest = path.dropFirst(old.count)
                    let oldPath = project + "/" + old.joined(separator: "/")
                    guard !renames.contains(where: { $0.oldPath == oldPath }),
                          named.contains((folder + rest).joined(separator: "/")),
                          !files.contains(where: { Array($0.prefix(old.count)) == old })
                    else { continue }
                    renames.append(ProvenanceFolderRename(oldPath: oldPath, newPath: project + "/" + folder.joined(separator: "/")))
                }
            }
        }
        // Two old folders for one new folder: the record cannot say which one moved there, so it maps neither and the
        // command shows as recorded (lane 13.45, ARCH C1).
        let newPaths = renames.map(\.newPath)
        return renames.filter { rename in newPaths.filter { $0 == rename.newPath }.count == 1 }
    }

    /// The folders that `path` names which `folder` may have been before it moved. A rename keeps the parent and changes
    /// the name. A Move keeps the name, takes a folder at any depth under the project and changes the parent. A Move
    /// that also renames is not read (the Known limit), and a hidden folder is never an old folder.
    private static func oldFolders(in path: [String], for folder: [String]) -> [[String]] {
        guard let name = folder.last else { return [] }
        let parent = Array(folder.dropLast())
        var olds: [[String]] = []
        if path.count >= folder.count, Array(path.prefix(folder.count - 1)) == parent {
            let oldName = path[folder.count - 1]
            if oldName != name, !oldName.hasPrefix(".") { olds.append(Array(path.prefix(folder.count))) }
        }
        for (index, component) in path.enumerated() where component == name {
            let old = Array(path.prefix(index + 1))
            guard Array(old.dropLast()) != parent, !old.contains(where: { $0.hasPrefix(".") }) else { continue }
            olds.append(old)
        }
        return olds
    }

    /// `command` with each path word that a rename moved in its new folder, quoted as one shell word, and each run of
    /// the project's path that holds white space quoted as ``quotingProjectPath(_:projectURL:)`` quotes it. Every other
    /// word goes back out as recorded. It is the command Copy Command copies, and with no rename it is
    /// `quotingProjectPath` itself.
    public static func movingRenamedPaths(
        _ command: String,
        renames: [ProvenanceFolderRename],
        projectURL: URL?
    ) -> String {
        guard let projectURL, let pieces = split(command, keeping: spacedPaths(of: projectURL)) else { return command }
        var shown = ""
        var recent: [String] = []
        for piece in pieces {
            switch piece {
            case .separator(let text):
                shown += text
            case .word(let word):
                if recent.count == 2 && isShell(recent[0]) && isCommandFlag(recent[1]) {
                    let script = movingRenamedPaths(word.value, renames: renames, projectURL: projectURL)
                    shown += script == word.value ? word.raw : shellEscape(script)
                } else {
                    shown += moving(word, renames: renames)
                }
                recent = Array((recent + [word.value]).suffix(2))
            }
        }
        return shown
    }

    /// The note beside the Command row of a step whose command a rename moved, each folder named as the row names a
    /// project path: `This command ran in <old>. The row and Copy Command name <new>, where the record is now.` The
    /// sidebar's Duplicate leaves the trace a rename leaves, and the record alone cannot tell the two apart, so the
    /// words hold for both (UX ruling 3 on lane 12.25). Nil when `renames` is empty.
    public static func renameNote(_ renames: [ProvenanceFolderRename], projectURL: URL?) -> String? {
        guard !renames.isEmpty else { return nil }
        return renames.map { rename in
            let old = displayPath(rename.oldPath, projectURL: projectURL, fileExists: { _ in false })
            let new = displayPath(rename.newPath, projectURL: projectURL, fileExists: { _ in true })
            return "This command ran in \(old). The row and Copy Command name \(new), where the record is now."
        }.joined(separator: " ")
    }

    // MARK: - Words

    private static func moving(_ word: Word, renames: [ProvenanceFolderRename]) -> String {
        guard let part = pathPart(of: word.value) else { return word.raw }
        let terminator = part.path.hasSuffix(";") ? ";" : ""
        let path = String(part.path.dropLast(terminator.count))
        guard let moved = renames.lazy.compactMap({ $0.moving(path) }).first else {
            guard word.joinedProjectPath else { return word.raw }
            return (part.isRedirect ? part.prefix + shellEscape(part.path) : shellEscape(part.prefix + part.path))
        }
        return (part.isRedirect ? part.prefix + shellEscape(moved) : shellEscape(part.prefix + moved)) + terminator
    }

    /// The path of each word of `command` that holds one, a shell's `-c` script read as a command of its own.
    static func pathWords(of command: String, projectURL: URL) -> [String] {
        guard let pieces = split(command, keeping: spacedPaths(of: projectURL)) else { return [] }
        var paths: [String] = []
        var recent: [String] = []
        for case .word(let word) in pieces {
            if recent.count == 2 && isShell(recent[0]) && isCommandFlag(recent[1]) {
                paths += pathWords(of: word.value, projectURL: projectURL)
            } else if let part = pathPart(of: word.value) {
                paths.append(part.path.hasSuffix(";") ? String(part.path.dropLast()) : part.path)
            }
            recent = Array((recent + [word.value]).suffix(2))
        }
        return paths
    }

    /// The components of `path` below `project`, or nil for a path that holds a placeholder the reader could not
    /// resolve, is not absolute or does not lie inside the project once `.` and `..` are resolved.
    private static func components(of path: String, under project: String) -> [String]? {
        guard path.hasPrefix("/"), !PortablePath.containsUnresolvedPlaceholder(path) else { return nil }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.hasPrefix(project + "/") else { return nil }
        return standardized.dropFirst(project.count + 1).split(separator: "/").map(String.init)
    }
}
