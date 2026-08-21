import Foundation
import Testing
@testable import LungfishWorkflow

@Suite("Metagenomics database installer")
struct MetagenomicsDatabaseInstallerTests {
    @Test("replacement stays reversible until finalize and rollback restores the prior bytes")
    func replacementTransactionFinalizesOrRollsBack() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let final = fixture.root.appendingPathComponent("kraken2/fixture", isDirectory: true)
        try Fixture.writeKrakenPayload(to: final)
        try Data("old provenance".utf8).write(
            to: final.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        )
        let oldBytes = try Fixture.directoryBytes(at: final)

        let first = try await fixture.installer(tools: FixtureToolRunner()).prepareInstallation(
            database: fixture.database(recipe: .kraken2Special(type: .silva)),
            databasesBaseURL: fixture.root,
            threads: 4,
            progress: { _, _ in }
        )
        #expect(try Fixture.directoryBytes(at: final) != oldBytes)
        #expect(try Fixture.transactionDirectories(beside: final).filter { $0.lastPathComponent.hasPrefix(".backup-") }.count == 1)

        try fixture.installer(tools: FixtureToolRunner()).rollback(first)
        #expect(try Fixture.directoryBytes(at: final) == oldBytes)
        #expect(try Fixture.transactionDirectories(beside: final).isEmpty)

