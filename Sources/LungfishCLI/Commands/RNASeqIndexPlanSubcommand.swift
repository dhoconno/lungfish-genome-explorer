// RNASeqIndexPlanSubcommand.swift - `lungfish-cli rnaseq index-plan` (Phase 5.3 lane EX-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishPortable
import LungfishWorkflow

/// Writes the submit folder that builds a STAR index of a reference set on a Linux machine, as `import fastq --write-plan`
/// writes one for an import. It starts no process and opens no connection, so a person copies the files and submits.
struct RNASeqIndexPlanSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index-plan",
        abstract: "Write a plan folder that builds the STAR index of a reference set on a Linux machine",
        discussion: """
            The plan runs STAR --runMode genomeGenerate with 8 threads on the set's genome, each extra and its counting GTF, \
            derived/genes.gtf. Each index file stays in the staging folder on the Linux machine as a staged output, and index-adopt \
            then records where each file sits and its SHA-256 for later plans. A set built before the counting GTF has none, so \
            rebuild it first.

            A genome with no measured figures needs --request-memory-mib, --request-cpus and --request-disk-gib, taken from \
            STAR's own peak memory and the job's disk on a small run. A run that index-adopt will read takes the manifest of the \
            executor you built with --executor-manifest, since the plan pins it.
            """
    )

    /// The words of a cancelled run.
    static let cancelledMessage = "The index plan was cancelled. No plan folder was written."

    @Option(name: .customLong("set"), help: "The id of a reference set under the storage root, or the path of a set folder")
    var setReference: String

    @Option(name: .customLong("star"), help: "The STAR version to run, either 2.7.11b or 2.7.3a")
    var star: String = "2.7.11b"

    @Option(name: .customLong("tenx-filter"), help: "The 10x biotype list, mkgtf-3.0.0 or gencode-2020-A, of a STARsolo index. Its filter rule makes the GTF from derived/genes.gtf into the plan folder")
    var tenxFilter: String?

    @Option(name: .customLong("output"), help: "The new plan folder to write. It must not exist")
    var outputPath: String

    @Option(name: .customLong("staging-folder"), help: "The absolute path of the folder on the Linux machine that holds the image and the executor and keeps the index")
    var stagingFolder: String

    @Option(name: .customLong("executor-manifest"), help: "The manifest.json beside the Linux lungfish-executor (default: the app's)")
    var executorManifest: String?

    @Option(name: .customLong("image"), help: "The image.json of the container image (default: the app's)")
    var image: String?

    @Option(name: .customLong("image-tool-manifest"), help: "The image's tool manifest, the file image.json pins (default: the app's)")
    var imageToolManifest: String?

    @Option(name: .customLong("request-memory-mib"), help: "Memory the job asks for, in MiB. Optional for Macaca_fascicularis_6.0")
    var requestMemoryMiB: Int64?

    @Option(name: .customLong("request-cpus"), help: "CPUs the job asks for. Optional for Macaca_fascicularis_6.0")
    var requestCPUs: Int?

    @Option(name: .customLong("request-disk-gib"), help: "Disk the job asks for, in GiB. Optional for Macaca_fascicularis_6.0")
    var requestDiskGiB: Int?

    @Option(name: .customLong("job-requirements"), help: "The machines the job may run on, as one HTCondor requirements expression")
    var jobRequirements: String?

    @Option(name: .customLong("storage-root"), help: "Managed storage root that --set names a set under (default: the configured location)")
    var storageRoot: String?

    @OptionGroup var globalOptions: GlobalOptions

    var outputURL: URL { URL(fileURLWithPath: outputPath).standardizedFileURL }

    func validate() throws {
        guard globalOptions.threads == nil else {
            throw ValidationError("rnaseq index-plan always runs STAR with 8 threads, so --threads does not apply. Leave it out.")
        }
    }

    /// The command the record names, in one fixed order with absolute paths. Parsing it gives equal options.
    func canonicalArgv() -> [String] {
        func absolute(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        var argv = [CLICommandIdentity.executableName, "rnaseq", "index-plan", "--set",
                    setReference.contains("/") ? absolute(setReference) : setReference, "--star", star, "--output", outputURL.path,
                    "--staging-folder", stagingFolder]
        if let tenxFilter { argv += ["--tenx-filter", tenxFilter] }
        for (flag, value) in [("--executor-manifest", executorManifest), ("--image", image),
                              ("--image-tool-manifest", imageToolManifest), ("--storage-root", storageRoot)] {
            if let value { argv += [flag, absolute(value)] }
        }
        if let requestMemoryMiB { argv += ["--request-memory-mib", "\(requestMemoryMiB)"] }
        if let requestCPUs { argv += ["--request-cpus", "\(requestCPUs)"] }
        if let requestDiskGiB { argv += ["--request-disk-gib", "\(requestDiskGiB)"] }
        if let jobRequirements { argv += ["--job-requirements", jobRequirements] }
        return argv
    }

    /// The list `--tenx-filter` names, nil when it is left out, or a refusal that names both lists.
    static func tenxList(_ value: String?) throws -> TenxGTFFilter.List? {
        guard let value else { return nil }
        guard let list = TenxGTFFilter.List(rawValue: value) else {
            throw STARIndexError("--tenx-filter is \(TenxGTFFilter.List.allCases.map(\.rawValue).joined(separator: " or ")), not \(value).")
        }
        return list
    }

    /// `--storage-root`, else the configured location. It sets no environment variable, since no tool runs here.
    static func storageRootURL(_ storageRoot: String?) -> URL {
        guard let storageRoot, !storageRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ManagedStorageConfigStore().currentLocation().rootURL
        }
        return URL(fileURLWithPath: storageRoot, isDirectory: true).standardizedFileURL
    }

    /// A set folder: the path itself when `reference` holds a slash, else the folder of that id under the storage root.
    static func setFolder(for reference: String, storageRoot: String?) throws -> URL {
        let url: URL
        if reference.contains("/") {
            url = URL(fileURLWithPath: reference, isDirectory: true).standardizedFileURL
        } else {
            url = storageRootURL(storageRoot).appendingPathComponent(ReferenceSetOwner.folderName, isDirectory: true)
                .appendingPathComponent("\(reference).\(ReferenceSetManifest.folderExtension)", isDirectory: true)
        }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(ReferenceSetManifest.filename).path) else {
            throw STARIndexError("No reference set is at \(url.path), so name the id of a set under the storage root or the path of a set folder.")
        }
        return url
    }
}
