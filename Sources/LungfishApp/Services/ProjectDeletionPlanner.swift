// ProjectDeletionPlanner.swift - Dependency-aware project deletion planning
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

struct ProjectDeletionImpact: Equatable {
    let selectedURLs: [URL]
    let dependentURLs: [URL]

    var hasDependents: Bool {
        !dependentURLs.isEmpty
    }

    var urlsForCascadingDeletion: [URL] {
        ProjectDeletionPlanner.topLevelURLsForDeletion(selectedURLs + dependentURLs)
    }
}

struct ProjectDeletionDependencyListPresentation: Equatable {
    let dependentURLs: [URL]
    let projectURL: URL?
    let previewLimit: Int

    init(dependentURLs: [URL], projectURL: URL?, previewLimit: Int = 8) {
        self.dependentURLs = dependentURLs.map(\.standardizedFileURL)
        self.projectURL = projectURL?.standardizedFileURL
        self.previewLimit = max(0, previewLimit)
    }

    var count: Int {
        dependentURLs.count
    }

    var isTruncated: Bool {
        dependentURLs.count > previewLimit
    }

    var previewLines: [String] {
        dependentURLs.prefix(previewLimit).map(\.lastPathComponent)
    }

    var overflowLine: String? {
        guard isTruncated else { return nil }
        return "... and \(dependentURLs.count - previewLimit) more"
    }

    var fullListLines: [String] {
        dependentURLs.map { Self.displayPath(for: $0, projectURL: projectURL) }
    }

    var fullListText: String {
        fullListLines.joined(separator: "\n")
    }

    private static func displayPath(for url: URL, projectURL: URL?) -> String {
        let path = url.standardizedFileURL.path
        guard let projectURL else { return path }

        let projectPath = projectURL.standardizedFileURL.path
        let normalizedProjectPath = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        guard path.hasPrefix(normalizedProjectPath) else {
            return path
        }
        return String(path.dropFirst(normalizedProjectPath.count))
    }
}

final class ProjectDeletionPlanner {
    private struct ProjectObjectRecord {
        let url: URL
        let dependencyURLs: [URL]
    }

    private let fileManager: FileManager
    private let maxMetadataFileBytes: UInt64 = 5 * 1024 * 1024

    /// Directory extensions for every opaque project-object bundle. A directory
    /// with one of these extensions is treated as a single object: the planner
    /// recognizes it as a project object and never enumerates into its internal
    /// files. Keep this as the single source of truth so the two consumers
    /// (`isProjectObjectDirectory` and `isInsideProjectObjectContainer`) stay in
    /// sync as new bundle types ship. Use the typed `directoryExtension`
    /// constants where they exist; the remaining entries have no typed constant
    /// and are used as string literals across the codebase.
    static let projectObjectDirectoryExtensions: Set<String> = [
        FASTQBundle.directoryExtension,
        MultipleSequenceAlignmentBundle.directoryExtension,
        ONTGenotypeResultBundle.directoryExtension,
        MHCAmpliconReferenceBundle.directoryExtension,
        TwelveSReferenceBundle.directoryExtension,
        TwelveSAmpliconResultBundle.directoryExtension,
        "lungfishref",
        "lungfishtree",
        "lungfishprimers",
        "lungfishtax",
    ]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func impact(ofDeleting selectedURLs: [URL], in projectURL: URL) -> ProjectDeletionImpact {
        let normalizedSelected = uniqueURLs(selectedURLs)
        guard !normalizedSelected.isEmpty else {
            return ProjectDeletionImpact(selectedURLs: [], dependentURLs: [])
        }

        let records = collectProjectObjectRecords(in: projectURL)
            .filter { record in
                !isCoveredByDeletionTargets(record.url, targets: normalizedSelected)
            }
        let objectKeySet = Set(records.map { urlKey($0.url) })
        let dependentsByDependencyKey = buildReverseDependencyIndex(
            records: records,
            objectKeySet: objectKeySet,
            projectURL: projectURL
        )

        var queue = normalizedSelected.map(urlKey)
        var queueIndex = 0
        var dependentURLs: [URL] = []
        var dependentSet = Set<String>()

        func addDependent(_ url: URL) {
            let key = urlKey(url)
            guard !dependentSet.contains(key),
                  !isCoveredByDeletionTargets(url, targets: normalizedSelected) else {
                return
            }
            dependentSet.insert(key)
            dependentURLs.append(url)
            queue.append(key)
        }

        for record in records where dependencyURLs(record.dependencyURLs, areCoveredByAnyOf: normalizedSelected) {
            addDependent(record.url)
        }

        while queueIndex < queue.count {
            let targetKey = queue[queueIndex]
            queueIndex += 1

            for dependent in dependentsByDependencyKey[targetKey] ?? [] {
                addDependent(dependent)
            }
        }

        return ProjectDeletionImpact(
            selectedURLs: normalizedSelected,
            dependentURLs: dependentURLs
        )
    }