        let second = try await fixture.installer(tools: FixtureToolRunner()).prepareInstallation(
            database: fixture.database(recipe: .kraken2Special(type: .silva)),
            databasesBaseURL: fixture.root,
            threads: 4,
            progress: { _, _ in }
        )
        let stagingRoots = fixture.writer.successes.compactMap {
            $0.attempt.resolvedOptions["databaseRoot"]?.fileValue?.path
        }
        #expect(stagingRoots.count == 2)
        #expect(Set(stagingRoots).count == 2)
        #expect(stagingRoots.allSatisfy { $0.contains("/.install-") })
        try fixture.installer(tools: FixtureToolRunner()).finalize(second)
        #expect(FileManager.default.fileExists(atPath: final.path))
        #expect(try Fixture.transactionDirectories(beside: final).isEmpty)
    }

    @Test("prepared success requires a decodable final receipt with its payload digest")
    func preparedSuccessVerifiesFinalReceiptDigest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.writer.omitSuccessReceipt = true

        await #expect(throws: MetagenomicsDatabaseInstallerError.self) {
            _ = try await fixture.installer(tools: FixtureToolRunner()).prepareInstallation(
                database: fixture.database(recipe: .kraken2Special(type: .silva)),
                databasesBaseURL: fixture.root,
                threads: 4,
                progress: { _, _ in }
            )
        }
        let final = fixture.root.appendingPathComponent("kraken2/fixture", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(try Fixture.transactionDirectories(beside: final).isEmpty)
    }

    @Test("backup cleanup failure reports a diagnostic without reverting the valid payload")
    func backupCleanupFailureKeepsCommittedPayload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let final = fixture.root.appendingPathComponent("kraken2/fixture", isDirectory: true)
        try Fixture.writeKrakenPayload(to: final)
        let fileSystem = FailingCleanupFileSystem()
        let installer = fixture.installer(tools: FixtureToolRunner(), fileSystem: fileSystem)
        let prepared = try await installer.prepareInstallation(
            database: fixture.database(recipe: .kraken2Special(type: .silva)),
            databasesBaseURL: fixture.root,
            threads: 4,
            progress: { _, _ in }
        )

        #expect(throws: MetagenomicsDatabaseInstallerError.self) {
            try installer.finalize(prepared)
        }
        #expect(FileManager.default.fileExists(atPath: final.appendingPathComponent("hash.k2d").path))
        #expect(try ProvenanceEnvelopeReader.loadCanonical(from: final) != nil)
    }

    @Test("SILVA uses the managed special and Bracken recipes with generic progress")
    func silvaRecipeUsesExactCommands() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let tools = FixtureToolRunner()
        let installer = fixture.installer(tools: tools)

        let prepared = try await installer.prepareInstallation(
            database: fixture.database(recipe: .kraken2Special(type: .silva)),
            databasesBaseURL: fixture.root,
            threads: 4,
            progress: { _, message in fixture.messages.append(message) }
        )

        #expect(tools.calls.count == 2)
        #expect(tools.calls[0] == .init(
            name: "kraken2-build",
            arguments: ["--db", tools.calls[0].arguments[1], "--special", "silva"],
            environment: "kraken2"
        ))
        #expect(tools.calls[1] == .init(
            name: "bracken-build",
            arguments: [
                "-d", tools.calls[0].arguments[1], "-t", "4", "-k", "35", "-l", "150",
                "-x", fixture.krakenBin.path, "-y", "kraken2",
            ],
            environment: "bracken"
        ))
        #expect(fixture.messages.allSatisfy { ["Downloading…", "Preparing…", "Verifying…"].contains($0) })
        #expect(!fixture.messages.contains { $0.localizedCaseInsensitiveContains("build") || $0.contains("kraken2-build") })
    }

    @Test("step evidence names the invoked executable rather than an argv value")
    func evidenceUsesInvokedToolNames() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let installer = fixture.installer(tools: FixtureToolRunner())

        _ = try await installer.prepareInstallation(
            database: fixture.database(recipe: .kraken2Special(type: .silva)),
            databasesBaseURL: fixture.root,
            threads: 4,
            progress: { _, _ in }
        )

        let attempt = try #require(fixture.writer.successes.first?.attempt)
        #expect(attempt.steps.map(\.toolName) == ["kraken2-build", "bracken-build"])
        #expect(attempt.steps.map(\.toolVersion) == ["1.0", "1.0"])
    }

    @Test("Bracken database provenance resolves the managed source overlay before stale conda metadata")
    func managedBrackenVersionWinsOverCondaPackageMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-bracken-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = CondaManager(rootPrefix: root)
        let environment = await manager.environmentURL(named: "bracken")
        let condaMeta = environment.appendingPathComponent("conda-meta", isDirectory: true)
        try FileManager.default.createDirectory(at: condaMeta, withIntermediateDirectories: true)
        try "{\"name\":\"bracken\",\"version\":\"1.0.0\",\"subdir\":\"noarch\"}".write(
            to: condaMeta.appendingPathComponent("bracken-1.0.0-0.json"),
            atomically: true,
            encoding: .utf8
        )
        for package in managedBrackenRuntimePackages {
            let metadata = "{\"name\":\"\(package.name)\",\"version\":\"\(package.version)\",\"build\":\"\(package.build)\",\"subdir\":\"\(package.subdir)\"}"
            try metadata.write(
                to: condaMeta.appendingPathComponent("\(package.name)-\(package.version)-\(package.build).json"),
                atomically: true,
                encoding: .utf8
            )
        }
        let compiler = environment.appendingPathComponent("bin/c++")
        try FileManager.default.createDirectory(
            at: compiler.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: compiler, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compiler.path)
        let openMPRuntime = environment.appendingPathComponent("lib/libomp.dylib")
        try FileManager.default.createDirectory(
            at: openMPRuntime.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("OpenMP runtime\n".utf8).write(to: openMPRuntime)
        let overlay = PackToolSourceOverlay(
            kind: .bracken,
            version: "3.1",
            sourceURL: URL(string: "https://example.test/Bracken-v3.1.tar.gz")!,
            sha256: String(repeating: "a", count: 64)
        )
        let fixtureFiles = ["bin/bracken", "bin/bracken-build", "bin/src/kmer2read_distr"]
        let installedFiles = try fixtureFiles.map { relativePath in
            let url = environment.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture \(relativePath)\n".utf8).write(to: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let sha256 = ManagedToolSourceInstallationRecord.sha256(of: url) else {
                throw CocoaError(.fileReadUnknown)
            }
            return ManagedToolSourceInstallationRecord.InstalledFile(
                relativePath: relativePath,
                sha256: sha256,
                sizeBytes: (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            )
        }
        let record = ManagedToolSourceInstallationRecord(
            source: overlay,
            commands: [.init(argv: ["bracken-build", "-v"], reproducibleCommand: "bracken-build -v")],
            runtime: .init(
                environmentPath: environment.path,
                compilerPath: compiler.path,
                openMPRuntimePath: openMPRuntime.path,
                condaPackages: managedBrackenRuntimePackages
            ),
            installedFiles: installedFiles,
            startedAt: .now,
            completedAt: .now,
            wallTimeSeconds: 0,
            exitStatus: 0,
            stderr: ""
        )
        let recordURL = environment.appendingPathComponent("share/lungfish/managed-tools/bracken.json")
        try record.write(to: recordURL)

        let version = try await ManagedMetagenomicsDatabaseToolRunner.resolveManagedToolVersion(
            manager,
            "bracken-build",
            "bracken",
            root
        )

        #expect(version == "3.1")
    }

    @Test("Greengenes selects its exact special source")
    func greengenesRecipeUsesExactSpecial() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let tools = FixtureToolRunner()
        let installer = fixture.installer(tools: tools)

        _ = try await installer.prepareInstallation(
            database: fixture.database(recipe: .kraken2Special(type: .greengenes)),
            databasesBaseURL: fixture.root,
            threads: 4,
            progress: { _, _ in }
        )

        #expect(tools.calls.first?.arguments.suffix(2) == ["--special", "greengenes"])
    }

    @Test("archive recipes record archive evidence before injected extraction")
    func archiveRecipeUsesTransferWithoutBuildExecutables() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let archive = fixture.root.appendingPathComponent("fixture.tar.gz")
        try Data("archive payload".utf8).write(to: archive)
        let tools = FixtureToolRunner()
        let transfer = FixtureArchiveTransfer(archive: archive) { destination in
            try Fixture.writeKrakenPayload(to: destination, special: false)
        }
        let installer = fixture.installer(tools: tools, transfer: transfer)

        let prepared = try await installer.prepareInstallation(
            database: fixture.database(recipe: .archive(url: URL(string: "https://example.test/db.tar.gz")!)),
            databasesBaseURL: fixture.root,
            threads: 4,
            progress: { _, _ in }
        )

        #expect(transfer.downloaded)
        #expect(transfer.extracted)
        #expect(tools.calls.isEmpty)
        let attempt = try #require(fixture.writer.successes.first?.attempt)
        let archiveInput = try #require(attempt.steps.first?.inputs.first)
        #expect(archiveInput.checksumSHA256 != nil)
        #expect(archiveInput.fileSize == UInt64("archive payload".utf8.count))
        #expect(prepared.result.payloadDigest.isEmpty == false)
    }

    @Test("archive extraction failures retain planned tar evidence and write an output-free receipt")
    func archiveExtractionFailureWritesReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let archive = fixture.root.appendingPathComponent("fixture.tar.gz")
        try Data("archive payload".utf8).write(to: archive)
        let transfer = FixtureArchiveTransfer(
            archive: archive,
            extractionError: FixtureError.transfer
        )

        await #expect(throws: FixtureError.transfer) {
            _ = try await fixture.installer(
                tools: FixtureToolRunner(),
                transfer: transfer
            ).prepareInstallation(
                database: fixture.database(recipe: .archive(url: URL(string: "https://example.test/db.tar.gz")!)),
                databasesBaseURL: fixture.root,
                threads: 4,
                progress: { _, _ in }
            )
        }

        let failure = try #require(fixture.writer.failures.only)
        let tar = try #require(failure.attempt.steps.only)
        #expect(tar.toolName == "tar")
        #expect(tar.toolVersion == "bsdtar fixture")
        #expect(tar.argv.first == "/usr/bin/tar")
        #expect(tar.outputs.isEmpty)
        #expect(failure.error.provenanceExitStatus != 0)
    }

    @Test("archive download cancellation records canonical cancellation status")
    func archiveDownloadCancellationWritesCancelledReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transfer = FixtureArchiveTransfer(cancelDuringDownload: true)
        let task = Task {
            try await fixture.installer(
                tools: FixtureToolRunner(),
                transfer: transfer
            ).prepareInstallation(
                database: fixture.database(recipe: .archive(url: URL(string: "https://example.test/db.tar.gz")!)),
                databasesBaseURL: fixture.root,
                threads: 4,
                progress: { _, _ in }
            )
        }

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(fixture.writer.failures.only?.error.provenanceExitStatus == 130)
    }

    @Test("tar cancellation is checked before a terminated process is classified as failure")
    func archiveExtractionCancellationWritesCancelledReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let archive = fixture.root.appendingPathComponent("fixture.tar.gz")
        try Data("archive payload".utf8).write(to: archive)
        let transfer = FixtureArchiveTransfer(archive: archive, cancelDuringExtraction: true)
        let task = Task {
            try await fixture.installer(
                tools: FixtureToolRunner(),
                transfer: transfer
            ).prepareInstallation(
                database: fixture.database(recipe: .archive(url: URL(string: "https://example.test/db.tar.gz")!)),
                databasesBaseURL: fixture.root,
                threads: 4,
                progress: { _, _ in }
            )
        }

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let failure = try #require(fixture.writer.failures.only)
        #expect(failure.error.provenanceExitStatus == 130)
        #expect(failure.attempt.steps.only?.outputs.isEmpty == true)
    }

    @Test("a pre-existing destination survives an installer failure before promotion")
    func existingDestinationSurvivesFailureBeforePromotion() async throws {
        let fixture = try Fixture(mutation: .missingCore)
        defer { fixture.cleanup() }
        let final = fixture.root.appendingPathComponent("kraken2/fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        let sentinel = final.appendingPathComponent("keep-me")
        try Data("sentinel".utf8).write(to: sentinel)

        await #expect(throws: MetagenomicsDatabaseInstallerError.self) {
            _ = try await fixture.installer(tools: FixtureToolRunner()).prepareInstallation(
                database: fixture.database(recipe: .kraken2Special(type: .silva)),
                databasesBaseURL: fixture.root,
                threads: 4,
                progress: { _, _ in }
            )
        }

        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("tar extraction records its injected tar version")
    func extractionUsesInjectedTarVersion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let archive = fixture.root.appendingPathComponent("fixture.tar.gz")
        try Data().write(to: archive)
        let destination = fixture.root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let transfer = URLSessionTarDatabaseArchiveTransfer(tarVersion: { "bsdtar 3.7.0 - libarchive" })

        let result = try await transfer.extract(archive: archive, destination: destination)

        #expect(result.toolVersion == "bsdtar 3.7.0")
        #expect(result.runtimeIdentity.executablePath == "/usr/bin/tar")
    }

    @Test("HTTP archive responses reject non-success status codes")
    func archiveHTTPResponseValidationRejectsNonSuccessStatus() throws {
        let url = try #require(URL(string: "https://example.test/database.tar.gz"))
        let notFound = try #require(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
        let success = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))

        #expect(throws: MetagenomicsDatabaseInstallerError.archiveTransferFailed("HTTP 404 while downloading https://example.test/database.tar.gz")) {
            try URLSessionTarDatabaseArchiveTransfer.validateHTTPResponse(notFound)
        }
        try URLSessionTarDatabaseArchiveTransfer.validateHTTPResponse(success)
    }

    @Test("special recipe rejects malformed required payload evidence")
    func specialPayloadValidationRejectsMissingFiles() async throws {
        for mutation in Fixture.PayloadMutation.allCases {
            let fixture = try Fixture(mutation: mutation)
            defer { fixture.cleanup() }
            let tools = FixtureToolRunner()
            let installer = fixture.installer(tools: tools)
            await #expect(throws: MetagenomicsDatabaseInstallerError.self) {
                _ = try await installer.prepareInstallation(
                    database: fixture.database(recipe: .kraken2Special(type: .silva)),
                    databasesBaseURL: fixture.root,
                    threads: 4,
                    progress: { _, _ in }
                )
            }
        }
    }

    @Test("missing managed executable explains how to install the Metagenomics pack")
    func missingExecutableIsActionable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let tools = FixtureToolRunner(missingExecutable: "kraken2-build")
        let installer = fixture.installer(tools: tools)

        await #expect(throws: MetagenomicsDatabaseInstallerError.missingManagedTool(name: "kraken2-build")) {
            _ = try await installer.prepareInstallation(
                database: fixture.database(recipe: .kraken2Special(type: .silva)),
                databasesBaseURL: fixture.root,
                threads: 4,
                progress: { _, _ in }
            )
        }
    }

    @Test("missing Bracken executable explains how to install the Metagenomics pack")
    func missingBrackenExecutableIsActionable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let tools = FixtureToolRunner(missingExecutable: "bracken-build")
        let installer = fixture.installer(tools: tools)

        await #expect(throws: MetagenomicsDatabaseInstallerError.missingManagedTool(name: "bracken-build")) {
            _ = try await installer.prepareInstallation(
                database: fixture.database(recipe: .kraken2Special(type: .silva)),
                databasesBaseURL: fixture.root,
                threads: 4,
                progress: { _, _ in }
            )
        }
        #expect(tools.calls.isEmpty)
    }

    @Test("tool failures retain bounded stderr and produce a failure receipt")
    func failedToolWritesFailureReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let tools = FixtureToolRunner(resultStatuses: [42])
        let installer = fixture.installer(tools: tools)

        await #expect(throws: MetagenomicsDatabaseInstallerError.toolFailed(
            tool: "kraken2-build", exitStatus: 42, stderr: String(repeating: "e", count: 16_384)
        )) {
            _ = try await installer.prepareInstallation(
                database: fixture.database(recipe: .kraken2Special(type: .silva)),
                databasesBaseURL: fixture.root,
                threads: 4,
                progress: { _, _ in }
            )
        }
        #expect(fixture.writer.failures.count == 1)
        #expect(fixture.writer.failures[0].error.provenanceExitStatus == 42)
    }

    @Test("receipt failures retain the original tool error and append the receipt diagnostic")
    func failureReceiptDiagnosticPreservesOriginalFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.writer.failureError = FixtureError.receipt
        let installer = fixture.installer(tools: FixtureToolRunner(resultStatuses: [42]))

        await #expect(throws: MetagenomicsDatabaseInstallerError.failureReceiptDiagnostic(
            original: "kraken2-build failed with exit status 42: \(String(repeating: "e", count: 16_384))",
            receipt: "receipt fixture failure"
        )) {
            _ = try await installer.prepareInstallation(
                database: fixture.database(recipe: .kraken2Special(type: .silva)),
                databasesBaseURL: fixture.root,
                threads: 4,
                progress: { _, _ in }
            )
        }
    }

    @Test("provenance write failures block prepared results")
    func provenanceFailureIsFatal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.writer.successError = FixtureError.provenance
        let installer = fixture.installer(tools: FixtureToolRunner())

        await #expect(throws: FixtureError.provenance) {
            _ = try await installer.prepareInstallation(
                database: fixture.database(recipe: .kraken2Special(type: .silva)),
                databasesBaseURL: fixture.root,
                threads: 4,
                progress: { _, _ in }
            )
        }
    }

    @Test("cancellation after promotion removes the unpublished final directory and records output-free failure evidence")
    func cancellationAfterPromotionRollsBackFinalDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.writer.cancelCurrentTaskAfterSuccessWrite = true
        let installer = fixture.installer(tools: FixtureToolRunner())

        let task = Task {
            _ = try await installer.prepareInstallation(
                database: fixture.database(recipe: .kraken2Special(type: .silva)),
                databasesBaseURL: fixture.root,
                threads: 4,
                progress: { _, _ in }
            )
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }

        let final = fixture.root.appendingPathComponent("kraken2/fixture", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(fixture.writer.successes.count == 1)
        #expect(fixture.writer.failures.count == 1)
        #expect(fixture.writer.failures[0].attempt.steps.allSatisfy { $0.outputs.isEmpty })
    }

    @Test("cancellation before work produces no successful prepared result")
    func cancellationBeforeWork() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let installer = fixture.installer(tools: FixtureToolRunner())
        let task = Task {
            try await installer.prepareInstallation(
                database: fixture.database(recipe: .kraken2Special(type: .silva)),
                databasesBaseURL: fixture.root,
                threads: 4,
                progress: { _, _ in }
            )
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(fixture.writer.successes.isEmpty)
    }

    @Test("cancellation between special commands writes a cancelled receipt and no prepared result")
    func cancellationBetweenSpecialCommands() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let tools = FixtureToolRunner(cancelAfterFirstRun: true)
        let installer = fixture.installer(tools: tools)

        let task = Task.detached {
            try await installer.prepareInstallation(
                database: fixture.database(recipe: .kraken2Special(type: .silva)),
                databasesBaseURL: fixture.root,
                threads: 4,
                progress: { _, _ in }
            )
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(tools.calls.count == 1)
        #expect(fixture.writer.successes.isEmpty)
        #expect(fixture.writer.failures.count == 1)
        #expect(fixture.writer.failures[0].error.provenanceExitStatus == 130)
    }

    @Test("cancellation while a recipe runner is suspended is observed and leaves no prepared result")
    func cancellationWhileRunnerIsSuspended() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let tools = FixtureToolRunner(suspendFirstRun: true)
        let installer = fixture.installer(tools: tools)
        let task = Task.detached {
            try await installer.prepareInstallation(
                database: fixture.database(recipe: .kraken2Special(type: .silva)),
                databasesBaseURL: fixture.root,
                threads: 4,
                progress: { _, _ in }
            )
        }
        while tools.calls.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(tools.observedCancellation)
        #expect(fixture.writer.successes.isEmpty)
        #expect(fixture.writer.failures.count == 1)
    }
}

