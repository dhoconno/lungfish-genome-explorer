// ExecutorRunAdoptionTests.swift - The adopt's refusals and the record it writes from a plan and a run record (CHTC C4 lane A)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

final class ExecutorRunAdoptionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorRunAdoption")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A returned plan folder: the emitter's plan, a payload and a succeeded run record that is true to both.
    private struct Returned {
        let folder: URL
        let plan: ExecutionPlan
        var record: ExecutorRunRecord

        func write() throws {
            try record.encoded().write(to: folder.appendingPathComponent(ExecutorRunRecord.fileName))
        }
    }

    private func returned(_ clumping: ClumpingTool, siteFacts: [PlanKeyValue] = []) throws -> Returned {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, "S")
        let emission = try ExecutorPlanEmitter.emission(
            ExecutorPlanTestSupport.request(root: root, "S", inputs: pair, clumping: clumping), host: ExecutorPlanTestSupport.mac24
        )
        let folder = root.appendingPathComponent("returned-\(clumping.rawValue)", isDirectory: true)
        let planFile = try ExecutorPlanFolderWriter.write(emission, into: folder)
        let planBytes = try Data(contentsOf: planFile)
        let payloadBytes = Data("@pair1/1\nACGTACGTAC\n+\nIIIIIIIIII\n@pair1/2\nGTACGTACGT\n+\nIIIIIIIIII\n".utf8)
        let payloadURL = folder.appendingPathComponent(ExecutorPlanEmitter.payloadPath)
        try FileManager.default.createDirectory(at: payloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payloadBytes.write(to: payloadURL)
        let payload = ExecutorFileDigest(
            relativePath: ExecutorPlanEmitter.payloadPath, sha256: PortableDigest.sha256Hex(of: payloadBytes),
            size: Int64(payloadBytes.count)
        )
        let plan = emission.plan
        let time = "2026-10-24T12:00:00.000Z"
        let steps = plan.steps.map { step in
            ExecutorStepRecord(
                id: step.id, kind: step.kind,
                tool: step.tool.map { ExecutorToolRecord(id: $0.id, version: $0.version, build: $0.build, path: "/opt/conda/bin/\($0.id)") },
                outcome: .succeeded, argv: step.arguments, environmentNames: ["HOME", "PATH", "TMPDIR"], graceSeconds: 30,
                deadlineSeconds: step.deadlineSeconds, toolExitCode: 0, startedAt: time, endedAt: time, wallSeconds: 1,
                qualityCounts: step.kind == .qualityCount
                    ? ExecutorQualityCounts(baseCount: 20, q20Count: 20, q30Count: 20, recordCount: 2, file: payload) : nil,
                storage: step.kind == .storage
                    ? ExecutorStorageDetails(clumpingRan: plan.clumping.resolved == .bbtools, qualityBinning: plan.storage.qualityBinning,
                                             inputBytes: 200, outputBytes: payload.size)
                    : nil
            )
        }
        let record = ExecutorRunRecord(
            outcome: .succeeded, executorArguments: ["run", "--plan", "plan.json"],
            executor: ExecutorBinaryIdentity(sha256: ExecutorPlanTestSupport.digest, size: 17, buildPin: plan.executor),
            plan: ExecutorFileDigest(relativePath: "plan.json", sha256: PortableDigest.sha256Hex(of: planBytes), size: Int64(planBytes.count)),
            recipe: plan.recipe,
            imageManifest: ExecutorImageManifestRecord(sha256: plan.imageManifest.sha256, size: plan.imageManifest.size, source: .image),
            runtimeIdentity: ExecutorRuntimeIdentity(
                kernelRelease: "5.14.0-503.el9.x86_64", machine: "x86_64", pidNamespaceDepth: 2, cgroupVersion: 2, observedLimits: [],
                subreaper: ExecutorStepRecord.Subreaper(state: "set", setterResult: 0, setterResultName: "0", getterResult: 0, getterValue: 1),
                orphanSweep: .subreaper
            ),
            siteFacts: siteFacts, inputs: plan.entries.filter { $0.role != .executor },
            payloads: [ExecutorPayloadRecord(
                relativePath: payload.relativePath, sha256: payload.sha256, size: payload.size, recordCount: 2, recordCountFile: payload
            )],
            steps: steps, startedAt: time, endedAt: time, wallSeconds: 3
        )
        let returned = Returned(folder: folder, plan: plan, record: record)
        try returned.write()
        return returned
    }

    private var project: URL { root.appendingPathComponent("Project.lungfish", isDirectory: true) }

    /// Every entry under the project's imports folder, hidden staging folders included.
    private func importedEntries() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent("Imports").path)) ?? []
    }

    private func refusal(_ returned: Returned, policy: ExecutorAdoptPolicy = .release) async -> ExecutorAdoptRefusal? {
        do {
            _ = try await ExecutorRunAdoption.adopt(resultFolder: returned.folder, projectDirectory: project, policy: policy)
            return nil
        } catch let refusal as ExecutorAdoptRefusal {
            return refusal
        } catch {
            XCTFail("The adopt failed with \(error) in place of a refusal")
            return nil
        }
    }

    private func envelope(_ bundle: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(
            fromSidecar: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        ))
    }

    /// S-2 and ARCH Q-C4-6: the public entry refuses a replay's record before any bundle file exists, and only the
    /// internal replay value lifts that one refusal.
    func testAdoptRefusesArgumentManifestSource() async throws {
        var returned = try returned(.bbtools)
        returned.record.imageManifest?.source = .argument
        try returned.write()
        let first = await refusal(returned)
        let refused = try XCTUnwrap(first)
        XCTAssertEqual(refused.field, "imageManifest.source")
        XCTAssertTrue(refused.reason.contains("--image-manifest"), refused.reason)
        XCTAssertEqual(importedEntries(), [])

        let bundle = try await ExecutorRunAdoption.adopt(
            resultFolder: returned.folder, projectDirectory: project, policy: .macReplayForTests
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("S.fastq.gz").path))

        // The replay value still checks the manifest's digest against the plan's pin.
        returned.record.imageManifest?.sha256 = String(repeating: "c", count: 64)
        try returned.write()
        let pinned = await refusal(returned, policy: .macReplayForTests)
        XCTAssertEqual(pinned?.field, "imageManifest.sha256")
    }

    /// C4-02: a record whose site facts break the executor's bounds is refused, naming the position and never the value.
    func testAdoptRefusesSiteFactOverBounds() async throws {
        let cases: [(facts: [PlanKeyValue], field: String, words: String)] = [
            ([PlanKeyValue(key: "Machine", value: "MARK" + String(repeating: "v", count: 1021))], "siteFacts[0]",
             "Site fact 1 has a value over 1024 bytes."),
            ((1...65).map { PlanKeyValue(key: "K\($0)", value: "MARK") }, "siteFacts[64]", "Site fact 65 is over the limit of 64 site facts."),
            ([PlanKeyValue(key: "A", value: "MARK1"), PlanKeyValue(key: "A", value: "MARK2")], "siteFacts[1]",
             "Site fact 2 repeats the key of an earlier site fact."),
            ([PlanKeyValue(key: "9lives", value: "MARK")], "siteFacts[0]", "Site fact 1 has a key that is not a letter"),
            ([PlanKeyValue(key: "C", value: "MARK\u{01}")], "siteFacts[0]", "Site fact 1 has a value that holds a control character."),
        ]
        for (facts, field, words) in cases {
            let returned = try returned(.bbtools, siteFacts: facts)
            let outcome = await refusal(returned)
            let refused = try XCTUnwrap(outcome, field)
            XCTAssertEqual(refused.field, field)
            XCTAssertTrue(refused.reason.hasPrefix(words), refused.reason)
            XCTAssertFalse(refused.reason.contains("MARK"), refused.reason)
            XCTAssertEqual(importedEntries(), [], field)
            try FileManager.default.removeItem(at: returned.folder)
            try FileManager.default.removeItem(at: root.appendingPathComponent("S", isDirectory: true))
        }
    }

    /// S-1: one flipped byte of a copied payload refuses the adopt, the message names that payload, and no bundle
    /// folder exists afterwards.
    func testAdoptRefusesPayloadWhoseDigestDiffersFromRecord() async throws {
        let returned = try returned(.bbtools)
        let payloadURL = returned.folder.appendingPathComponent(ExecutorPlanEmitter.payloadPath)
        var bytes = try Data(contentsOf: payloadURL)
        bytes[3] ^= 0x01
        try bytes.write(to: payloadURL)
        let outcome = await refusal(returned)
        let refused = try XCTUnwrap(outcome)
        XCTAssertEqual(refused.field, "payloads[0]")
        XCTAssertTrue(refused.reason.contains("The payload \(ExecutorPlanEmitter.payloadPath) has SHA-256"), refused.reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Imports/S.lungfishfastq").path))
        XCTAssertEqual(importedEntries(), [])
    }

    /// S-1 with the resolver's path and link rules: a payload path that leaves the plan's folder is refused by `..`, by an
    /// absolute path and by a symbolic link out of the folder, and so is a run record that is itself a link. The first and
    /// third case name a real file with the right size and digest, and each case sets the record's count files to the same
    /// path, so only the path rule can refuse. Each leaves the file outside the folder as it was and makes no bundle file.
    func testAdoptRefusesPayloadThatLeavesTheFolder() async throws {
        let outsideBytes = Data("@outside/1\nACGTACGTAC\n+\nIIIIIIIIII\n@outside/2\nGTACGTACGT\n+\nIIIIIIIIII\n".utf8)
        let outside = root.appendingPathComponent("outside.fastq.gz")
        let cases: [(label: String, path: String, file: URL, words: String)] = [
            ("dot-dot", "../outside.fastq.gz", outside, "holds an empty, . or .. component"),
            ("absolute", "/etc/hosts", URL(fileURLWithPath: "/etc/hosts"), "is absolute"),
            ("link", "out/link.fastq.gz", outside, "leads outside the plan's folder through a symbolic link"),
        ]
        for (label, path, file, words) in cases {
            var folderCase = try returned(.bbtools)
            try outsideBytes.write(to: outside)
            if label == "link" {
                try FileManager.default.createSymbolicLink(
                    atPath: folderCase.folder.appendingPathComponent(path).path, withDestinationPath: outside.path
                )
            }
            let named = ExecutorFileDigest(
                relativePath: path, sha256: PortableDigest.sha256Hex(of: outsideBytes), size: Int64(outsideBytes.count)
            )
            folderCase.record.payloads = [ExecutorPayloadRecord(
                relativePath: path, sha256: named.sha256, size: named.size, recordCount: 2, recordCountFile: named
            )]
            let counted = try XCTUnwrap(folderCase.record.steps.firstIndex(where: { $0.kind == .qualityCount }), label)
            folderCase.record.steps[counted].qualityCounts = ExecutorQualityCounts(
                baseCount: 20, q20Count: 20, q30Count: 20, recordCount: 2, file: named
            )
            try folderCase.write()
            let fileBefore = try Data(contentsOf: file)
            let caseOutcome = await refusal(folderCase)
            let caseRefused = try XCTUnwrap(caseOutcome, label)
            XCTAssertEqual(caseRefused.field, "payloads[0]", label)
            XCTAssertTrue(caseRefused.reason.contains(words), "\(label): \(caseRefused.reason)")
            XCTAssertEqual(importedEntries(), [], label)
            XCTAssertEqual(try Data(contentsOf: file), fileBefore, label)
            try FileManager.default.removeItem(at: folderCase.folder)
            try FileManager.default.removeItem(at: root.appendingPathComponent("S", isDirectory: true))
        }

        // The run record is a link to a copy outside the folder: the adopt reads a regular file at the folder's root only.
        let linked = try returned(.bbtools)
        let recordURL = linked.folder.appendingPathComponent(ExecutorRunRecord.fileName)
        let copy = root.appendingPathComponent("outside-run-record.json")
        try FileManager.default.moveItem(at: recordURL, to: copy)
        try FileManager.default.createSymbolicLink(at: recordURL, withDestinationURL: copy)
        let copyBefore = try Data(contentsOf: copy)
        let linkOutcome = await refusal(linked)
        let linkRefused = try XCTUnwrap(linkOutcome)
        XCTAssertEqual(linkRefused.field, ExecutorRunRecord.fileName)
        XCTAssertTrue(linkRefused.reason.contains("is not a regular file."), linkRefused.reason)
        XCTAssertEqual(importedEntries(), [])
        XCTAssertEqual(try Data(contentsOf: copy), copyBefore)
    }

    /// C4-02: a run from any Linux machine passes no site fact, and its record adopts.
    func testAdoptAcceptsRecordWithNoSiteFacts() async throws {
        let returned = try returned(.bbtools)
        XCTAssertEqual(returned.record.siteFacts, [])
        let bundle = try await ExecutorRunAdoption.adopt(resultFolder: returned.folder, projectDirectory: project)
        XCTAssertEqual(bundle.lastPathComponent, "S.lungfishfastq")
        let fastq = bundle.appendingPathComponent("S.fastq.gz")
        XCTAssertEqual(try Data(contentsOf: fastq), try Data(contentsOf: returned.folder.appendingPathComponent(ExecutorPlanEmitter.payloadPath)))
        let ingestion = try XCTUnwrap(FASTQMetadataStore.load(for: fastq)?.ingestion)
        XCTAssertEqual(ingestion.storageOutputSizeBytes, returned.record.payloads[0].size)
        XCTAssertEqual(ingestion.originalFilenames, returned.plan.sample.originalFilenames)
        XCTAssertEqual(importedEntries(), ["S.lungfishfastq"])
    }

    /// SWIFT 6: a name the caller gives passes through the one name sanitizer, so no part of it reaches the bundle's path,
    /// the staging folder beside it or the staged file, and nothing is written beside or above the project's imports.
    func testAdoptSanitizesTheNameItIsGiven() async throws {
        let returned = try returned(.bbtools)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let bundle = try await ExecutorRunAdoption.adopt(
            resultFolder: returned.folder, projectDirectory: project, name: "../../Escape/x"
        )
        let expected = project.appendingPathComponent("Imports/Escape_x.lungfishfastq")
        XCTAssertEqual(bundle.standardizedFileURL.path, expected.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Escape_x.fastq.gz").path))
        XCTAssertEqual(importedEntries(), ["Escape_x.lungfishfastq"])
        let after = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(after.sorted(), (before + ["Project.lungfish"]).sorted())
    }

    /// C4-01, XC-7, XC-8 and XC-13 on the adopted record, for an automatic plan and for one that names the tool.
    func testAdoptedRecordOfAutoPlanNullsHostBasis() async throws {
        let physicalMemory = String(ProcessInfo.processInfo.physicalMemory)
        for clumping in [ClumpingTool.auto, .bbtools] {
            let returned = try returned(clumping)
            let projectFolder = root.appendingPathComponent("Project-\(clumping.rawValue).lungfish", isDirectory: true)
            let bundle = try await ExecutorRunAdoption.adopt(resultFolder: returned.folder, projectDirectory: projectFolder)
            let envelope = try envelope(bundle)
            let resolved = envelope.options.resolvedDefaults
            let label = clumping.rawValue
            for key in ["clumpingEstimatedInputBytes", "clumpingPhysicalMemoryBytes", "clumpingThresholdBytes"] {
                XCTAssertEqual(resolved[key], .null, "\(label) \(key)")
            }
            for key in ["threadsSource", "clumpifyHeapSource", "resolvedClumpingToolSource", "qualityBinningSource"] {
                XCTAssertEqual(resolved[key], .string("plan"), "\(label) \(key)")
            }
            // Clumpify ran, so the record states the heap the plan pinned, as the Mac's record states the heap that ran.
            XCTAssertEqual(resolved["clumpifyHeapGB"], .integer(returned.plan.storage.clumpifyHeapGB), label)
            XCTAssertEqual(resolved["clumpingHeapBytes"], .integer(returned.plan.storage.clumpifyHeapGB * 1_073_741_824), label)
            XCTAssertEqual(resolved["requestedClumpingTool"], .string(clumping.rawValue), label)
            XCTAssertEqual(resolved["resolvedClumpingTool"], .string("bbtools"), label)
            XCTAssertEqual(resolved["clumpingResolutionReason"], .string(returned.plan.clumping.reason), label)
            XCTAssertEqual(resolved["clumpingPlanHeapBytes"], .integer(Int(returned.plan.clumping.heapBytes)), label)
            // BIO's testAdoptedRecordOfAutomaticPlanNamesNoHostEstimate: no key holds this Mac's memory.
            let text = String(decoding: try Data(contentsOf: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)), as: UTF8.self)
            XCTAssertFalse(text.contains(physicalMemory), "\(label) names the Mac's physical memory")

            // QA ruling 2: the executor's step parents every node step, and the import step is the run's last.
            let executor = try XCTUnwrap(envelope.steps.first { $0.toolName == ExecutorRunAdoption.executorToolName }, label)
            let nodeSteps = envelope.steps.filter { $0.parentStepID == executor.id }
            XCTAssertEqual(nodeSteps.count, returned.record.steps.count, label)
            XCTAssertEqual(executor.parentStepID, envelope.steps.last?.id, label)
            XCTAssertEqual(envelope.steps.last?.toolName, "lungfish import fastq", label)
            XCTAssertFalse(envelope.steps.contains { $0.toolName == "seqkit" && $0.argv.contains("stats") && $0.parentStepID != executor.id }, label)
        }
    }

    /// The facts lane H's job passed to a CHTC slot (H2.md line 33), as `--site-fact` gives them.
    private static let chtcFacts = [
        ("Machine", "e4004.chtc.wisc.edu"), ("Arch", "X86_64"), ("Microarch", "x86_64-v3"), ("OpSysAndVer", "CentOS9"),
        ("OpSysMajorVer", "9"), ("OSKernelRelease", "5.14.0-620.el9.x86_64"), ("Cpus", "1"), ("Memory", "1024"),
        ("Disk", "16777216"), ("ClusterId", "593367"), ("ProcId", "0"),
    ].map { PlanKeyValue(key: $0.0, value: $0.1) }

    private static let sif = "lge-c0-tools-c42530259944.sif"
    private static let sifSHA256 = "c425302599447ae0157523299b71ac5c170294537c58c1ca31bdc2bb1cfceb7c"

    private func writeStaging(_ returned: Returned) throws {
        let json = #"{"schemaVersion":1,"sharedFiles":[],"image":{"fileName":"\#(Self.sif)","sha256":"\#(Self.sifSHA256)","size":392368128}}"#
        try Data(json.utf8).write(to: returned.folder.appendingPathComponent("staging.json"))
    }

    /// C4-02 and ARCH item 11: the envelope's run-level identity holds the site facts in the record's order as the
    /// launcher gave them, and the image `staging.json` names, never the tool manifest's digest. A job's image digest
    /// that differs from `staging.json` is refused.
    func testAdoptedEnvelopeCopiesSiteFactsAndStagingImage() async throws {
        let returned = try returned(.bbtools, siteFacts: Self.chtcFacts)
        try writeStaging(returned)
        let bundle = try await ExecutorRunAdoption.adopt(resultFolder: returned.folder, projectDirectory: project)
        let runtime = try envelope(bundle).runtimeIdentity
        XCTAssertEqual(runtime.siteFacts, Self.chtcFacts.map { ProvenanceSiteFact(key: $0.key, value: $0.value) })
        XCTAssertEqual(runtime.containerImage, Self.sif)
        XCTAssertEqual(runtime.containerDigest, Self.sifSHA256)
        XCTAssertNotEqual(runtime.containerDigest, returned.plan.imageManifest.sha256)

        let other = try self.returned(.auto, siteFacts: [PlanKeyValue(key: "ImageSHA256", value: String(repeating: "d", count: 64))])
        try writeStaging(other)
        let outcome = await refusal(other)
        let refused = try XCTUnwrap(outcome)
        XCTAssertEqual(refused.field, "siteFacts[0]")
        XCTAssertTrue(refused.reason.contains(Self.sifSHA256), refused.reason)
    }

    /// C4-02: a record with no site fact and no `staging.json`, a run on any Linux machine, adopts with neither.
    func testAdoptedEnvelopeOfPlainLinuxRunHoldsNoSiteFactOrImage() async throws {
        let returned = try returned(.bbtools)
        let bundle = try await ExecutorRunAdoption.adopt(resultFolder: returned.folder, projectDirectory: project)
        let runtime = try envelope(bundle).runtimeIdentity
        XCTAssertNil(runtime.siteFacts)
        XCTAssertNil(runtime.containerImage)
        XCTAssertNil(runtime.containerDigest)
        XCTAssertEqual(ProvenanceSiteFactRows.rows(runtime.siteFacts).count, 0)
    }

    /// OQ-5's rows for the facts a CHTC slot gave: the group row first, a template fact under its label, Memory in
    /// MiB and Disk in KiB, any other key under its own name, one job row, and each asked-for fact the record lacks as
    /// Not recorded.
    func testSiteFactRowsShowLauncherWordsLabelsAndUnits() {
        let facts = Self.chtcFacts.map { ProvenanceSiteFact(key: $0.key, value: $0.value) }
        let rows = ProvenanceSiteFactRows.rows(facts).map { "\($0.label): \($0.value)" }
        XCTAssertEqual(rows, [
            "Reported by the launcher: Passed in by the program that started the run, such as HTCondor. Lungfish shows them as given and did not check them.",
            "Machine name: e4004.chtc.wisc.edu", "Arch: X86_64", "CPU microarchitecture: x86_64-v3",
            "Operating system: CentOS9", "OpSysMajorVer: 9", "Kernel release: 5.14.0-620.el9.x86_64", "CPUs: 1",
            "Memory: 1024 MiB", "Disk: 16777216 KiB", "HTCondor job: 593367.0",
            "Apptainer version: Not recorded", "HTCondor version: Not recorded",
        ])
        let odd = ProvenanceSiteFactRows.rows([
            ProvenanceSiteFact(key: "Memory", value: "1 GB"), ProvenanceSiteFact(key: "Machine", value: "undefined"),
            ProvenanceSiteFact(key: "ProcId", value: "3"),
        ], missingValue: "undefined").map { "\($0.label): \($0.value)" }
        XCTAssertEqual(Array(odd.dropFirst().prefix(3)), ["Memory: 1 GB", "Machine name: Not recorded", "HTCondor job: Not recorded"])
        XCTAssertEqual(ProvenanceSiteFactRows.rows([]).count, 0)
        XCTAssertEqual(ProvenanceSiteFactRows.rows(nil).count, 0)
    }

    /// ARCH 5 and CLI-EQUIVALENCE: the adopted record is signed on the Mac and passes the check that `lungfish-cli
    /// provenance verify` runs, and its argv and its import step's command are the adopt command.
    func testAdoptedBundlePassesProvenanceVerify() async throws {
        let returned = try returned(.bbtools)
        let keyFile = root.appendingPathComponent("signing-key.txt")
        try "adopt-throwaway-\(UUID().uuidString)\n".write(to: keyFile, atomically: true, encoding: .utf8)
        let bundle = try await ExecutorRunAdoption.adopt(
            resultFolder: returned.folder, projectDirectory: project, name: "S2", eventsOn: true, policy: .release,
            signingEnvironment: [ProvenanceSigningConfiguration.signingKeyFileEnvironmentKey: keyFile.path]
        )
        let record = bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: record).isValid)
        let command = ["lungfish-cli"] + ExecutorRunAdoption.cliArguments(
            resultFolder: returned.folder, projectDirectory: project, name: "S2", eventsOn: true
        )
        XCTAssertEqual(command, [
            "lungfish-cli", "import", "fastq", returned.folder.path, "--adopt", "--project", project.path, "--name", "S2",
            "--format", "json",
        ])
        let envelope = try envelope(bundle)
        XCTAssertEqual(envelope.argv, command)
        XCTAssertEqual(envelope.steps.last?.argv, command)
    }

    /// BIO 4: a plan that ran no clumpify has no heap to state. The adopted record holds the Mac's own nulls for the heap
    /// that ran, keeps the heap the plan pinned in `clumpingPlanHeapBytes`, and still names the plan as the source of
    /// the threads, the clumping tool and the binning.
    func testAdoptedRecordOfPlanWithoutClumpifyNullsHeapKeys() async throws {
        for clumping in [ClumpingTool.none, .trimGalore] {
            let returned = try returned(clumping)
            let label = clumping.rawValue
            XCTAssertFalse(returned.record.steps.contains { $0.storage?.clumpingRan == true }, label)
            let projectFolder = root.appendingPathComponent("Project-\(label).lungfish", isDirectory: true)
            let bundle = try await ExecutorRunAdoption.adopt(resultFolder: returned.folder, projectDirectory: projectFolder)
            let resolved = try envelope(bundle).options.resolvedDefaults
            for key in [
                "clumpifyHeapSource", "clumpifyHeapGB", "clumpingHeapBytes",
                "clumpingEstimatedInputBytes", "clumpingPhysicalMemoryBytes", "clumpingThresholdBytes",
            ] {
                XCTAssertEqual(resolved[key], .null, "\(label) \(key)")
            }
            XCTAssertEqual(resolved["clumpingPlanHeapBytes"], .integer(Int(returned.plan.clumping.heapBytes)), label)
            for key in ["threadsSource", "resolvedClumpingToolSource", "qualityBinningSource"] {
                XCTAssertEqual(resolved[key], .string("plan"), "\(label) \(key)")
            }
        }
    }
}
