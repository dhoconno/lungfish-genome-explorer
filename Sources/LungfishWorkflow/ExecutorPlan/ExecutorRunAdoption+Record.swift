// ExecutorRunAdoption+Record.swift - The adopt's command, its staging image and the envelope's run identity (CHTC C4 lane A)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The image a shared plan folder's `staging.json` names (lane F, schema 1): the SIF's file name and its SHA-256.
struct ExecutorAdoptStagingImage: Sendable, Equatable {
    let fileName: String
    let sha256: String
}

extension ExecutorRunAdoption {
    static let stagingFileName = "staging.json"
    static let stagingSchemaVersion = 1
    /// The site fact a job may set with the image's SHA-256 (ARCH item 11, Q-C4-5).
    static let imageDigestFactKey = "ImageSHA256"

    /// The argv of `lungfish-cli import fastq <folder> --adopt --project <project>` after the executable. The GUI runs
    /// this array and records it as its row's command, and the adopt records the same words as the envelope's argv,
    /// so the row and the record name one command (CLI-EQUIVALENCE, "Built from what runs").
    public static func cliArguments(
        resultFolder: URL, projectDirectory: URL, name: String? = nil, force: Bool = false, eventsOn: Bool = false
    ) -> [String] {
        var arguments = [
            "import", "fastq", resultFolder.standardizedFileURL.path, "--adopt",
            "--project", projectDirectory.standardizedFileURL.path,
        ]
        if let name { arguments += ["--name", name] }
        if force { arguments.append("--force") }
        if eventsOn { arguments += ["--format", "json"] }
        return arguments
    }

    /// Every check of the adopt with nothing written (`--dry-run`), and the sample name the bundle would take. A bundle
    /// of that name already in the project is refused without `force`, as the adopt refuses it (review A2 fix 1).
    public static func dryRun(resultFolder: URL, projectDirectory: URL, name: String? = nil, force: Bool = false) throws -> String {
        let run = try check(resultFolder, name: name, policy: .release)
        _ = try preflight(run, projectDirectory: projectDirectory, force: force)
        return run.sampleName
    }

    /// `staging.json`'s image, or nil for a folder that holds none, such as a run on any Linux machine. A file that is
    /// there and does not read is refused, so the record never names an image it could not read.
    static func stagingImage(in resolver: PlanResourceResolver) throws(ExecutorAdoptRefusal) -> ExecutorAdoptStagingImage? {
        guard (try? FileManager.default.attributesOfItem(atPath: resolver.workRoot + "/" + stagingFileName)) != nil else {
            return nil
        }
        struct Staging: Decodable {
            struct Image: Decodable {
                let fileName: String
                let sha256: String
            }
            let schemaVersion: Int
            let image: Image
        }
        let bytes = try read(stagingFileName, in: resolver, limit: largestPlanBytes)
        guard let staging = try? JSONDecoder().decode(Staging.self, from: bytes), staging.schemaVersion == stagingSchemaVersion,
              staging.image.sha256.utf8.count == 64, !staging.image.fileName.isEmpty,
              staging.image.sha256.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
        else {
            throw refusal(stagingFileName, "The folder's \(stagingFileName) does not name the image the run used in schema \(stagingSchemaVersion).")
        }
        return ExecutorAdoptStagingImage(fileName: staging.image.fileName, sha256: staging.image.sha256)
    }

    /// Q-C4-5: an image digest the job reported must be the one `staging.json` names.
    static func checkImageDigestFact(_ facts: [PlanKeyValue], image: ExecutorAdoptStagingImage?) throws(ExecutorAdoptRefusal) {
        guard let image, let index = facts.firstIndex(where: { $0.key == imageDigestFactKey }),
              facts[index].value.lowercased() != image.sha256 else { return }
        throw refusal(
            "siteFacts[\(index)]",
            "Site fact \(index + 1) (\(imageDigestFactKey)) names another image than the one \(stagingFileName) names, with SHA-256 \(image.sha256)."
        )
    }

    /// The envelope's run-level identity: this Mac's, as the Mac that adopted and signed the record, with the image
    /// `staging.json` names in `containerImage` and `containerDigest` (ARCH item 11) and the site facts as the launcher
    /// reported them (C4-02). The tool manifest's digest that the plan pins stays in the run record only.
    static func runtimeIdentity(_ run: ExecutorAdoptedRun) -> ProvenanceRuntimeIdentity {
        let facts = run.record.siteFacts.map { ProvenanceSiteFact(key: $0.key, value: $0.value) }
        let node = run.record.runtimeIdentity
        return ProvenanceRuntimeIdentity(
            containerImage: run.stagingImage?.fileName, containerDigest: run.stagingImage?.sha256,
            siteFacts: facts.isEmpty ? nil : facts,
            // Lane U's OQ-1 rows: where the steps ran and with which executor, as the record states them.
            nodeRuntime: ProvenanceNodeRuntime(
                kernelRelease: node.kernelRelease, machine: node.machine,
                executorBuild: run.record.executor.buildPin?.lgeVersion, executorSHA256: run.record.executor.sha256,
                orphanSweep: node.orphanSweep.rawValue
            )
        )
    }
}
