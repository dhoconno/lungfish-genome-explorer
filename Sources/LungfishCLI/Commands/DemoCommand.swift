// DemoCommand.swift - List, describe and fetch ready-to-analyse demo projects
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// CLI parity for Help > Demo Projects… in the app.
struct DemoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "demo",
        abstract: "List, describe and download ready-to-analyse demo projects",
        discussion: """
        Each demo project matches one activity in the user manual. 'demo fetch'
        downloads the project archive, checks its size and SHA-256, unpacks it
        safely and installs it as '<dest>/<Project Name>.lungfish'. The default
        destination is ~/Documents/LGE Demo Projects, which is also the app's
        default folder in Help > Demo Projects… Pass --dest to use another folder.

        An existing copy is left alone unless you pass --force, which moves it to
        the Trash before installing a fresh copy.
        """,
        subcommands: [
            ListSubcommand.self,
            InfoSubcommand.self,
            FetchSubcommand.self,
        ]
    )
}

/// Options every `demo` subcommand shares.
struct DemoLocationOptions: ParsableArguments {
    @Option(
        name: .customLong("dest"),
        help: "Folder that holds installed demo projects (default: ~/Documents/LGE Demo Projects)"
    )
    var destination: String?

    @Option(
        name: .customLong("manifest"),
        help: ArgumentHelp("Read the demo project list from this JSON file instead of the bundled one", visibility: .hidden)
    )
    var manifestPath: String?

    func destinationURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard let destination, !destination.isEmpty else {
            return DemoProjectInstaller.defaultInstallDirectory(homeDirectory: homeDirectory)
        }
        let expanded = (destination as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    func loadManifest() throws -> DemoProjectManifest {
        if let manifestPath, !manifestPath.isEmpty {
            return try DemoProjectManifest.load(from: URL(fileURLWithPath: (manifestPath as NSString).expandingTildeInPath))
        }
        return try DemoProjectManifest.loadBundled()
    }
}

extension DemoCommand {
    /// One row of `demo list --format json`, and the body of `demo info --format json`.
    struct ProjectReport: Codable, Equatable {
        let id: String
        let title: String
        let summary: String
        let version: String
        let minimumAppVersion: String?
        let bytes: Int64
        let size: String
        let published: Bool
        let status: String
        let installed: Bool
        let installedVersion: String?
        let path: String
        let archiveURL: String
        let sha256: String
        let chapters: [ChapterReport]

        private enum CodingKeys: String, CodingKey {
            case id, title, summary, version, minimumAppVersion, bytes, size, published, status
            case installed, installedVersion, path, archiveURL, sha256, chapters
        }

        /// Writes optional fields as explicit `null` so every row has the same keys.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(summary, forKey: .summary)
            try container.encode(version, forKey: .version)
            try container.encode(minimumAppVersion, forKey: .minimumAppVersion)
            try container.encode(bytes, forKey: .bytes)
            try container.encode(size, forKey: .size)
            try container.encode(published, forKey: .published)
            try container.encode(status, forKey: .status)
            try container.encode(installed, forKey: .installed)
            try container.encode(installedVersion, forKey: .installedVersion)
            try container.encode(path, forKey: .path)
            try container.encode(archiveURL, forKey: .archiveURL)
            try container.encode(sha256, forKey: .sha256)
            try container.encode(chapters, forKey: .chapters)
        }
    }

    struct ChapterReport: Codable, Equatable {
        let title: String
        let url: String
    }

    struct ListReport: Codable, Equatable {
        let schemaVersion: Int
        let destination: String
        let projects: [ProjectReport]
    }

