// CzIdProjectImportWorkflow.swift - Shared first-class CZ-ID project import workflow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

public struct CzIdProjectImportResult: Sendable {
    public let bundleURL: URL
    public let sampleName: String
    public let command: [String]
    public let conversion: CzIdConversion
}

public enum CzIdProjectImportWorkflow {
    public static func importFromURL(
        _ sourceURL: URL,
        projectURL: URL,
        sampleName requestedSampleName: String? = nil,
        metadataURL: URL? = nil,
        nonHostFastqURL: URL? = nil
    ) async throws -> CzIdProjectImportResult {
        let projectURL = projectURL.standardizedFileURL
        let fileManager = FileManager.default
        let classificationsURL = projectURL.appendingPathComponent("Classifications", isDirectory: true)

        return try await CzIdImportPreview.withResolvedReport(from: sourceURL) { resolved in
            let parsed = try CzIdDataConverter.parseTaxonReport(at: resolved.reportURL)
            let trimmedSampleName = requestedSampleName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sampleName = (trimmedSampleName?.isEmpty == false ? trimmedSampleName : nil)
                ?? parsed.metadata.sampleName
                ?? resolved.reportURL.deletingPathExtension().lastPathComponent
            let bundleURL = classificationsURL.appendingPathComponent(
                "\(bundleFileName(for: sampleName)).lungfishtax",
                isDirectory: true
            )

            guard !fileManager.fileExists(atPath: bundleURL.path) else {
                throw CzIdProjectImportError.bundleAlreadyExists(bundleURL)
            }
            try fileManager.createDirectory(at: classificationsURL, withIntermediateDirectories: true)

            var command = [
                "lungfish",
                "import",
                "cz-id",
                sourceURL.path,
                "--project",
                projectURL.path,
                "--sample-name",
                sampleName,
            ]
            if let metadataURL {
                command.append(contentsOf: ["--metadata", metadataURL.path])
            }
            if let nonHostFastqURL {
                command.append(contentsOf: ["--non-host-fastq", nonHostFastqURL.path])
            }

            let conversion = try CzIdDataConverter.convertTaxonReport(
                at: resolved.reportURL,
                outputDirectory: bundleURL,
                command: command,
                sourceInputURL: resolved.selectedSourceURL,
                sampleNameOverride: sampleName,
                additionalInputURLs: [metadataURL, nonHostFastqURL].compactMap { $0 },
                provenanceToolName: "lungfish import cz-id",
                provenanceParameters: [
                    "project": .file(projectURL),
                    "sampleName": .string(sampleName),
                    "czIdSchemaVersion": .string(CzIdDataConverter.schemaVersion),
                    "sourcePath": .file(sourceURL),
                    "outputBundle": .file(bundleURL),
                    "metadataPath": metadataURL.map(ParameterValue.file) ?? .null,
                    "nonHostFastqPath": nonHostFastqURL.map(ParameterValue.file) ?? .null,
                ]
            )

            return CzIdProjectImportResult(
                bundleURL: bundleURL,
                sampleName: sampleName,
                command: command,
                conversion: conversion
            )
        }
    }

    public static func bundleFileName(for sampleName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = sampleName.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let name = String(scalars)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return name.isEmpty ? "cz-id-sample" : name
    }
}

public enum CzIdProjectImportError: LocalizedError, Equatable {
    case bundleAlreadyExists(URL)

    public var errorDescription: String? {
        switch self {
        case .bundleAlreadyExists(let url):
            return "Classification bundle already exists: \(url.path)"
        }
    }
}