    func existingCompanionSidecarURLs(for url: URL) -> [URL] {
        Self.companionSidecarCandidates(for: url)
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted(by: stableURLSort)
    }

    static func topLevelURLsForDeletion(_ urls: [URL]) -> [URL] {
        let normalized = uniqueURLs(urls)
        return normalized
            .filter { candidate in
                !normalized.contains { other in
                    !sameURL(candidate, other) && isAncestor(other, of: candidate)
                }
            }
            .sorted(by: stableURLSort)
    }

    static func companionSidecarCandidates(for url: URL) -> [URL] {
        let standardized = url.standardizedFileURL
        let adjacentSidecars = [
            standardized.appendingPathExtension("lungfish-meta.json"),
            standardized.appendingPathExtension("lungfish-provenance.json"),
        ]
        let appleDoubleSidecars = adjacentSidecars.map { sidecar in
            sidecar.deletingLastPathComponent()
                .appendingPathComponent("._\(sidecar.lastPathComponent)")
        }
        let appleDoubleObject = standardized.deletingLastPathComponent()
            .appendingPathComponent("._\(standardized.lastPathComponent)")
        return uniqueURLs(adjacentSidecars + appleDoubleSidecars + [appleDoubleObject])
    }

    private func collectProjectObjectRecords(in projectURL: URL) -> [ProjectObjectRecord] {
        collectProjectObjects(in: projectURL).map { objectURL in
            ProjectObjectRecord(
                url: objectURL,
                dependencyURLs: structuredDependencyURLs(for: objectURL, projectURL: projectURL)
            )
        }
    }

    private func collectProjectObjects(in projectURL: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var objects: [URL] = []
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            let values = try? standardized.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let isDirectory = values?.isDirectory == true

            if isDirectory {
                if shouldSkipDirectoryDescendants(standardized) {
                    enumerator.skipDescendants()
                    continue
                }
                if isProjectObjectDirectory(standardized) {
                    objects.append(standardized)
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true,
                  isProjectObjectFile(standardized),
                  !isInsideProjectObjectContainer(standardized, projectURL: projectURL) else {
                continue
            }
            objects.append(standardized)
        }

        return uniqueURLs(objects).sorted(by: stableURLSort)
    }

    private func buildReverseDependencyIndex(
        records: [ProjectObjectRecord],
        objectKeySet: Set<String>,
        projectURL: URL
    ) -> [String: [URL]] {
        var index: [String: Set<String>] = [:]
        var urlsByKey: [String: URL] = [:]

        for record in records {
            let recordKey = urlKey(record.url)
            urlsByKey[recordKey] = record.url

            for dependencyURL in record.dependencyURLs {
                let dependencyKey = canonicalDependencyKey(
                    for: dependencyURL,
                    objectKeySet: objectKeySet,
                    projectURL: projectURL
                )
                index[dependencyKey, default: []].insert(recordKey)
            }
        }

        return index.mapValues { keys in
            keys.compactMap { urlsByKey[$0] }.sorted(by: stableURLSort)
        }
    }

    private func canonicalDependencyKey(
        for dependencyURL: URL,
        objectKeySet: Set<String>,
        projectURL: URL
    ) -> String {
        let projectPath = projectURL.standardizedFileURL.path
        let normalizedProjectPath = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        var candidate = dependencyURL.standardizedFileURL

        while candidate.path == projectPath || candidate.path.hasPrefix(normalizedProjectPath) {
            let key = urlKey(candidate)
            if objectKeySet.contains(key) {
                return key
            }

            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }

        return urlKey(dependencyURL)
    }

    private func dependencyURLs(_ dependencyURLs: [URL], areCoveredByAnyOf targetURLs: [URL]) -> Bool {
        dependencyURLs.contains { dependencyURL in
            targetURLs.contains { targetURL in
                Self.isAncestor(targetURL, of: dependencyURL) || sameURL(targetURL, dependencyURL)
            }
        }
    }

    private func structuredDependencyURLs(for objectURL: URL, projectURL: URL) -> [URL] {
        var dependencies: [URL] = []

        for metadataURL in metadataFiles(in: objectURL) where metadataURL.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: metadataURL),
                  UInt64(data.count) <= maxMetadataFileBytes,
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            let strings = dependencyStrings(in: json, dependencyContext: false)
            dependencies.append(contentsOf: strings.compactMap {
                resolveDependencyString($0, objectURL: objectURL, metadataURL: metadataURL, projectURL: projectURL)
            })
        }