    static func report(for project: DemoProject, in destination: URL) -> ProjectReport {
        let status = DemoProjectInstaller.status(for: project, in: destination)
        let installedVersion: String?
        switch status {
        case .notDownloaded: installedVersion = nil
        case .downloaded(let version): installedVersion = version
        case .updateAvailable(let installed, _): installedVersion = installed
        }
        return ProjectReport(
            id: project.id,
            title: project.title,
            summary: project.summary,
            version: project.version,
            minimumAppVersion: project.minimumAppVersion,
            bytes: project.archive.bytes,
            size: formatBytes(project.archive.bytes),
            published: !project.archive.isPlaceholder,
            status: status.token,
            installed: status.isInstalled,
            installedVersion: installedVersion,
            path: DemoProjectInstaller.projectURL(for: project, in: destination).path,
            archiveURL: project.archive.url.absoluteString,
            sha256: project.archive.sha256,
            chapters: project.chapters.map { ChapterReport(title: $0.title, url: $0.url?.absoluteString ?? $0.path) }
        )
    }

    static func listReport(for manifest: DemoProjectManifest, in destination: URL) -> ListReport {
        ListReport(
            schemaVersion: manifest.schemaVersion,
            destination: destination.path,
            projects: manifest.projects.map { report(for: $0, in: destination) }
        )
    }

    static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "unknown size" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func resolveProject(_ id: String, in manifest: DemoProjectManifest) throws -> DemoProject {
        guard let project = manifest.project(id: id) else {
            throw DemoProjectError.unknownProject(id)
        }
        return project
    }
}

// MARK: - list

extension DemoCommand {
    struct ListSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List the demo projects with their size, installed status and path"
        )

        @OptionGroup var globalOptions: TextAndJSONGlobalOptions
        @OptionGroup var location: DemoLocationOptions

        func run() async throws {
            let manifest = try location.loadManifest()
            let destination = location.destinationURL()
            let report = DemoCommand.listReport(for: manifest, in: destination)
            let resolved = try globalOptions.resolved(with: CommandLine.arguments)
            if resolved.outputFormat == .json {
                Swift.print(try DemoCommand.encodeJSON(report))
                return
            }
            Swift.print(DemoCommand.textTable(for: report))
        }
    }

    static func textTable(for report: ListReport) -> String {
        let idWidth = max(2, report.projects.map(\.id.count).max() ?? 0)
        let titleWidth = max(5, report.projects.map(\.title.count).max() ?? 0)
        let sizeWidth = max(4, report.projects.map(\.size.count).max() ?? 0)
        let statusWidth = max(6, report.projects.map { statusText($0).count }.max() ?? 0)
        func pad(_ text: String, _ width: Int) -> String {
            text.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        var lines = ["Demo projects in \(report.destination)", ""]
        lines.append([pad("ID", idWidth), pad("TITLE", titleWidth), pad("SIZE", sizeWidth), pad("STATUS", statusWidth), "PATH"].joined(separator: "  "))
        for project in report.projects {
            lines.append([
                pad(project.id, idWidth),
                pad(project.title, titleWidth),
                pad(project.size, sizeWidth),
                pad(statusText(project), statusWidth),
                project.installed ? project.path : "-",
            ].joined(separator: "  "))
        }
        return lines.joined(separator: "\n")
    }

    private static func statusText(_ project: ProjectReport) -> String {
        switch project.status {
        case "not-downloaded": return project.published ? "Not downloaded" : "Not published"
        case "update-available": return "Update available"
        default: return "Downloaded"
        }
    }
}

// MARK: - info