private let managedBrackenRuntimePackages: [ManagedToolSourceInstallationRecord.Runtime.CondaPackage] = [
    .init(name: "cxx-compiler", version: "1.9.0", build: "h1", subdir: "osx-arm64"),
    .init(name: "llvm-openmp", version: "21.1.8", build: "h2", subdir: "osx-arm64"),
    .init(name: "python", version: "3.11.13", build: "h3", subdir: "osx-arm64"),
]

private final class Fixture: @unchecked Sendable {
    enum PayloadMutation: CaseIterable { case missingCore, emptyDistribution, missingTaxonomy, missingLibrary, symlink }
    let root: URL
    let krakenBin: URL
    let writer = FixtureProvenanceWriter()
    var messages: [String] = []
    let mutation: PayloadMutation?

    init(mutation: PayloadMutation? = nil) throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("test-metagenomics-installer-\(UUID().uuidString)", isDirectory: true)
        self.krakenBin = root.appendingPathComponent("managed-kraken/bin", isDirectory: true)
        self.mutation = mutation
        try FileManager.default.createDirectory(at: krakenBin, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func database(recipe: MetagenomicsDatabaseInstallationRecipe) -> MetagenomicsDatabaseInfo {
        MetagenomicsDatabaseInfo(
            name: "fixture", tool: "kraken2", version: "fixture-v1", sizeBytes: 1,
            catalogID: "fixture", installationRecipe: recipe, description: "fixture", recommendedRAM: 1
        )
    }

    func installer(
        tools: FixtureToolRunner,
        transfer: FixtureArchiveTransfer = FixtureArchiveTransfer(),
        fileSystem: any MetagenomicsDatabaseFileSystem = FoundationMetagenomicsDatabaseFileSystem()
    ) -> MetagenomicsDatabaseInstaller {
        tools.fixture = self
        return MetagenomicsDatabaseInstaller(toolRunner: tools, archiveTransfer: transfer, provenanceWriter: writer, fileSystem: fileSystem)
    }

    static func writeKrakenPayload(to root: URL, special: Bool = true, mutation: PayloadMutation? = nil) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["hash.k2d", "opts.k2d", "taxo.k2d", "database150mers.kmer_distrib"] {
            try Data("payload".utf8).write(to: root.appendingPathComponent(name))
        }
        guard special else { return }
        let taxonomy = root.appendingPathComponent("taxonomy", isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: taxonomy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("nodes".utf8).write(to: taxonomy.appendingPathComponent("nodes.dmp"))
        try Data("names".utf8).write(to: taxonomy.appendingPathComponent("names.dmp"))
        try Data(">seq\nACTG\n".utf8).write(to: library.appendingPathComponent("library.fna"))
        switch mutation {
        case .missingCore: try FileManager.default.removeItem(at: root.appendingPathComponent("hash.k2d"))
        case .emptyDistribution: try Data().write(to: root.appendingPathComponent("database150mers.kmer_distrib"))
        case .missingTaxonomy: try FileManager.default.removeItem(at: taxonomy.appendingPathComponent("names.dmp"))
        case .missingLibrary: try FileManager.default.removeItem(at: library.appendingPathComponent("library.fna"))
        case .symlink:
            try FileManager.default.removeItem(at: root.appendingPathComponent("hash.k2d"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("hash.k2d"), withDestinationURL: root.deletingLastPathComponent())
        case nil: break
        }
    }

    static func directoryBytes(at root: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator where !url.hasDirectoryPath {
            result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }

    static func transactionDirectories(beside final: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: final.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".install-") || $0.lastPathComponent.hasPrefix(".backup-") }
    }
}

private struct FailingCleanupFileSystem: MetagenomicsDatabaseFileSystem {
    private let base = FoundationMetagenomicsDatabaseFileSystem()
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }
    func removeItemIfPresent(at url: URL) throws {
        if url.lastPathComponent.hasPrefix(".backup-") { throw FixtureError.cleanup }
        try base.removeItemIfPresent(at: url)
    }
}

