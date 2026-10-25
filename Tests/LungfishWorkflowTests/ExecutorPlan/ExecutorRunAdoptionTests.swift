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

    /// A returned plan folder: the emitter's plan, a payload and a succeeded run record that is true to both. The
    /// builder is in LungfishTestSupport, where the CLI's process tests of the adopt build the same folder.
    private typealias Returned = ExecutorReturnedFolder

    private func returned(_ clumping: ClumpingTool, siteFacts: [PlanKeyValue] = []) throws -> Returned {
        try ExecutorReturnedFolder.make(root: root, clumping: clumping, siteFacts: siteFacts)
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
    /// MiB and Disk in KiB, any other key under its own name, one job row, and each fact the CHTC template asks for
    /// that the record lacks as Not recorded. Every key lane H's template passes has a label (lane U), and the
    /// Apptainer and HTCondor versions it does not pass show no row.
    func testSiteFactRowsShowLauncherWordsLabelsAndUnits() {
        let facts = Self.chtcFacts.map { ProvenanceSiteFact(key: $0.key, value: $0.value) }
        let rows = ProvenanceSiteFactRows.rows(facts).map { "\($0.label): \($0.value)" }
        XCTAssertEqual(rows, [
            "Reported by the launcher: Passed in by the program that started the run, such as HTCondor. Lungfish shows them as given and did not check them.",
            "Machine name: e4004.chtc.wisc.edu", "CPU architecture: X86_64", "CPU microarchitecture: x86_64-v3",
            "Operating system: CentOS9", "Operating system major version: 9", "Kernel release: 5.14.0-620.el9.x86_64",
            "CPUs: 1", "Memory: 1024 MiB", "Disk: 16777216 KiB", "HTCondor job: 593367.0",
        ])
        let withoutDisk = ProvenanceSiteFactRows.rows(facts.filter { $0.key != "Disk" }).map { "\($0.label): \($0.value)" }
        XCTAssertEqual(withoutDisk.last, "Disk: Not recorded")
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


    /// Each file under a folder with its bytes, so a test can tell that nothing was written.
    private static func files(under folder: URL) -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            files[url.path] = (try? Data(contentsOf: url)) ?? Data()
        }
        return files
    }

    /// Review A2 fix 1: `--dry-run` says what the real run does. With the bundle in place it refuses without `--force`
    /// as the adopt does, names the sample with `--force`, and writes nothing either way.
    func testAdoptDryRunRefusesExistingBundleWithoutForce() async throws {
        let returned = try returned(.bbtools)
        XCTAssertEqual(try ExecutorRunAdoption.dryRun(resultFolder: returned.folder, projectDirectory: project), "S")
        let bundle = try await ExecutorRunAdoption.adopt(resultFolder: returned.folder, projectDirectory: project)
        let before = Self.files(under: project)
        XCTAssertThrowsError(try ExecutorRunAdoption.dryRun(resultFolder: returned.folder, projectDirectory: project, force: false)) {
            guard case BatchImportError.outputBundleAlreadyExists(let url) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(url.standardizedFileURL.path, bundle.standardizedFileURL.path)
        }
        XCTAssertEqual(try ExecutorRunAdoption.dryRun(resultFolder: returned.folder, projectDirectory: project, force: true), "S")
        XCTAssertEqual(Self.files(under: project), before)
    }

    /// The refusal the dry run raises, or nil when it says the adopt would succeed.
    private func dryRunRefusal(_ returned: Returned) -> ExecutorAdoptRefusal? {
        do {
            _ = try ExecutorRunAdoption.dryRun(resultFolder: returned.folder, projectDirectory: project)
            return nil
        } catch let refusal as ExecutorAdoptRefusal {
            return refusal
        } catch {
            XCTFail("The dry run failed with \(error) in place of a refusal")
            return nil
        }
    }

    /// AMV1 SWIFT fix 1: the dry run and the adopt share one preflight, so a record that only the bundle step used to
    /// refuse (no seqkit table, or a text the Mac's parse rejects) is refused by `--dry-run` as well, with the same field
    /// and words, and neither run makes a bundle file or an `Imports` folder.
    func testAdoptDryRunRefusesWhatTheAdoptRefuses() async throws {
        let notATable = "not a seqkit table"
        let cases: [(label: String, output: ExecutorCapturedOutput?)] = [
            ("no seqkit stats output", nil),
            ("a text that is not a seqkit table", ExecutorCapturedOutput(
                text: notATable, sha256: PortableDigest.sha256Hex(of: Data(notATable.utf8)), size: Int64(notATable.utf8.count)
            )),
        ]
        for (label, output) in cases {
            var changed = try returned(.bbtools)
            let index = try XCTUnwrap(changed.record.steps.firstIndex { $0.kind == .statistics }, label)
            changed.record.steps[index].standardOutput = output
            try changed.write()
            let dry = try XCTUnwrap(dryRunRefusal(changed), "\(label): the dry run passed a run the adopt refuses")
            let outcome = await refusal(changed)
            let refused = try XCTUnwrap(outcome, label)
            XCTAssertEqual(dry.field, "steps[\(index)]", label)
            XCTAssertEqual(refused.field, dry.field, label)
            XCTAssertEqual(refused.reason, dry.reason, label)
            XCTAssertEqual(importedEntries(), [], label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Imports").path), label)
            try FileManager.default.removeItem(at: changed.folder)
            try FileManager.default.removeItem(at: root.appendingPathComponent("S", isDirectory: true))
        }
        // ARCH-X3 R-2: the four input refusals, each named by the plan's input index, the same from the dry run.
        let inputCases: [(label: String, change: (inout Returned, PlanEntry) throws -> Void)] = [
            ("an absent input the record does not state", { returned, pin in
                returned.record.inputs = []
                try FileManager.default.removeItem(at: returned.folder.appendingPathComponent(pin.relativePath))
            }),
            ("a record digest off the plan", { returned, pin in
                for index in returned.record.inputs.indices where returned.record.inputs[index].relativePath == pin.relativePath {
                    returned.record.inputs[index].sha256 = String(repeating: "d", count: 64)
                }
            }),
            ("a present input off the plan", { returned, pin in
                let url = returned.folder.appendingPathComponent(pin.relativePath)
                var bytes = try Data(contentsOf: url)
                bytes[1] ^= 0x01
                try bytes.write(to: url)
            }),
            ("a present input that cannot be read", { returned, pin in
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0], ofItemAtPath: returned.folder.appendingPathComponent(pin.relativePath).path
                )
            }),
        ]
        for (label, change) in inputCases {
            var changed = try returned(.bbtools)
            let pin = try XCTUnwrap(changed.plan.entries.first { $0.role == .input }, label)
            try change(&changed, pin)
            try changed.write()
            let dry = try XCTUnwrap(dryRunRefusal(changed), "\(label): the dry run passed a run the adopt refuses")
            let outcome = await refusal(changed)
            let refused = try XCTUnwrap(outcome, label)
            XCTAssertEqual(dry.field, "inputs[0]", label)
            XCTAssertEqual(refused.field, dry.field, label)
            XCTAssertEqual(refused.reason, dry.reason, label)
            XCTAssertTrue(refused.reason.hasSuffix("Nothing was imported."), refused.reason)
            XCTAssertEqual(importedEntries(), [], label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Imports").path), label)
            try FileManager.default.removeItem(at: changed.folder)
            try FileManager.default.removeItem(at: root.appendingPathComponent("S", isDirectory: true))
        }
    }

    /// The plan's input entries of a returned folder, in the plan's order.
    private func inputPins(_ returned: Returned) -> [PlanEntry] {
        returned.plan.entries.filter { $0.role == .input }
    }

    /// ARCH-X3 R-2: a CHTC job reads its inputs from /staging and returns none, so the adopt takes each input's digest and
    /// size from the record's checked inputs. With the inputs gone the dry run and the adopt pass, and the envelope's input
    /// records, the run's and the import step's, carry the plan's SHA-256 and size.
    func testAdoptTakesAbsentInputsFromRunRecord() async throws {
        let returned = try returned(.bbtools)
        let pins = inputPins(returned)
        XCTAssertEqual(pins.count, 2)
        for pin in pins { try FileManager.default.removeItem(at: returned.folder.appendingPathComponent(pin.relativePath)) }
        XCTAssertNil(dryRunRefusal(returned))
        let bundle = try await ExecutorRunAdoption.adopt(resultFolder: returned.folder, projectDirectory: project)
        let envelope = try envelope(bundle)
        let importStep = try XCTUnwrap(envelope.steps.last)
        XCTAssertEqual(importStep.toolName, "lungfish import fastq")
        for pin in pins {
            let file = try XCTUnwrap(
                envelope.files.first { $0.role == .input && $0.path.hasSuffix("/" + pin.relativePath) }, pin.relativePath
            )
            XCTAssertEqual(file.checksumSHA256, pin.sha256, pin.relativePath)
            XCTAssertEqual(file.fileSize.map { Int64($0) }, pin.size, pin.relativePath)
            let stepInput = try XCTUnwrap(importStep.inputs.first { $0.path == file.path }, pin.relativePath)
            XCTAssertEqual(stepInput.checksumSHA256, pin.sha256, pin.relativePath)
            XCTAssertEqual(stepInput.fileSize.map { Int64($0) }, pin.size, pin.relativePath)
        }
    }

    /// ARCH-X3 R-2: an input that is neither in the folder nor stated by the record is refused before any bundle file,
    /// naming the plan's input index and the fix with the pin's SHA-256.
    func testAdoptRefusesAbsentInputTheRecordDoesNotState() async throws {
        var returned = try returned(.bbtools)
        let pin = try XCTUnwrap(inputPins(returned).first)
        returned.record.inputs = []
        try returned.write()
        try FileManager.default.removeItem(at: returned.folder.appendingPathComponent(pin.relativePath))
        let outcome = await refusal(returned)
        let refused = try XCTUnwrap(outcome)
        XCTAssertEqual(refused.field, "inputs[0]")
        XCTAssertTrue(refused.reason.contains("Copy the file the plan pins"), refused.reason)
        XCTAssertTrue(refused.reason.contains(pin.sha256), refused.reason)
        XCTAssertTrue(refused.reason.contains("\(pin.size) bytes"), refused.reason)
        XCTAssertEqual(importedEntries(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Imports/S.lungfishfastq").path))
    }

    /// ARCH-X3 R-2: a record that states another digest for an input than the plan pins is refused, naming both.
    func testAdoptRefusesRecordInputDigestOffThePlan() async throws {
        var returned = try returned(.bbtools)
        let pin = try XCTUnwrap(inputPins(returned).first)
        let index = try XCTUnwrap(returned.record.inputs.firstIndex { $0.relativePath == pin.relativePath })
        let stated = String(repeating: "d", count: 64)
        returned.record.inputs[index].sha256 = stated
        try returned.write()
        let outcome = await refusal(returned)
        let refused = try XCTUnwrap(outcome)
        XCTAssertEqual(refused.field, "inputs[0]")
        XCTAssertTrue(refused.reason.contains(stated), refused.reason)
        XCTAssertTrue(refused.reason.contains(pin.sha256), refused.reason)
        XCTAssertEqual(importedEntries(), [])
    }

    /// ARCH-X3 R-2: an input file in the folder is still hashed, and one changed byte refuses the adopt with the fix.
    func testAdoptRefusesPresentInputOffThePlan() async throws {
        let returned = try returned(.bbtools)
        let pin = try XCTUnwrap(inputPins(returned).first)
        let url = returned.folder.appendingPathComponent(pin.relativePath)
        var bytes = try Data(contentsOf: url)
        bytes[1] ^= 0x01
        try bytes.write(to: url)
        let outcome = await refusal(returned)
        let refused = try XCTUnwrap(outcome)
        XCTAssertEqual(refused.field, "inputs[0]")
        XCTAssertTrue(refused.reason.contains("Remove it, or replace it"), refused.reason)
        XCTAssertTrue(refused.reason.contains(pin.sha256), refused.reason)
        XCTAssertEqual(importedEntries(), [])
    }

    /// AMV1 BIO fix 2 (a): the seqkit table that becomes the sidecar's statistics must describe the payload. A record
    /// whose statistics step read another file than the payload is refused by the dry run and by the adopt, naming the
    /// step's `inputFile`, and the unchanged record passes the dry run.
    func testAdoptRefusesStatisticsTableOfAnotherFile() async throws {
        var changed = try returned(.bbtools)
        XCTAssertEqual(try ExecutorRunAdoption.dryRun(resultFolder: changed.folder, projectDirectory: project), "S")
        let index = try XCTUnwrap(changed.record.steps.firstIndex { $0.kind == .statistics })
        let payload = changed.record.payloads[0]
        changed.record.steps[index].inputFile = ExecutorFileDigest(
            relativePath: payload.relativePath, sha256: String(repeating: "e", count: 64), size: payload.size
        )
        try changed.write()
        let dry = try XCTUnwrap(dryRunRefusal(changed), "the dry run passed a table of another file")
        let outcome = await refusal(changed)
        let refused = try XCTUnwrap(outcome, "the adopt took a table of another file")
        XCTAssertEqual(dry.field, "steps[\(index)].inputFile")
        XCTAssertEqual(refused.field, dry.field)
        XCTAssertEqual(refused.reason, dry.reason)
        XCTAssertEqual(importedEntries(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Imports").path))
    }

    /// Lane U's two fills (U.md Handoff a): the run identity names the node's kernel, machine, executor build and SHA-256
    /// and its orphan sweep as the record states them, and each node step names its tool as the record does, with the
    /// plan step's title on a step the executor ran itself.
    func testAdoptedEnvelopeNamesNodeRuntimeAndStepTools() async throws {
        let returned = try returned(.bbtools)
        let bundle = try await ExecutorRunAdoption.adopt(resultFolder: returned.folder, projectDirectory: project)
        let node = try XCTUnwrap(try envelope(bundle).runtimeIdentity.nodeRuntime)
        XCTAssertEqual(node.kernelRelease, "5.14.0-503.el9.x86_64")
        XCTAssertEqual(node.machine, "x86_64")
        // U review fix 1: the build is the pin's commit, the `build` of the executor's own tool record, not its version.
        XCTAssertEqual(node.executorBuild, returned.record.executor.buildPin?.lgeCommit)
        XCTAssertNotEqual(node.executorBuild, returned.record.executor.buildPin?.lgeVersion)
        XCTAssertEqual(node.executorSHA256, ExecutorPlanTestSupport.digest)
        XCTAssertEqual(node.orphanSweep, "subreaper")

        let record = try Data(contentsOf: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        let steps = try XCTUnwrap((try JSONSerialization.jsonObject(with: record) as? [String: Any])?["steps"] as? [[String: Any]])
        let executor = steps.first { $0["toolName"] as? String == ExecutorRunAdoption.executorToolName }
        let executorID = try XCTUnwrap(executor?["id"] as? String)
        let nodeSteps = steps.filter { $0["parentStepID"] as? String == executorID }
        XCTAssertEqual(nodeSteps.count, returned.record.steps.count)
        var titled = 0
        for (step, recorded) in zip(nodeSteps, returned.record.steps) {
            let options = step["resolvedOptions"] as? NSDictionary
            guard let tool = recorded.tool else {
                XCTAssertNil(options?[ProvenanceNodeStepOptions.toolKey], recorded.id)
                continue
            }
            let title = tool.id == ExecutorRunAdoption.executorBinaryName
                ? returned.plan.steps.first { $0.id == recorded.id }?.title : nil
            if title != nil { titled += 1 }
            let expected = ProvenanceNodeStepOptions.options(
                toolID: tool.id, version: tool.version, build: tool.build, versionSource: tool.versionSource.rawValue, title: title
            )
            let expectedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? NSDictionary
            XCTAssertEqual(options, expectedJSON, recorded.id)
        }
        print("ADOPT-NODE-STEPS steps=\(nodeSteps.count) titled=\(titled)")
    }

    /// BIO's binding (A-BIO O1, A2 Handoff a): the adopted sidecar's statistics are the record's `seqkit stats -a -T`
    /// table through the Mac's own parse, with Q20 and Q30 from the record's counts, which cover the bases seqkit summed.
    func testAdoptedSidecarCarriesRecordStatistics() async throws {
        let returned = try returned(.bbtools)
        let bundle = try await ExecutorRunAdoption.adopt(resultFolder: returned.folder, projectDirectory: project)
        let sidecar = try XCTUnwrap(FASTQMetadataStore.load(for: bundle.appendingPathComponent("S.fastq.gz")))
        let statistics = try XCTUnwrap(sidecar.computedStatistics)
        let seqkit = try XCTUnwrap(sidecar.seqkitStats)
        XCTAssertEqual(statistics.readCount, 2)
        XCTAssertEqual(statistics.baseCount, 20)
        XCTAssertEqual(statistics.n50ReadLength, 10)
        XCTAssertEqual(statistics.medianReadLength, 10)
        XCTAssertEqual(statistics.gcContent, 0.5, accuracy: 1e-9)
        XCTAssertEqual(seqkit.numSeqs, 2)
        // The record counted 20 of 20 bases at Q20 and at Q30, so its counts replace seqkit's whole percents (95, 91).
        XCTAssertEqual(statistics.q20Percentage, 100, accuracy: 1e-9)
        XCTAssertEqual(statistics.q30Percentage, 100, accuracy: 1e-9)
    }

    /// BIO 4 and BIO 6: a record whose steps are not the plan's is refused with the step's field before any bundle file
    /// exists, so no value of the bundle's records comes from a default. A step dropped, added or renamed, a step that
    /// did not succeed, a storage or Q20 and Q30 step without its details, and a time that is not a time.
    func testAdoptRefusesRecordWhoseStepsAreNotThePlans() async throws {
        func index(of kind: PlanStepKind, in returned: Returned) throws -> Int {
            try XCTUnwrap(returned.plan.steps.firstIndex(where: { $0.kind == kind }), kind.rawValue)
        }
        let cases: [(label: String, words: String, change: (inout Returned) throws -> String)] = [
            ("a dropped storage step", "storage of kind storage", { returned in
                let at = try index(of: .storage, in: returned)
                returned.record.steps.remove(at: at)
                return "steps[\(at)]"
            }),
            ("an added step", "and the plan has", { returned in
                returned.record.steps.append(returned.record.steps[0])
                return "steps[\(returned.plan.steps.count)]"
            }),
            ("a renamed step", "is not the plan's step", { returned in
                let at = try index(of: .qualityCount, in: returned)
                returned.record.steps[at].id = "recipe-9"
                return "steps[\(at)]"
            }),
            ("a failed step", "outcome failed", { returned in
                let at = try index(of: .statistics, in: returned)
                returned.record.steps[at].outcome = .failed
                return "steps[\(at)]"
            }),
            ("a storage step without its details", "no storage details", { returned in
                let at = try index(of: .storage, in: returned)
                returned.record.steps[at].storage = nil
                return "steps[\(at)]"
            }),
            ("a Q20 and Q30 step without its counts", "no Q20 and Q30 count", { returned in
                let at = try index(of: .qualityCount, in: returned)
                returned.record.steps[at].qualityCounts = nil
                return "steps[\(at)]"
            }),
            ("a step time that is not a time", "startedAt", { returned in
                let at = try index(of: .storage, in: returned)
                returned.record.steps[at].startedAt = "soon"
                return "steps[\(at)]"
            }),
            ("a record time that is not a time", "endedAt", { returned in
                returned.record.endedAt = "soon"
                return "endedAt"
            }),
        ]
        for (label, words, change) in cases {
            var changed = try returned(.bbtools)
            let field = try change(&changed)
            try changed.write()
            let outcome = await refusal(changed)
            let refused = try XCTUnwrap(outcome, label)
            XCTAssertEqual(refused.field, field, label)
            XCTAssertTrue(refused.reason.contains(words), "\(label): \(refused.reason)")
            XCTAssertTrue(refused.reason.hasSuffix("Nothing was imported."), label)
            XCTAssertEqual(importedEntries(), [], label)
            try FileManager.default.removeItem(at: changed.folder)
            try FileManager.default.removeItem(at: root.appendingPathComponent("S", isDirectory: true))
        }
    }
}
