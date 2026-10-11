// ProvenanceWriter+BundleOutputs.swift - The outputs of a bundle that get a record of their own
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ProvenanceWriter {
    struct BundleOutputEntry {
        let descriptor: ProvenanceFileDescriptor
        let relativePath: String
    }

    func bundleOutputEntries(
        from envelope: ProvenanceEnvelope,
        relativeTo bundleURL: URL
    ) -> [BundleOutputEntry] {
        let descriptors = envelope.steps.flatMap(\.outputs)
            + (envelope.output.map { [$0] } ?? [])
            + envelope.outputs
        var orderedKeys: [String] = []
        var entriesByKey: [String: BundleOutputEntry] = [:]
        var entries: [BundleOutputEntry] = []
        for descriptor in descriptors {
            guard let relativePath = Self.bundleRelativePath(for: descriptor.path, relativeTo: bundleURL),
                  !isDirectoryOutput(descriptor, relativePath: relativePath, bundleURL: bundleURL) else {
                continue
            }
            if entriesByKey[relativePath] == nil {
                orderedKeys.append(relativePath)
            }
            entriesByKey[relativePath] = BundleOutputEntry(descriptor: descriptor, relativePath: relativePath)
        }
        for key in orderedKeys {
            if let entry = entriesByKey[key] {
                entries.append(entry)
            }
        }
        return entries
    }

    func isDirectoryOutput(
        _ descriptor: ProvenanceFileDescriptor,
        relativePath: String,
        bundleURL: URL
    ) -> Bool {
        let outputURL = descriptor.path.hasPrefix("/")
            ? URL(fileURLWithPath: descriptor.path)
            : bundleURL.appendingPathComponent(relativePath)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func bundleRelativePath(for path: String, relativeTo bundleURL: URL) -> String? {
        if path.hasPrefix("/") {
            let bundleComponents = bundleURL.standardizedFileURL.pathComponents
            let outputComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            guard outputComponents.starts(with: bundleComponents),
                  outputComponents.count > bundleComponents.count else {
                return nil
            }
            let relativeComponents = outputComponents.dropFirst(bundleComponents.count)
            guard relativeComponents.first != Self.bundleProvenanceDirectoryName else {
                return nil
            }
            return relativeComponents.joined(separator: "/")
        }

        let components = path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        guard !components.isEmpty,
              !components.contains(".."),
              components.first != Self.bundleProvenanceDirectoryName else {
            return nil
        }
        return components.joined(separator: "/")
    }

    static func bundleOutputSidecarURL(
        forRelativeOutputPath relativePath: String,
        inProvenanceDirectory provenanceDirectory: URL
    ) -> URL {
        var components = relativePath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        let filename = (components.popLast() ?? "output") + ".lungfish-provenance.json"
        var directory = provenanceDirectory
        for component in components {
            directory = directory.appendingPathComponent(component, isDirectory: true)
        }
        return directory.appendingPathComponent(filename)
    }
}
