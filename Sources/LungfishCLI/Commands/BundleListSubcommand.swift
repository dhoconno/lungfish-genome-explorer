// BundleListSubcommand.swift - List bundle contents
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - List Subcommand

/// List bundle contents
struct BundleListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List bundle contents",
        discussion: """
            Lists the files and tracks contained in a bundle.

            Examples:
              lungfish-cli bundle list MyGenome.lungfishref
              lungfish-cli bundle list MyGenome.lungfishref --tracks
            """
    )

    @Argument(help: "Path to the .lungfishref bundle")
    var bundlePath: String

    @Flag(name: .long, help: "Show tracks only")
    var tracks: Bool = false

    @Flag(name: .long, help: "Show files only")
    var files: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            throw CLIError.inputFileNotFound(path: bundlePath)
        }

        let manifest: BundleManifest
        do {
            manifest = try BundleManifest.load(from: bundleURL)
        } catch {
            throw CLIError.conversionFailed(reason: "Failed to load bundle manifest: \(error.localizedDescription)")
        }

        if globalOptions.outputFormat == .json {
            let output = BundleListOutput(
                files: tracks ? nil : listBundleFiles(bundleURL),
                tracks: files ? nil : BundleTrackList(manifest: manifest)
            )
            let handler = JSONOutputHandler()
            handler.writeData(output, label: nil)
            return
        }

        // Text output
        if !tracks {
            print(formatter.header("Files"))
            for file in listBundleFiles(bundleURL) {
                print("  \(file)")
            }
        }

        if !files {
            if !manifest.alignments.isEmpty {
                print("\n" + formatter.header("Alignment Tracks"))
                for line in BundleAlignmentTrackListing.listLines(manifest.alignments, formatter: formatter) {
                    print("  \(line)")
                }
            }

            if !manifest.annotations.isEmpty {
                print("\n" + formatter.header("Annotation Tracks"))
                for track in manifest.annotations {
                    print("  \(track.id): \(track.name) (\(track.annotationType.rawValue))")
                }
            }

            if !manifest.variants.isEmpty {
                print("\n" + formatter.header("Variant Tracks"))
                for track in manifest.variants {
                    print("  \(track.id): \(track.name) (\(track.variantType.rawValue))")
                }
            }

            if !manifest.tracks.isEmpty {
                print("\n" + formatter.header("Signal Tracks"))
                for track in manifest.tracks {
                    print("  \(track.id): \(track.name) (\(track.signalType.rawValue))")
                }
            }
        }
    }

    private func listBundleFiles(_ bundleURL: URL) -> [String] {
        var files: [String] = []
        let fileManager = FileManager.default

        if let enumerator = fileManager.enumerator(at: bundleURL, includingPropertiesForKeys: nil) {
            while let fileURL = enumerator.nextObject() as? URL {
                let relativePath = fileURL.path.replacingOccurrences(of: bundleURL.path + "/", with: "")
                files.append(relativePath)
            }
        }

        return files.sorted()
    }
}
