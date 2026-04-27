// ReferenceBundleAnnotationImportService.swift - Attach annotation tracks to existing reference bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let annotationImportLogger = Logger(subsystem: LogSubsystem.app, category: "ReferenceAnnotationImport")

public struct ReferenceBundleChoice: Sendable, Equatable, Identifiable {
    public let url: URL
    public let displayPath: String

    public var id: String { url.standardizedFileURL.path }
}

public struct ReferenceBundleAnnotationImportResult: Sendable, Equatable {
    public let bundleURL: URL
    public let track: AnnotationTrackInfo
    public let featureCount: Int
}

public enum ReferenceBundleAnnotationImportError: Error, LocalizedError {
    case unsupportedFormat(URL)
    case missingManifest(URL)
    case missingGenome(URL)
    case duplicateTrackID(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let url):
            return "\(url.lastPathComponent) is not a supported annotation format. Use GTF, GFF, GFF3, or BED."
        case .missingManifest(let url):
            return "\(url.lastPathComponent) is not a valid reference bundle."
        case .missingGenome(let url):
            return "\(url.lastPathComponent) does not contain genome sequence metadata for annotation import."
        case .duplicateTrackID(let id):
            return "This bundle already has an annotation track named \(id)."
        }
    }
}

@MainActor
public final class ReferenceBundleAnnotationImportService {
    public init() {}

    public static func discoverReferenceBundles(
        in projectURL: URL,
        fileManager: FileManager = .default
    ) throws -> [ReferenceBundleChoice] {
        var choices: [ReferenceBundleChoice] = []
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "lungfishref" else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            guard (try? BundleManifest.load(from: url).genome) != nil else { continue }
            choices.append(
                ReferenceBundleChoice(
                    url: url.standardizedFileURL,
                    displayPath: projectRelativePath(from: projectURL, to: url)
                )
            )
            enumerator.skipDescendants()
        }

        return choices.sorted {
            $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath) == .orderedAscending
        }
    }

    public func attachAnnotationTrack(
        sourceURL: URL,
        bundleURL: URL
    ) async throws -> ReferenceBundleAnnotationImportResult {
        guard ReferenceBundleImportService.classify(sourceURL) == .annotationTrack else {
            throw ReferenceBundleAnnotationImportError.unsupportedFormat(sourceURL)
        }

        var manifest: BundleManifest
        do {
            manifest = try BundleManifest.load(from: bundleURL)
        } catch {
            throw ReferenceBundleAnnotationImportError.missingManifest(bundleURL)
        }
        guard let genome = manifest.genome else {
            throw ReferenceBundleAnnotationImportError.missingGenome(bundleURL)
        }

        let annotationsDir = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)

        let trackID = makeUniqueTrackID(
            base: sanitizedTrackID(for: sourceURL),
            existingIDs: Set(manifest.annotations.map(\.id)),
            annotationsDir: annotationsDir
        )
        let databasePath = "annotations/\(trackID).db"
        let databaseURL = bundleURL.appendingPathComponent(databasePath)
        let chromosomeSizes = genome.chromosomes.map { ($0.name, $0.length) }

        let featureCount: Int
        let ext = ReferenceBundleImportService.normalizedExtension(for: sourceURL)
        if ["gff", "gff3", "gtf"].contains(ext) {
            featureCount = try await AnnotationDatabase.createFromGFF3(
                gffURL: sourceURL,
                outputURL: databaseURL,
                chromosomeSizes: chromosomeSizes
            )
        } else if ext == "bed" {
            featureCount = try AnnotationDatabase.createFromBED(bedURL: sourceURL, outputURL: databaseURL)
        } else {
            throw ReferenceBundleAnnotationImportError.unsupportedFormat(sourceURL)
        }

        let track = AnnotationTrackInfo(
            id: trackID,
            name: sourceURL.deletingPathExtension().lastPathComponent,
            description: "Imported from \(sourceURL.lastPathComponent)",
            path: databasePath,
            databasePath: featureCount > 0 ? databasePath : nil,
            annotationType: .custom,
            featureCount: featureCount,
            source: sourceURL.path
        )

        manifest = manifest.addingAnnotationTrack(track)
        try manifest.save(to: bundleURL)
        annotationImportLogger.info("Attached annotation track \(trackID, privacy: .public) to \(bundleURL.lastPathComponent, privacy: .public)")

        return ReferenceBundleAnnotationImportResult(bundleURL: bundleURL, track: track, featureCount: featureCount)
    }

    private func sanitizedTrackID(for sourceURL: URL) -> String {
        var baseURL = sourceURL
        if ReferenceBundleImportService.compressionExtensions.contains(baseURL.pathExtension.lowercased()) {
            baseURL = baseURL.deletingPathExtension()
        }
        let raw = baseURL.deletingPathExtension().lastPathComponent.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let collapsed = String(scalars)
            .split(separator: "_")
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return collapsed.isEmpty ? "annotations" : collapsed
    }

    private func makeUniqueTrackID(
        base: String,
        existingIDs: Set<String>,
        annotationsDir: URL
    ) -> String {
        var candidate = base
        var index = 2
        while existingIDs.contains(candidate)
            || FileManager.default.fileExists(atPath: annotationsDir.appendingPathComponent("\(candidate).db").path) {
            candidate = "\(base)_\(index)"
            index += 1
        }
        return candidate
    }

    private static func projectRelativePath(from projectURL: URL, to targetURL: URL) -> String {
        let projectPath = projectURL.standardizedFileURL.path
        let targetPath = targetURL.standardizedFileURL.path
        let normalizedProjectPath = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        guard targetPath.hasPrefix(normalizedProjectPath) else { return targetPath }
        return String(targetPath.dropFirst(normalizedProjectPath.count))
    }
}
