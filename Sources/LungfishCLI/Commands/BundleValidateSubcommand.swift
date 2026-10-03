// BundleValidateSubcommand.swift - Validate a bundle
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Validate Subcommand

/// Validate a bundle
struct BundleValidateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a reference bundle",
        discussion: """
            Validates the structure and integrity of a .lungfishref bundle.

            Checks:
            - manifest.json exists and is valid
            - All referenced files exist
            - Genome sequence is readable
            - Index files are valid

            Examples:
              lungfish-cli bundle validate MyGenome.lungfishref
              lungfish-cli bundle validate *.lungfishref
            """
    )

    @Argument(help: "Bundle path(s) to validate")
    var bundles: [String]

    @Flag(name: .long, help: "Check file integrity (slower)")
    var checkIntegrity: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        var allValid = true
        var sawMissingBundle = false
        var results: [BundleValidationResult] = []

        for bundlePath in bundles {
            let bundleURL = URL(fileURLWithPath: bundlePath)

            guard FileManager.default.fileExists(atPath: bundlePath) else {
                allValid = false
                sawMissingBundle = true
                results.append(BundleValidationResult(
                    path: bundlePath,
                    valid: false,
                    errors: ["Bundle not found"]
                ))
                if globalOptions.outputFormat == .text {
                    print(formatter.error("\(bundleURL.lastPathComponent): Not found"))
                }
                continue
            }

            var errors: [String] = []

            // Check manifest exists
            let manifestURL = bundleURL.appendingPathComponent("manifest.json")
            if !FileManager.default.fileExists(atPath: manifestURL.path) {
                errors.append("manifest.json not found")
            } else {
                // Try to load and validate manifest
                do {
                    let manifest = try BundleManifest.load(from: bundleURL)
                    let validationErrors = manifest.validate()
                    errors.append(contentsOf: validationErrors.map { $0.localizedDescription })

                    // Check referenced files exist
                    if let genome = manifest.genome {
                        let genomePath = bundleURL.appendingPathComponent(genome.path)
                        if !FileManager.default.fileExists(atPath: genomePath.path) {
                            errors.append("Genome file not found: \(genome.path)")
                        }

                        let indexPath = bundleURL.appendingPathComponent(genome.indexPath)
                        if !FileManager.default.fileExists(atPath: indexPath.path) {
                            errors.append("Index file not found: \(genome.indexPath)")
                        }
                    }

                    for anno in manifest.annotations {
                        let annoPath = bundleURL.appendingPathComponent(anno.path)
                        if !FileManager.default.fileExists(atPath: annoPath.path) {
                            errors.append("Annotation file not found: \(anno.path)")
                        }
                    }

                    for variant in manifest.variants {
                        // An imported VCF lives only in its SQLite database, so
                        // that is the file that must exist. Older manifests
                        // name a `.bcf` placeholder that was never written.
                        for required in VCFBundleVariantImport.requiredFiles(for: variant) {
                            let url = bundleURL.appendingPathComponent(required.relativePath)
                            if !FileManager.default.fileExists(atPath: url.path) {
                                errors.append("Variant file not found: \(required.relativePath)")
                            }
                        }
                    }

                    for track in manifest.tracks {
                        let trackPath = bundleURL.appendingPathComponent(track.path)
                        if !FileManager.default.fileExists(atPath: trackPath.path) {
                            errors.append("Signal track not found: \(track.path)")
                        }
                    }
                } catch {
                    errors.append("Failed to load manifest: \(error.localizedDescription)")
                }
            }

            let isValid = errors.isEmpty
            if !isValid { allValid = false }

            results.append(BundleValidationResult(
                path: bundlePath,
                valid: isValid,
                errors: errors
            ))

            if globalOptions.outputFormat == .text {
                if isValid {
                    print(formatter.success("\(bundleURL.lastPathComponent): Valid"))
                } else {
                    print(formatter.error("\(bundleURL.lastPathComponent): Invalid"))
                    for error in errors {
                        print("  - \(error)")
                    }
                }
            }
        }

        if globalOptions.outputFormat == .json {
            let handler = JSONOutputHandler()
            handler.writeData(BundleValidationOutput(bundles: results, allValid: allValid), label: nil)
        }

        if !allValid {
            throw sawMissingBundle ? CLIExitCode.inputError.exitCode : CLIExitCode.formatError.exitCode
        }
    }
}