extension DemoCommand {
    struct InfoSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Describe one demo project and the manual chapters it goes with"
        )

        @Argument(help: "Demo project id (see 'demo list')")
        var id: String

        @OptionGroup var globalOptions: TextAndJSONGlobalOptions
        @OptionGroup var location: DemoLocationOptions

        func run() async throws {
            let manifest = try location.loadManifest()
            let project = try DemoCommand.resolveProject(id, in: manifest)
            let report = DemoCommand.report(for: project, in: location.destinationURL())
            let resolved = try globalOptions.resolved(with: CommandLine.arguments)
            if resolved.outputFormat == .json {
                Swift.print(try DemoCommand.encodeJSON(report))
                return
            }
            var lines = [
                report.title,
                report.summary,
                "",
                "ID:           \(report.id)",
                "Version:      \(report.version)",
                "Size:         \(report.size)",
                "Status:       \(DemoProjectInstaller.status(for: project, in: location.destinationURL()).label)",
                "Path:         \(report.path)",
                "Archive:      \(report.archiveURL)",
                "SHA-256:      \(report.published ? report.sha256 : "not published yet")",
            ]
            if let minimum = report.minimumAppVersion {
                lines.append("Requires:     Lungfish Genome Explorer \(minimum) or later")
            }
            if !report.chapters.isEmpty {
                lines.append("")
                lines.append("Manual chapters:")
                for chapter in report.chapters {
                    lines.append("  \(chapter.title)")
                    lines.append("    \(chapter.url)")
                }
            }
            Swift.print(lines.joined(separator: "\n"))
        }
    }
}

// MARK: - fetch

extension DemoCommand {
    struct FetchSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fetch",
            abstract: "Download, verify and install a demo project, then print its path",
            discussion: """
            The archive is checked against the byte count and SHA-256 in the demo
            project list before anything is unpacked. It is unpacked into a hidden
            staging folder and moved into place only when complete, so a failed or
            cancelled fetch never leaves a half-extracted project behind.
            """
        )

        @Argument(help: "Demo project id (see 'demo list')")
        var id: String

        @Flag(name: .customLong("force"), help: "Replace an existing copy with a fresh one (the old copy goes to the Trash)")
        var force: Bool = false

        @OptionGroup var globalOptions: TextAndJSONGlobalOptions
        @OptionGroup var location: DemoLocationOptions

        func run() async throws {
            let resolved = try globalOptions.resolved(with: CommandLine.arguments)
            let manifest = try location.loadManifest()
            let project = try DemoCommand.resolveProject(id, in: manifest)
            let destination = location.destinationURL()
            let projectURL = DemoProjectInstaller.projectURL(for: project, in: destination)

            if !force, FileManager.default.fileExists(atPath: projectURL.path) {
                if !resolved.quiet {
                    FileHandle.standardError.write(Data(
                        "\(project.title) is already installed. Pass --force to replace it with a fresh copy.\n".utf8
                    ))
                }
                Swift.print(projectURL.path)
                return
            }

            let showProgress = !resolved.quiet && isatty(fileno(stderr)) != 0
            let installer = DemoProjectInstaller()
            do {
                let result = try await installer.install(project, into: destination, replaceExisting: force) { phase in
                    guard !resolved.quiet else { return }
                    DemoCommand.reportProgress(phase, interactive: showProgress)
                }
                if showProgress { FileHandle.standardError.write(Data("\n".utf8)) }
                if result.replacedPreviousCopy, !resolved.quiet {
                    let location = result.previousCopyTrashURL?.path ?? "the Trash"
                    FileHandle.standardError.write(Data("Moved the previous copy to \(location).\n".utf8))
                }
                if resolved.outputFormat == .json {
                    Swift.print(try DemoCommand.encodeJSON(DemoCommand.report(for: project, in: destination)))
                } else {
                    Swift.print(result.projectURL.path)
                }
            } catch {
                if showProgress { FileHandle.standardError.write(Data("\n".utf8)) }
                throw error
            }
        }
    }

    static func reportProgress(_ phase: DemoProjectInstallPhase, interactive: Bool) {
        let line: String
        switch phase {
        case .downloading(let received, let total):
            guard interactive else { return }
            if let total, total > 0 {
                let percent = Int((Double(received) / Double(total) * 100).rounded())
                line = "\rDownloading… \(percent)% (\(formatBytes(received)) of \(formatBytes(total)))"
            } else {
                line = "\rDownloading… \(formatBytes(received))"
            }
        case .verifying:
            line = (interactive ? "\n" : "") + "Verifying size and SHA-256…\n"
        case .extracting:
            line = "Unpacking…\n"
        case .installing:
            line = "Installing…\n"
        }
        FileHandle.standardError.write(Data(line.utf8))
    }
}
