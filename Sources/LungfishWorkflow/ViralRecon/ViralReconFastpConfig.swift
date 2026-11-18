// ViralReconFastpConfig.swift - The fastp arguments LGE gives viralrecon's FASTP step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Ruling BIO-THREE-ROWS, items 8-11 and section 3 (VIRALRECON-SE-ADAPTER-GUESS). viralrecon hands its FASTP step no
// adapter FASTA (`workflows/viralrecon.nf:246-251`), so for a single-end sample fastp guessed the adapter from the reads
// it saw first, and the same reads in another stored order could be trimmed differently. A run with a single-end
// Illumina sample gets one more `-c` config. It keeps viralrecon's own `ext.args` for every sample and, only when
// `meta.single_end`, names TruSeq Read 1 and LGE's known adapters, as LGE's own single-read fastp does
// (``FastpPairedRunner/SingleReadAdapters``).

import Foundation
import LungfishIO

/// The `-c` config that names the adapters of viralrecon's FASTP step for a single-end sample.
package enum ViralReconFastpConfig {
    /// The config of a run, written into `launchFolder`, when a row of `readPairing` runs single-end and the run does
    /// not skip fastp. Nil for a run whose rows all run paired, which launches as it did before, and for Nanopore,
    /// which has no rows here. `adapters` refuses in words when LGE's list of known adapters is missing.
    package static func writeIfNeeded(
        readPairing: [ViralReconReadPairingDecision],
        params: [String: String],
        launchFolder: URL,
        stagingRoot: URL,
        adapters: () throws -> FastpPairedRunner.SingleReadAdapters = { try .bundled() }
    ) throws -> Written? {
        guard readPairing.contains(where: { !$0.runsPaired }),
              params["skip_fastp"]?.trimmingCharacters(in: .whitespaces).lowercased() != "true" else {
            return nil
        }
        return try write(in: launchFolder, stagingRoot: stagingRoot, adapters: adapters())
    }

    /// viralrecon 3.0.0's own FASTP `ext.args`, `conf/modules_illumina.config:75` at the pinned revision, word for word.
    package static let viralReconArguments = "--cut_front --cut_tail --trim_poly_x --cut_mean_quality 30 "
        + "--qualified_quality_phred 30 --unqualified_percent_limit 10 --length_required 50"

    /// The config's name in the launch folder, beside `lungfish-resource-limits.config`.
    package static let fileName = "lungfish-fastp-adapters.config"

    /// The folder under the run's staging root that holds the run's copy of the adapter FASTA.
    package static let adapterFolderName = "lungfish-fastp-adapters"

    /// The words of `ext.args` for a single-end sample, viralrecon's own and then the named adapters.
    package static func singleEndArguments(adapters: FastpPairedRunner.SingleReadAdapters) -> [String] {
        viralReconArguments.split(separator: " ").map(String.init)
            + ["--adapter_sequence", adapters.adapterSequence, "--adapter_fasta", adapters.fastaURL.path]
    }

    /// The config a run passes with `-c`, and the adapters it names.
    package struct Written: Sendable {
        package let configURL: URL
        /// The adapters, with the run's own copy of the FASTA, which the record names.
        package let adapters: FastpPairedRunner.SingleReadAdapters
        /// The folder that holds the copy, removed with the run's scratch unless ``isFallback``.
        package let adapterFolder: URL
        /// True when the copy went to a system temp folder because the staging root's path could not be named in the
        /// config. The caller removes that folder once the run ends.
        package let isFallback: Bool
    }

    /// The config's errors, in the words the run shows.
    package enum ConfigError: Error, LocalizedError, Equatable {
        case unsafePath(String)

        package var errorDescription: String? {
            switch self {
            case .unsafePath(let path):
                return "Lungfish could not give the fastp step of Viral Recon its list of known adapters, because "
                    + "the folder \(path) has a character that the step cannot take in a folder name. Move the project "
                    + "to a folder whose name has only letters, digits, dots, dashes and underscores, and run it again."
            }
        }
    }

    /// Whether `path` can stand as one word in the shell line of the FASTP task and in Docker's `--volume`.
    static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && path.range(of: #"^[A-Za-z0-9._/+-]+$"#, options: .regularExpression) != nil
    }

    /// Copies `bundled`'s FASTA into ``adapterFolderName`` under `stagingRoot` and writes the config into
    /// `directory`. The task runs in a container that sees only the folders Nextflow mounts, so the config also
    /// mounts the copy's folder, read only, into a single-end FASTP task. When `stagingRoot`'s path cannot be named in
    /// the config, the copy goes to a system temp folder.
    package static func write(
        in directory: URL,
        stagingRoot: URL,
        adapters bundled: FastpPairedRunner.SingleReadAdapters
    ) throws -> Written {
        let fileManager = FileManager.default
        var folder = stagingRoot.appendingPathComponent(adapterFolderName, isDirectory: true).standardizedFileURL
        var isFallback = false
        if !isSafe(folder.path) {
            folder = try ProjectTempDirectory.create(prefix: adapterFolderName + "-", contextURL: nil, policy: .systemOnly)
                .standardizedFileURL
            isFallback = true
            guard isSafe(folder.path) else {
                try? fileManager.removeItem(at: folder)
                throw ConfigError.unsafePath(stagingRoot.path)
            }
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(bundled.fastaURL.lastPathComponent)
        try? fileManager.removeItem(at: copy)
        try fileManager.copyItem(at: bundled.fastaURL, to: copy)
        let adapters = try FastpPairedRunner.SingleReadAdapters(adapterSequence: bundled.adapterSequence, fastaURL: copy)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent(fileName)
        try configText(adapters: adapters, mountFolder: folder).write(to: configURL, atomically: true, encoding: .utf8)
        return Written(
            configURL: configURL.standardizedFileURL, adapters: adapters, adapterFolder: folder, isFallback: isFallback
        )
    }

    /// The config. Its selector is viralrecon's own (`conf/modules_illumina.config:74`), so a `-c` file, read after
    /// the pipeline's config, takes its place. A paired sample keeps viralrecon's words and no added mount.
    static func configText(adapters: FastpPairedRunner.SingleReadAdapters, mountFolder: URL) -> String {
        let single = singleEndArguments(adapters: adapters).joined(separator: " ")
        return """
        // Written by Lungfish. viralrecon hands fastp no adapter for a single-end sample, so fastp guessed one from
        // the reads it saw first. A single-end sample gets viralrecon's own arguments and the adapters named below.
        // A paired sample keeps viralrecon's own arguments (conf/modules_illumina.config:75).
        process {
            withName: 'FASTP' {
                ext.args = { meta.single_end ? '\(single)' : '\(viralReconArguments)' }
                containerOptions = { meta.single_end ? '--volume \(mountFolder.path):\(mountFolder.path):ro' : '' }
            }
        }

        """
    }
}
