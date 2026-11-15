// RNASeqIndexAdoptSubcommand.swift - `lungfish-cli rnaseq index-adopt` (Phase 5.3 lane EX-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishPortable
import LungfishWorkflow

/// Records the STAR index that a run on a Linux machine built, from the run record that came home. The record holds the
/// set id, the key, the tool and each staged file's path, bytes and SHA-256, so a later plan pins the index by them.
struct RNASeqIndexAdoptSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index-adopt",
        abstract: "Record the STAR index that a run on a Linux machine built",
        discussion: """
            Reads run-record.json in the result folder, which must read succeeded and name each index file as a staged output, \
            and writes the index record under the storage root: the set id, the key, the tool, and each file's staging path, \
            bytes and SHA-256, all from the run record and none from the plan. A later plan finds the record by set id and key. \
            The index files stay in the staging folder on the Linux machine, and nothing here copies one.
            """
    )

    @Argument(help: "The folder the job returned its files to, which holds run-record.json")
    var resultPath: String

    @Option(name: .customLong("set"), help: "The id of the reference set the index was built from, or the path of its folder")
    var setReference: String

    @Option(name: .customLong("staging-folder"), help: "The absolute path of the staging folder on the Linux machine, as the plan was written with")
    var stagingFolder: String

    @Option(name: .customLong("batch"), help: "The name of the plan folder, which names the batch in the staging folder")
    var batch: String

    @Option(name: .customLong("sample"), help: "The sample name of the job (default: index)")
    var sample: String = STARIndexPlan.sampleName

    @Option(name: .customLong("storage-root"), help: "Managed storage root to write the record under (default: the configured location)")
    var storageRoot: String?

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        do {
            let summary = try adopt()
            if globalOptions.outputFormat == .json {
                print(summary.json)
            } else if !globalOptions.quiet {
                summary.lines.forEach { print($0) }
            }
        } catch {
            FileHandle.standardError.write(Data("Error: \(CLIFailureWords.describe(error))\n".utf8))
            throw (error is CocoaError ? CLIExitCode.workflowError : CLIExitCode.inputError).exitCode
        }
    }

    /// Reads the run record, refuses what it does not show, and writes the index record through the one owner.
    func adopt() throws -> (lines: [String], json: String) {
        guard stagingFolder.hasPrefix("/") else { throw STARIndexError("--staging-folder must be an absolute path.") }
        let result = URL(fileURLWithPath: resultPath, isDirectory: true).standardizedFileURL
        guard let data = try? Data(contentsOf: result.appendingPathComponent(ExecutorRunRecord.fileName)) else {
            throw STARIndexError("\(result.path) holds no \(ExecutorRunRecord.fileName), so name the folder the job returned its files to.")
        }
        let setFolder = try RNASeqIndexPlanSubcommand.setFolder(for: setReference, storageRoot: storageRoot)
        let record = try STARIndexAdopt.adopt(
            runRecord: data, setFolder: setFolder, staging: ExecutorPlanStagingLayout(folder: stagingFolder, batch: batch),
            sample: sample)
        let root = RNASeqIndexPlanSubcommand.storageRootURL(storageRoot)
        let written = try STARIndexRecordStore(storageRoot: root).write(record)
        let bytes = record.files.reduce(UInt64(0)) { $0 + $1.bytes }
        let lines = ["Adopted the STAR index \(record.key.folderName) of the set \(record.setID): \(record.files.count) files, "
                         + "\(bytes) bytes in the staging folder.", written.path]
        let facts: [String: Any] = [
            "setID": record.setID, "key": record.key.folderName, "record": written.path, "files": record.files.count, "bytes": bytes,
        ]
        let json = try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys, .withoutEscapingSlashes])
        return (lines, String(decoding: json, as: UTF8.self))
    }
}
