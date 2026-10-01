// ProvenancePathPresentation.swift - A recorded path as a reader should see it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A record names files by the absolute path they had when the run was
// recorded. Read from inside a project, a file that lives in that project
// is better named by its project-relative path, a file the run wrote to a
// scratch folder or another machine's project and that no longer exists is
// an intermediate the project did not keep, and a file outside the project
// is best named by its file name. The recorded path stays available for a
// tooltip and for assistive technology, so nothing is lost.

import Foundation
import LungfishCore

public struct ProvenancePathPresentation: Sendable, Equatable {
    public enum Location: Sendable, Equatable {
        /// Under the project the record is read from.
        case project
        /// Under some other `.lungfish` project root.
        case otherProject
        /// A `pipe:` stream between two piped steps, not a file.
        case stream
        /// Anywhere else: a scratch folder, a temporary root, or a
        /// user-chosen location outside the project.
        case external
    }

    public static let intermediateDetail = "intermediate file, not kept"
    public static let outsideProjectDetail = "outside the project"
    public static let otherProjectDetail = "in another project"
    public static let streamDetail = "stream between piped steps"

    /// The path as the record names it, after any re-rooting on read.
    public let recordedPath: String
    public let location: Location
    /// The text to show: a project-relative path, a file name, or a stream name.
    public let label: String
    /// True when the file exists at the recorded path.
    public let isPresent: Bool
    /// A short note on where the file is, or nil for a present project file.
    public let detail: String?

    public init(recordedPath: String, location: Location, label: String, isPresent: Bool, detail: String?) {
        self.recordedPath = recordedPath
        self.location = location
        self.label = label
        self.isPresent = isPresent
        self.detail = detail
    }

    /// The label with its note, for a list of paths on one line each.
    public var listLabel: String {
        guard let detail else { return label }
        return "\(label) (\(detail))"
    }

    /// The tooltip: the note, then the recorded path.
    public var helpText: String {
        guard let detail else { return recordedPath }
        return "\(detail.capitalizedFirst). \(recordedPath)"
    }

    /// The accessibility value: the note, then the recorded path.
    public var accessibilityValue: String {
        helpText
    }

    /// Presents `path` for a record read from inside `projectURL` (nil
    /// outside any project, which leaves the path as recorded).
    public static func present(
        _ path: String,
        projectURL: URL?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ProvenancePathPresentation {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("pipe:") {
            let parts = trimmed.split(separator: ":", maxSplits: 2).map(String.init)
            let label = parts.count == 3 ? "\(parts[1]) of \(parts[2])" : trimmed
            return .init(recordedPath: path, location: .stream, label: label, isPresent: false, detail: streamDetail)
        }
        guard let projectURL else {
            return .init(recordedPath: path, location: .external, label: path, isPresent: fileExists(path), detail: nil)
        }
        let projectPath = projectURL.standardizedFileURL.path
        let projectPrefix = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        let exists = !PortablePath.containsUnresolvedPlaceholder(trimmed) && fileExists(trimmed)

        if trimmed.hasPrefix(projectPrefix) {
            let tail = String(trimmed.dropFirst(projectPrefix.count))
            return .init(
                recordedPath: path, location: .project, label: tail.isEmpty ? trimmed : tail,
                isPresent: exists, detail: exists ? nil : intermediateDetail
            )
        }
        if let tail = tailUnderProjectRoot(trimmed) {
            return .init(
                recordedPath: path, location: .otherProject, label: tail,
                isPresent: exists, detail: exists ? otherProjectDetail : intermediateDetail
            )
        }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        let isScratch = trimmed.contains(PortablePath.workspacePlaceholder) || isUnderTemporaryRoot(trimmed)
        return .init(
            recordedPath: path, location: .external, label: name.isEmpty ? trimmed : name,
            isPresent: exists, detail: (!exists && isScratch) ? intermediateDetail : outsideProjectDetail
        )
    }

    /// The path after the first `<name>.lungfish/` component, or nil.
    private static func tailUnderProjectRoot(_ path: String) -> String? {
        guard let range = path.range(of: ".lungfish/") else { return nil }
        let tail = String(path[range.upperBound...])
        return tail.isEmpty ? nil : tail
    }

    private static func isUnderTemporaryRoot(_ path: String) -> Bool {
        let roots = PortablePath.defaultTemporaryRoots.map { $0.standardizedFileURL.path }
            + ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        return roots.contains { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
