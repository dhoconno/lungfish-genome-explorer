// MappingReferenceStager.swift - Runtime reference FASTA normalization for mapper compatibility
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

struct StagedMappingReferenceArtifacts: Sendable, Equatable {
    let referenceURL: URL
    let cleanupURLs: [URL]
}

enum MappingReferenceStager {
    static func stageMapperCompatibleReferenceIfNeeded(
        referenceURL: URL,
        sourceReferenceBundleURL: URL?,
        projectURL: URL?
    ) async throws -> StagedMappingReferenceArtifacts {
        let manifestNames = chromosomeNames(from: sourceReferenceBundleURL)
        let requiresStaging = try await referenceRequiresStaging(
            inputURL: referenceURL,
            manifestNames: manifestNames
        )
        guard requiresStaging else {
            return StagedMappingReferenceArtifacts(referenceURL: referenceURL, cleanupURLs: [])
        }

        let workspace = try ProjectTempDirectory.create(prefix: "mapping-reference-stage-", in: projectURL)
        let stagedURL = workspace.appendingPathComponent("reference.fa")
        try await rewriteReference(
            inputURL: referenceURL,
            outputURL: stagedURL,
            manifestNames: manifestNames
        )

        return StagedMappingReferenceArtifacts(referenceURL: stagedURL, cleanupURLs: [workspace])
    }

    static func enclosingReferenceBundleURL(for url: URL) -> URL? {
        var current = startingDirectory(for: url).standardizedFileURL

        while true {
            if current.pathExtension.lowercased() == "lungfishref" {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.standardizedFileURL == current {
                return nil
            }
            current = parent.standardizedFileURL
        }
    }

    private static func referenceRequiresStaging(
        inputURL: URL,
        manifestNames: [String]
    ) async throws -> Bool {
        var recordIndex = 0

        for try await line in inputURL.linesAutoDecompressing() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }

            if trimmed.hasPrefix(">") {
                let originalHeader = String(trimmed.dropFirst())
                let fallbackName = firstHeaderToken(originalHeader, fallback: "contig_\(recordIndex + 1)")
                let stagedName = manifestNames.indices.contains(recordIndex)
                    ? manifestNames[recordIndex]
                    : fallbackName
                if stagedName != originalHeader {
                    return true
                }
                recordIndex += 1
            } else if trimmed.contains("U") || trimmed.contains("u") {
                return true
            }
        }

        return false
    }

    private static func rewriteReference(
        inputURL: URL,
        outputURL: URL,
        manifestNames: [String]
    ) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        fm.createFile(atPath: outputURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        var recordIndex = 0

        for try await line in inputURL.linesAutoDecompressing() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }

            if trimmed.hasPrefix(">") {
                let originalHeader = String(trimmed.dropFirst())
                let fallbackName = firstHeaderToken(originalHeader, fallback: "contig_\(recordIndex + 1)")
                let stagedName = manifestNames.indices.contains(recordIndex)
                    ? manifestNames[recordIndex]
                    : fallbackName
                try handle.write(contentsOf: Data(">\(stagedName)\n".utf8))
                recordIndex += 1
            } else {
                let converted = convertRNABasesToDNA(in: trimmed)
                try handle.write(contentsOf: Data("\(converted)\n".utf8))
            }
        }
    }

    private static func chromosomeNames(from sourceReferenceBundleURL: URL?) -> [String] {
        guard let sourceReferenceBundleURL,
              let manifest = try? BundleManifest.load(from: sourceReferenceBundleURL),
              let genome = manifest.genome else {
            return []
        }
        return genome.chromosomes.map(\.name)
    }

    private static func firstHeaderToken(_ header: String, fallback: String) -> String {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        guard let whitespaceIndex = trimmed.firstIndex(where: \.isWhitespace) else {
            return trimmed
        }
        let token = String(trimmed[..<whitespaceIndex])
        return token.isEmpty ? fallback : token
    }

    private static func convertRNABasesToDNA(in line: String) -> String {
        String(
            line.map { character in
                switch character {
                case "U":
                    return "T"
                case "u":
                    return "t"
                default:
                    return character
                }
            }
        )
    }

    private static func startingDirectory(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }
}
