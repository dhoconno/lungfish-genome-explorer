// MetagenomicsImportService+NaoMgsStage.swift - Imports one NAO-MGS sample into a staging folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Intermediate result from importing a single pre-partitioned sample into staging.
struct NaoMgsSingleSampleStageResult {
    let sampleName: String
    let hitCount: Int
    let taxonCount: Int
    let createdBAM: Bool
    let stageInput: NaoMgsStageDatabaseInput
    let materializationSteps: [NaoMgsBamMaterializationStep]
}

extension MetagenomicsImportService {
    /// Imports a single pre-partitioned sample TSV into a staging directory.
    /// Produces a per-sample SQLite database and BAM files without fetching references.
    ///
    /// `samtoolsPath` is the samtools that writes the BAM. It is the managed one unless a test names a
    /// stand-in, and nil means there is none.
    static func importNaoMgsSingleSampleStage(
        inputURL: URL,
        stagingDirectory: URL,
        sampleName: String,
        minIdentity: Double = 0,
        samtoolsPath: String? = MetagenomicsImportService.managedSamtoolsExecutableURL()?.path
    ) async throws -> NaoMgsSingleSampleStageResult {
        let fm = FileManager.default
        let stageDir = stagingDirectory.appendingPathComponent(sampleName, isDirectory: true)
        try ensureDirectoryExists(stageDir)

        let hitsDBURL = stageDir.appendingPathComponent("hits.sqlite")
        let streamResult = try await NaoMgsDatabase.createStreaming(
            at: hitsDBURL,
            from: [inputURL],
            sampleNameOverride: sampleName,
            minIdentity: minIdentity
        )

        // Materialize BAMs for this sample.
        var createdBAM = false
        var materializationSteps: [NaoMgsBamMaterializationStep] = []
        if let samtoolsPath {
            let materialized = try NaoMgsBamMaterializer.materializeAllWithProvenance(
                dbPath: hitsDBURL.path,
                resultURL: stageDir,
                samtoolsPath: samtoolsPath,
                lungfishVersion: WorkflowRun.currentAppVersion
            )
            let generated = materialized.bamURLs
            materializationSteps.append(contentsOf: materialized.steps)
            createdBAM = !generated.isEmpty
            // Each stage holds one sample, so no BAM from a stage that has hits is that sample's BAM not written.
            if generated.isEmpty, streamResult.hitCount > 0 {
                throw MetagenomicsImportError.naoMgsBAMNotWritten(
                    sample: sampleName, reason: materialized.failures.values.first
                )
            }

            if !generated.isEmpty {
                // Record BAM paths in the stage database so the merge can read them.
                let rwDB = try NaoMgsDatabase.openReadWrite(at: hitsDBURL)
                var bamPathsBySample: [String: (bamPath: String, bamIndexPath: String?)] = [:]
                for bamURL in generated {
                    let sample = bamURL.deletingPathExtension().lastPathComponent
                    let bamRelative = "bams/\(bamURL.lastPathComponent)"
                    let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
                    let csiURL = URL(fileURLWithPath: bamURL.path + ".csi")
                    let indexRelative: String?
                    if fm.fileExists(atPath: baiURL.path) {
                        indexRelative = bamRelative + ".bai"
                    } else if fm.fileExists(atPath: csiURL.path) {
                        indexRelative = bamRelative + ".csi"
                    } else {
                        indexRelative = nil
                    }
                    bamPathsBySample[sample] = (bamPath: bamRelative, bamIndexPath: indexRelative)
                }
                try rwDB.updateBamPaths(bamPathsBySample)

                // Purge virus_hits now that BAMs are materialized.
                try? rwDB.deleteVirusHitsAndVacuum()
            }
        } else if streamResult.hitCount > 0 {
            throw MetagenomicsImportError.naoMgsSamtoolsMissing(sample: sampleName)
        }

        // Build the stage input descriptor for the merge phase.
        let bamRelative = "bams/\(sampleName).bam"
        let bamFullPath = stageDir.appendingPathComponent(bamRelative)
        let baiFullPath = URL(fileURLWithPath: bamFullPath.path + ".bai")
        let csiFullPath = URL(fileURLWithPath: bamFullPath.path + ".csi")
        let indexRelative: String?
        if fm.fileExists(atPath: baiFullPath.path) {
            indexRelative = "bams/\(sampleName).bam.bai"
        } else if fm.fileExists(atPath: csiFullPath.path) {
            indexRelative = "bams/\(sampleName).bam.csi"
        } else {
            indexRelative = nil
        }

        return NaoMgsSingleSampleStageResult(
            sampleName: streamResult.sampleName,
            hitCount: streamResult.hitCount,
            taxonCount: streamResult.taxonCount,
            createdBAM: createdBAM,
            stageInput: NaoMgsStageDatabaseInput(
                sample: sampleName,
                databaseURL: hitsDBURL,
                bamRelativePath: bamRelative,
                bamIndexRelativePath: indexRelative
            ),
            materializationSteps: materializationSteps
        )
    }
}