private struct FixtureToolCall: Equatable { let name: String; let arguments: [String]; let environment: String }

private final class FixtureToolRunner: MetagenomicsDatabaseToolRunning, @unchecked Sendable {
    var fixture: Fixture?
    var calls: [FixtureToolCall] = []
    let missingExecutable: String?
    var resultStatuses: [Int32]
    let cancelAfterFirstRun: Bool
    let suspendFirstRun: Bool
    var observedCancellation = false

    init(missingExecutable: String? = nil, resultStatuses: [Int32] = [], cancelAfterFirstRun: Bool = false, suspendFirstRun: Bool = false) {
        self.missingExecutable = missingExecutable
        self.resultStatuses = resultStatuses
        self.cancelAfterFirstRun = cancelAfterFirstRun
        self.suspendFirstRun = suspendFirstRun
    }

    func executableDirectory(environment: String) async throws -> URL {
        let name = environment == "kraken2" ? "kraken2-build" : "bracken-build"
        if missingExecutable == name { throw FixtureError.missing }
        return try #require(fixture).krakenBin
    }

    func toolVersion(name: String, environment: String, workingDirectory: URL) async throws -> String { "1.0" }

    func run(name: String, arguments: [String], environment: String, workingDirectory: URL, timeout: TimeInterval) async throws -> MetagenomicsDatabaseToolResult {
        calls.append(.init(name: name, arguments: arguments, environment: environment))
        let fixture = try #require(fixture)
        if suspendFirstRun, calls.count == 1 {
            do { try await Task.sleep(for: .seconds(5)) }
            catch is CancellationError { observedCancellation = true; throw CancellationError() }
        }
        if name == "bracken-build" { try Fixture.writeKrakenPayload(to: workingDirectory, mutation: fixture.mutation) }
        let status = resultStatuses.isEmpty ? 0 : resultStatuses.removeFirst()
        if cancelAfterFirstRun, calls.count == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        return .init(stdout: "", stderr: String(repeating: "e", count: 20_000), exitStatus: status, argv: ["micromamba", "run", "-n", environment, name] + arguments, runtimeIdentity: .fixture(executablePath: fixture.krakenBin.appendingPathComponent(name).path, condaEnvironment: environment), toolVersion: "1.0", startedAt: .now, completedAt: .now)
    }
}

