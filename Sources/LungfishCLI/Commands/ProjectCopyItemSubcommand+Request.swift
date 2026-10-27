// ProjectCopyItemSubcommand+Request.swift - What `project copy-item` copies and the words its record names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.18 (BIO ruling on F3). The record names the source item as two values, the source
// project and the item's path inside it, never as one absolute path inside the source project, since
// the provenance reader re-roots such a path onto the copy. The words are spelled one way whatever form
// the user typed, so the sidebar's run and a run typed at a shell write the same record.

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension ProjectCopyItemSubcommand {
    /// The item, its project, the target project and the folder, with the identity the records name.
    struct Request {
        let source: URL
        let kind: CrossProjectItemCopier.ItemKind
        let sourceProject: URL?
        let target: URL
        let folder: URL?
        let identity: ProjectCopyCommandIdentity
    }

    /// Checks the arguments and spells the command's words, or refuses before anything is written.
    func resolvedRequest() throws -> Request {
        let target = Self.absoluteURL(project)
        guard Self.isProject(target) else {
            throw ProjectCopyItemRefusal("No project at \(target.path). --project names a .lungfish project folder.")
        }
        let givenSourceProject = sourceProject.map(Self.absoluteURL)
        if let given = givenSourceProject, !Self.isProject(given) {
            throw ProjectCopyItemRefusal("No project at \(given.path). --source-project names a .lungfish project folder.")
        }
        let source: URL
        if let given = givenSourceProject, !item.hasPrefix("/") {
            source = given.appendingPathComponent(item, isDirectory: true).standardizedFileURL
        } else {
            source = Self.absoluteURL(item)
        }
        guard let kind = CrossProjectItemCopier.kind(of: source) else {
            throw ProjectCopyItemRefusal(
                "No Lungfish bundle or analysis result at \(source.path). project copy-item copies one of those."
            )
        }
        // The copier finds the source project the same way, so the record and the copy agree.
        let holder = ProjectTempDirectory.findProjectRoot(source.deletingLastPathComponent())?.standardizedFileURL
        if let given = givenSourceProject,
           holder?.resolvingSymlinksInPath().path != given.resolvingSymlinksInPath().path {
            throw ProjectCopyItemRefusal("\(source.path) is not inside \(given.path). Give the project that holds the item.")
        }

        var argv = [CLICommandIdentity.executableName, "project", "copy-item"]
        var explicit: [String: ParameterValue] = ["project": .file(target)]
        if let holder, let relative = ProjectItemLinkRewriter.descendantPath(of: source, in: holder) {
            argv += [relative, "--source-project", holder.path]
            explicit["item"] = .string(relative)
            explicit["sourceProject"] = .file(holder)
        } else {
            argv.append(source.path)
            explicit["item"] = .file(source)
        }
        argv += ["--project", target.path]

        var folderURL: URL?
        if let folder {
            let url = folder.hasPrefix("/")
                ? URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
                : target.appendingPathComponent(folder, isDirectory: true).standardizedFileURL
            let relative = url.path == target.path
                ? "."
                : ProjectItemLinkRewriter.descendantPath(of: url, in: target)
            guard let relative else {
                throw ProjectCopyItemRefusal("--folder \(folder) is not inside \(target.path). Give a folder inside the project.")
            }
            folderURL = url
            argv += ["--folder", relative]
            explicit["folder"] = .string(relative)
        }

        var resolved = explicit
        resolved["caller"] = .string("cli")
        return Request(
            source: source,
            kind: kind,
            sourceProject: holder,
            target: target,
            folder: folderURL,
            identity: ProjectCopyCommandIdentity(
                name: Self.commandName,
                argv: argv,
                explicitOptions: explicit,
                defaultOptions: [:],
                resolvedOptions: resolved
            )
        )
    }

    private static func absoluteURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func isProject(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return ProjectRootTest.isProjectRoot(url)
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