        return uniqueURLs(dependencies)
    }

    private func metadataFiles(in objectURL: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: objectURL.path, isDirectory: &isDirectory) else {
            return []
        }

        if !isDirectory.boolValue {
            return shouldScanMetadataFile(objectURL) ? [objectURL] : []
        }

        if isProjectObjectDirectory(objectURL) {
            return topLevelMetadataFiles(in: objectURL)
        }

        guard let enumerator = fileManager.enumerator(
            at: objectURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            let values = try? standardized.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values?.isDirectory == true {
                if shouldSkipDirectoryDescendants(standardized) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true,
                  shouldScanMetadataFile(standardized),
                  UInt64(values?.fileSize ?? 0) <= maxMetadataFileBytes else {
                continue
            }
            urls.append(standardized)
        }
        return urls.sorted(by: stableURLSort)
    }

    private func topLevelMetadataFiles(in directoryURL: URL) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.compactMap { url -> URL? in
            let standardized = url.standardizedFileURL
            let values = try? standardized.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                  shouldScanMetadataFile(standardized),
                  UInt64(values?.fileSize ?? 0) <= maxMetadataFileBytes else {
                return nil
            }
            return standardized
        }
        .sorted(by: stableURLSort)
    }

    private func dependencyStrings(in value: Any, dependencyContext: Bool) -> [String] {
        if let string = value as? String {
            guard dependencyContext, looksLikeDependencyString(string) else { return [] }
            return [string]
        }
        if let array = value as? [Any] {
            return array.flatMap { dependencyStrings(in: $0, dependencyContext: dependencyContext) }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, nestedValue -> [String] in
                dependencyStrings(
                    in: nestedValue,
                    dependencyContext: dependencyContext || isDependencyKey(key)
                )
            }
        }
        return []
    }

    private func isDependencyKey(_ key: String) -> Bool {
        let lowercased = key.lowercased()
        return lowercased.contains("path")
            || lowercased.contains("url")
            || lowercased.contains("file")
            || lowercased.contains("bundle")
            || lowercased.contains("input")
            || lowercased.contains("source")
    }

    private func resolveDependencyString(
        _ value: String,
        objectURL: URL,
        metadataURL: URL,
        projectURL: URL
    ) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("@/") {
            return projectURL
                .appendingPathComponent(String(trimmed.dropFirst(2)))
                .standardizedFileURL
        }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }

        guard looksLikeDependencyString(trimmed) else { return nil }

        if FASTQBundle.isBundleURL(objectURL), trimmed.contains(".lungfish") || trimmed.contains("/") {
            return URL(fileURLWithPath: trimmed, relativeTo: objectURL)
                .standardizedFileURL
                .absoluteURL
        }

        return URL(fileURLWithPath: trimmed, relativeTo: metadataURL.deletingLastPathComponent())
            .standardizedFileURL
            .absoluteURL
    }

    private func isProjectObjectDirectory(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if Self.projectObjectDirectoryExtensions.contains(ext) {
            return true
        }

        let markerNames = [
            "analysis-metadata.json",
            "alignment-result.json",
            "assembly-result.json",
            "classification-batch-result.json",
            "classification-result.json",
            "cz-id-manifest.json",
            "esviritu-batch-result.json",
            "esviritu-result.json",
            "mapping-result.json",
            "scout-result.json",
            "taxtriage-batch-manifest.json",
            "taxtriage-result.json",
        ]
        if markerNames.contains(where: { fileManager.fileExists(atPath: url.appendingPathComponent($0).path) }) {
            return true
        }

        let isAnalysisLikeManifestDirectory = url.pathComponents.contains("Analyses")
            || url.lastPathComponent.hasPrefix("naomgs-")
            || url.lastPathComponent.hasPrefix("nvd-")
        if fileManager.fileExists(atPath: url.appendingPathComponent("manifest.json").path),
           isAnalysisLikeManifestDirectory {
            return true
        }

        return false
    }

    private func isProjectObjectFile(_ url: URL) -> Bool {
        guard !isInternalSidecarFile(url) else { return false }
        return !url.pathExtension.isEmpty
    }

    private func shouldScanMetadataFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if name.hasPrefix("._") || name == ".ds_store" { return false }
        if name == "source-files.json"
            || name == "derived.manifest.json"
            || name == "read-manifest.json"
            || name == "mapping-result.json"
            || name == "analysis-metadata.json"
            || name == "classification-result.json"
            || name == "classification-batch-result.json"
            || name == "assembly-result.json"
            || name == "alignment-result.json"
            || name == "taxtriage-result.json"
            || name == "taxtriage-batch-manifest.json"
            || name == "esviritu-result.json"
            || name == "esviritu-batch-result.json"
            || name == "cz-id-manifest.json"
            || name == "manifest.json"
            || name == ".lungfish-provenance.json"
            || name.hasSuffix(".lungfish-meta.json")
            || name.hasSuffix(".lungfish-provenance.json")
            || name.hasSuffix("-provenance.json") {
            return true
        }
        return ext == "json"
    }

    private func isInternalSidecarFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if name.hasPrefix("._") || name == ".ds_store" { return true }
        if ["bai", "csi", "fai", "gzi", "tbi"].contains(ext) { return true }
        if name.hasSuffix(".lungfish-meta.json")
            || name.hasSuffix(".lungfish-provenance.json")
            || name.hasSuffix("-provenance.json") {
            return true
        }
        return [
            "analysis-metadata.json",
            "alignment-result.json",
            "assembly-result.json",
            "batch.manifest.json",
            "classification-batch-result.json",
            "classification-result.json",
            "cz-id-manifest.json",
            "demux-manifest.json",
            "derived.manifest.json",
            "esviritu-batch-result.json",
            "esviritu-result.json",
            "extraction-metadata.json",
            ONTGenotypeResultBundleManifest.filename,
            "mapping-result.json",
            "manifest.json",
            "read-manifest.json",
            "scout-result.json",
            "source-files.json",
            "taxtriage-batch-manifest.json",
            "taxtriage-result.json",
        ].contains(name)
    }

    private func shouldSkipDirectoryDescendants(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name == ".tmp"
            || name == "chunks"
            || name == "materialized"
            || name == "provenance"
            || name == "genome"
            || name == "annotations"
            || name == "indices"
            || name == "__macosx" {
            return true
        }
        if name.hasPrefix("cli-output-") || name.hasPrefix("materialized-inputs-") {
            return true
        }
        return false
    }

    private func isInsideProjectObjectContainer(_ url: URL, projectURL: URL) -> Bool {
        let projectPath = projectURL.standardizedFileURL.path
        let components = url.standardizedFileURL.pathComponents
        let projectComponents = projectURL.standardizedFileURL.pathComponents
        guard components.count > projectComponents.count else { return false }
        guard url.standardizedFileURL.path.hasPrefix(projectPath) else { return false }

        let relativeComponents = components.dropFirst(projectComponents.count).dropLast()
        return relativeComponents.contains { component in
            let ext = (component as NSString).pathExtension.lowercased()
            return Self.projectObjectDirectoryExtensions.contains(ext)
        }
    }

    private func looksLikeDependencyString(_ value: String) -> Bool {
        value.hasPrefix("/")
            || value.hasPrefix("@/")
            || value.contains(".lungfish")
            || value.contains(".fastq")
            || value.contains(".fq")
            || value.contains(".fasta")
            || value.contains(".fa")
            || value.contains(".bam")
            || value.contains(".sam")
            || value.contains("/")
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        Self.uniqueURLs(urls)
    }

    private func stableURLSort(_ lhs: URL, _ rhs: URL) -> Bool {
        Self.stableURLSort(lhs, rhs)
    }

    private func sameURL(_ lhs: URL, _ rhs: URL) -> Bool {
        Self.sameURL(lhs, rhs)
    }

    private func isCoveredByDeletionTargets(_ url: URL, targets: [URL]) -> Bool {
        targets.contains { Self.isAncestor($0, of: url) }
    }

    private func urlKey(_ url: URL) -> String {
        Self.urlKey(url)
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let normalized = url.standardizedFileURL
            guard seen.insert(urlKey(normalized)).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    private static func sameURL(_ lhs: URL, _ rhs: URL) -> Bool {
        urlKey(lhs) == urlKey(rhs)
    }

    private static func isAncestor(_ ancestor: URL, of descendant: URL) -> Bool {
        let ancestorPath = ancestor.standardizedFileURL.path
        let descendantPath = descendant.standardizedFileURL.path
        if ancestorPath == descendantPath { return true }
        let normalizedAncestor = ancestorPath.hasSuffix("/") ? ancestorPath : ancestorPath + "/"
        return descendantPath.hasPrefix(normalizedAncestor)
    }

    private static func stableURLSort(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path.localizedStandardCompare(rhs.standardizedFileURL.path) == .orderedAscending
    }

    private static func urlKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
