// MSAClipboardExportArtifact.swift - Durable evidence for alignment clipboard exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import CryptoKit
import Foundation
import LungfishCore

/// A clipboard export remains a real CLI output, so its provenance never points
/// to a staging file that disappears after the text reaches the pasteboard.
struct MSAClipboardExportArtifact: Sendable {
    static let provenanceType = NSPasteboard.PasteboardType("org.lungfish.provenance+json")

    let outputURL: URL
    let text: String
    let byteCount: Int
    let provenance: Data

    enum ArtifactError: Error, LocalizedError {
        case invalidProvenance
        case invalidText

        var errorDescription: String? {
            switch self {
            case .invalidProvenance:
                return "The exported alignment does not match its provenance. The clipboard was not changed."
            case .invalidText:
                return "The exported alignment is not valid UTF-8 text. The clipboard was not changed."
            }
        }
    }

    private struct ExportEvidence: Decodable {
        struct OutputFile: Decodable {
            let path: String
            let checksumSHA256: String
            let fileSize: Int64
        }
        let outputFile: OutputFile
        let exitStatus: Int
    }

    static func createOutputURL(applicationSupportDirectory: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let support = applicationSupportDirectory
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = support
            .appendingPathComponent(LungfishAppIdentity.current.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Clipboard Exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("alignment.fasta")
    }

    static func load(from outputURL: URL) throws -> MSAClipboardExportArtifact {
        let data = try Data(contentsOf: outputURL)
        let provenance = try Data(contentsOf: outputURL.appendingPathExtension("lungfish-provenance.json"))
        let evidence = try JSONDecoder().decode(ExportEvidence.self, from: provenance)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard evidence.exitStatus == 0,
              URL(fileURLWithPath: evidence.outputFile.path).standardizedFileURL == outputURL.standardizedFileURL,
              evidence.outputFile.fileSize == Int64(data.count),
              evidence.outputFile.checksumSHA256.lowercased() == checksum else {
            throw ArtifactError.invalidProvenance
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ArtifactError.invalidText
        }
        return MSAClipboardExportArtifact(outputURL: outputURL, text: text, byteCount: data.count, provenance: provenance)
    }

    @MainActor
    func write(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(provenance, forType: Self.provenanceType)
        pasteboard.setString(outputURL.absoluteString, forType: .fileURL)
    }
}
