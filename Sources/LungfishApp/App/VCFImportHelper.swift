// VCFImportHelper.swift - Headless helper-mode VCF importer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Helper-mode entrypoint used by the GUI process to import VCF out-of-process.
///
/// Invoked by launching the same app executable with `--vcf-import-helper` and
/// passing import parameters as command-line options.
public enum VCFImportHelper {
    private struct Event: Codable {
        let event: String
        let progress: Double?
        let message: String?
        let variantCount: Int?
        let error: String?
        let profile: String?
    }

    public static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.contains("--vcf-import-helper") else { return nil }

        guard let vcfPath = value(for: "--vcf-path", in: arguments),
              let outputDBPath = value(for: "--output-db-path", in: arguments)
        else {
            emit(Event(
                event: "error",
                progress: nil,
                message: nil,
                variantCount: nil,
                error: "Missing required helper arguments: --vcf-path and --output-db-path",
                profile: nil
            ))
            return 2
        }

        let requestedProfile = parseProfile(value(for: "--import-profile", in: arguments)) ?? .auto
        let sourceFile = value(for: "--source-file", in: arguments)
            ?? URL(fileURLWithPath: vcfPath).lastPathComponent

        emit(Event(
            event: "started",
            progress: 0.0,
            message: "Starting helper import",
            variantCount: nil,
            error: nil,
            profile: requestedProfile.rawValue
        ))

        do {
            let variantCount = try VariantDatabase.createFromVCF(
                vcfURL: URL(fileURLWithPath: vcfPath),
                outputURL: URL(fileURLWithPath: outputDBPath),
                parseGenotypes: true,
                sourceFile: sourceFile,
                progressHandler: { progress, message in
                    emit(Event(
                        event: "progress",
                        progress: max(0.0, min(1.0, progress)),
                        message: message,
                        variantCount: nil,
                        error: nil,
                        profile: nil
                    ))
                },
                shouldCancel: nil,
                importProfile: requestedProfile
            )

            emit(Event(
                event: "done",
                progress: 1.0,
                message: "Import complete",
                variantCount: variantCount,
                error: nil,
                profile: requestedProfile.rawValue
            ))
            return 0
        } catch let error as VariantDatabaseError {
            if case .cancelled = error {
                emit(Event(
                    event: "cancelled",
                    progress: nil,
                    message: "Import cancelled",
                    variantCount: nil,
                    error: nil,
                    profile: requestedProfile.rawValue
                ))
                return 125
            }

            emit(Event(
                event: "error",
                progress: nil,
                message: nil,
                variantCount: nil,
                error: error.localizedDescription,
                profile: requestedProfile.rawValue
            ))
            return 1
        } catch {
            emit(Event(
                event: "error",
                progress: nil,
                message: nil,
                variantCount: nil,
                error: error.localizedDescription,
                profile: requestedProfile.rawValue
            ))
            return 1
        }
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func parseProfile(_ raw: String?) -> VCFImportProfile? {
        guard let raw else { return nil }
        if let profile = VCFImportProfile(rawValue: raw) {
            return profile
        }
        switch raw.lowercased() {
        case "low", "low-memory", "low_memory":
            return .lowMemory
        case "fast":
            return .fast
        case "auto":
            return .auto
        default:
            return nil
        }
    }

    private static func emit(_ event: Event) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