private final class FixtureArchiveTransfer: MetagenomicsDatabaseArchiveTransferring, @unchecked Sendable {
    let archive: URL?
    let onExtract: ((URL) throws -> Void)?
    let extractionError: Error?
    let cancelDuringDownload: Bool
    let cancelDuringExtraction: Bool
    var downloaded = false
    var extracted = false
    init(archive: URL? = nil, onExtract: ((URL) throws -> Void)? = nil, extractionError: Error? = nil, cancelDuringDownload: Bool = false, cancelDuringExtraction: Bool = false) {
        self.archive = archive; self.onExtract = onExtract; self.extractionError = extractionError
        self.cancelDuringDownload = cancelDuringDownload; self.cancelDuringExtraction = cancelDuringExtraction
    }
    func extractionToolVersion() async throws -> String { "bsdtar fixture" }
    func download(from source: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        downloaded = true
        if cancelDuringDownload {
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        progress(1)
        return try #require(archive)
    }
    func extract(archive: URL, destination: URL) async throws -> MetagenomicsDatabaseToolResult {
        extracted = true
        if let extractionError { throw extractionError }
        if cancelDuringExtraction {
            withUnsafeCurrentTask { $0?.cancel() }
            return .init(stdout: "", stderr: "terminated", exitStatus: 15, argv: ["/usr/bin/tar"], runtimeIdentity: .fixture(executablePath: "/usr/bin/tar"), toolVersion: "bsdtar fixture", startedAt: .now, completedAt: .now)
        }
        try onExtract?(destination)
        return .init(stdout: "", stderr: "", exitStatus: 0, argv: ["/usr/bin/tar"], runtimeIdentity: .fixture(executablePath: "/usr/bin/tar"), toolVersion: "bsdtar fixture", startedAt: .now, completedAt: .now)
    }
}

private final class FixtureProvenanceWriter: MetagenomicsDatabaseInstallProvenanceWriting, @unchecked Sendable {
    struct Success { let attempt: MetagenomicsDatabaseInstallAttempt; let snapshot: MetagenomicsDatabasePayloadSnapshot }
    struct Failure { let attempt: MetagenomicsDatabaseInstallAttempt; let error: MetagenomicsDatabaseInstallFailure }
    var successes: [Success] = []
    var failures: [Failure] = []
    var successError: Error?
    var failureError: Error?
    var cancelCurrentTaskAfterSuccessWrite = false
    var omitSuccessReceipt = false
    func writeSuccess(_ attempt: MetagenomicsDatabaseInstallAttempt, snapshot: MetagenomicsDatabasePayloadSnapshot) throws {
        if let successError { throw successError }
        successes.append(.init(attempt: attempt, snapshot: snapshot))
        if !omitSuccessReceipt {
            try CanonicalMetagenomicsDatabaseInstallProvenanceWriter().writeSuccess(attempt, snapshot: snapshot)
        }
        if cancelCurrentTaskAfterSuccessWrite { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func writeFailure(_ attempt: MetagenomicsDatabaseInstallAttempt, error: MetagenomicsDatabaseInstallFailure, historyDirectory: URL) throws {
        if let failureError { throw failureError }
        failures.append(.init(attempt: attempt, error: error))
    }
}

private enum FixtureError: Error, LocalizedError {
    case missing, provenance, receipt, transfer, cleanup
    var errorDescription: String? { self == .receipt ? "receipt fixture failure" : nil }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
