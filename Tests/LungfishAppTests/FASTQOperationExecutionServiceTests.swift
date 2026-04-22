import Darwin
import XCTest
@testable import LungfishApp
@testable import LungfishIO
import LungfishWorkflow

final class FASTQOperationExecutionServiceTests: XCTestCase {
    func testExecuteDerivativeDiscoversStagedFASTQFileAndImportsIt() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("input.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: inputURL, readCount: 3, readLength: 18)

        let resolver = SpyInputResolver(
            resolvedRequest: .derivative(
                request: .lengthFilter(min: 10, max: 40),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )
        let runner = SpyCommandRunner { invocation, _ in
            guard
                let outputIndex = invocation.arguments.firstIndex(of: "-o"),
                invocation.arguments.indices.contains(outputIndex + 1)
            else {
                XCTFail("Expected -o output path in CLI invocation")
                throw NSError(
                    domain: "FASTQOperationExecutionServiceTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing -o output path in CLI invocation"]
                )
            }

            let outputURL = URL(fileURLWithPath: invocation.arguments[outputIndex + 1])
            XCTAssertTrue(FASTQBundle.isFASTQFileURL(outputURL), "Expected a staged FASTQ file output path")
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: outputURL, readCount: 2, readLength: 16)
            return FASTQCLIExecutionResult(outputURLs: [])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        let importedBundle = tempDir.appendingPathComponent("filtered.\(FASTQBundle.directoryExtension)")
        importer.resultURLs = [importedBundle]

        let result = try await service.execute(
            request: .derivative(
                request: .lengthFilter(min: 10, max: 40),
                inputURLs: [inputURL],
                outputMode: .perInput
            ),
            workingDirectory: tempDir
        )

        XCTAssertEqual(result.importedURLs, [importedBundle])
        XCTAssertEqual(importer.calls.count, 1)
        XCTAssertEqual(importer.calls[0].count, 1)
        XCTAssertTrue(FASTQBundle.isFASTQFileURL(importer.calls[0][0]))
    }

    func testExecuteDerivativeMaterializesMultiFileBundleIntoSingleCLIInput() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent(
            "multi.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        let chunksDir = bundleURL.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunksDir, withIntermediateDirectories: true)

        let chunkA = chunksDir.appendingPathComponent("chunk-a.fastq")
        let chunkB = chunksDir.appendingPathComponent("chunk-b.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: chunkA, readCount: 2, readLength: 12, idPrefix: "chunkA")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: chunkB, readCount: 1, readLength: 12, idPrefix: "chunkB")

        try """
        {
          "version": 1,
          "files": [
            {
              "filename": "chunks/chunk-a.fastq",
              "originalPath": "/tmp/chunk-a.fastq",
              "sizeBytes": 1,
              "isSymlink": false
            },
            {
              "filename": "chunks/chunk-b.fastq",
              "originalPath": "/tmp/chunk-b.fastq",
              "sizeBytes": 1,
              "isSymlink": false
            }
          ]
        }
        """.write(
            to: bundleURL.appendingPathComponent("source-files.json"),
            atomically: true,
            encoding: .utf8
        )

        let runner = SpyCommandRunner { invocation, _ in
            XCTAssertEqual(invocation.arguments.first, "subsample")
            let resolvedInputPath = try XCTUnwrap(invocation.arguments[safe: 1])
            XCTAssertNotEqual(resolvedInputPath, chunkA.path)
            XCTAssertNotEqual(resolvedInputPath, chunkB.path)

            let resolvedInputURL = URL(fileURLWithPath: resolvedInputPath)
            let resolvedContents = try String(contentsOf: resolvedInputURL, encoding: .utf8)
            XCTAssertTrue(resolvedContents.contains("@chunkA1"))
            XCTAssertTrue(resolvedContents.contains("@chunkB1"))

            guard
                let outputIndex = invocation.arguments.firstIndex(of: "-o"),
                let outputPath = invocation.arguments[safe: outputIndex + 1]
            else {
                XCTFail("Expected -o output path in CLI invocation")
                throw NSError(
                    domain: "FASTQOperationExecutionServiceTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Missing -o output path in multi-file invocation"]
                )
            }

            let outputURL = URL(fileURLWithPath: outputPath)
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: outputURL, readCount: 2, readLength: 12, idPrefix: "output")
            return FASTQCLIExecutionResult(outputURLs: [])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            commandRunner: runner,
            directImporter: importer
        )

        _ = try await service.execute(
            request: .derivative(
                request: .subsampleCount(2),
                inputURLs: [bundleURL],
                outputMode: .perInput
            ),
            workingDirectory: tempDir
        )

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(importer.calls.count, 1)
    }

    func testExecuteMaterializesVirtualBundleInputBeforeInvocation() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent(
            "virtual.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let materializedURL = tempDir.appendingPathComponent("materialized.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: materializedURL, readCount: 2, readLength: 12)

        let resolver = SpyInputResolver(
            resolvedRequest: .derivative(
                request: .subsampleCount(5),
                inputURLs: [materializedURL],
                outputMode: .perInput
            )
        )
        let runner = SpyCommandRunner()
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        _ = try await service.execute(
            request: .derivative(
                request: .subsampleCount(5),
                inputURLs: [bundleURL],
                outputMode: .perInput
            ),
            workingDirectory: tempDir
        )

        XCTAssertEqual(resolver.requests, [
            .derivative(
                request: .subsampleCount(5),
                inputURLs: [bundleURL],
                outputMode: .perInput
            )
        ])
        XCTAssertEqual(runner.invocations.map { $0.arguments.first }, ["subsample"])
        XCTAssertTrue(runner.invocations[0].arguments.contains(materializedURL.path))
    }

    func testExecuteForwardsResolvedInputsIntoBuiltInvocation() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let resolvedR1 = tempDir.appendingPathComponent("resolved-R1.fastq")
        let resolvedR2 = tempDir.appendingPathComponent("resolved-R2.fastq")
        let referenceURL = tempDir.appendingPathComponent("reference.fasta")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: resolvedR1, readCount: 1, readLength: 10)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: resolvedR2, readCount: 1, readLength: 10)
        try ">ref\nAACCGGTT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let resolver = SpyInputResolver(
            resolvedRequest: .map(
                inputURLs: [resolvedR1, resolvedR2],
                referenceURL: referenceURL,
                outputMode: .groupedResult
            )
        )
        let runner = SpyCommandRunner()
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        _ = try await service.execute(
            request: .map(
                inputURLs: [
                    tempDir.appendingPathComponent("raw-R1.\(FASTQBundle.directoryExtension)"),
                    tempDir.appendingPathComponent("raw-R2.\(FASTQBundle.directoryExtension)")
                ],
                referenceURL: referenceURL,
                outputMode: .groupedResult
            ),
            workingDirectory: tempDir
        )

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations[0].subcommand, "map")
        XCTAssertEqual(Array(runner.invocations[0].arguments[0..<2]), [
            resolvedR1.path,
            resolvedR2.path,
        ])
        XCTAssertTrue(runner.invocations[0].arguments.contains("--paired"))
    }

    func testExecuteGroupedResultWritesBatchManifestAndReturnsGroupedContainer() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let groupedOutputDir = tempDir.appendingPathComponent("grouped-output", isDirectory: true)
        try FileManager.default.createDirectory(at: groupedOutputDir, withIntermediateDirectories: true)

        let inputA = tempDir.appendingPathComponent("input-a.\(FASTQBundle.directoryExtension)", isDirectory: true)
        let inputB = tempDir.appendingPathComponent("input-b.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: inputA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputB, withIntermediateDirectories: true)

        let resolver = SpyInputResolver(
            resolvedRequest: .derivative(
                request: .lengthFilter(min: 100, max: 500),
                inputURLs: [inputA, inputB],
                outputMode: .groupedResult
            )
        )
        let runner = SpyCommandRunner { _, outputDirectory in
            let bundleA = outputDirectory.appendingPathComponent(
                "filtered-a.\(FASTQBundle.directoryExtension)",
                isDirectory: true
            )
            let bundleB = outputDirectory.appendingPathComponent(
                "filtered-b.\(FASTQBundle.directoryExtension)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: bundleA, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundleB, withIntermediateDirectories: true)
            return FASTQCLIExecutionResult(outputURLs: [bundleA, bundleB])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        let result = try await service.execute(
            request: .derivative(
                request: .lengthFilter(min: 100, max: 500),
                inputURLs: [inputA, inputB],
                outputMode: .groupedResult
            ),
            workingDirectory: groupedOutputDir
        )

        let groupedURL = try XCTUnwrap(result.groupedContainerURL)
        XCTAssertEqual(result.importedURLs, [groupedURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: groupedURL.appendingPathComponent(FASTQBatchManifest.filename).path))
        XCTAssertTrue(importer.calls.isEmpty, "Grouped results should bypass direct import")

        let manifest = try XCTUnwrap(FASTQBatchManifest.load(from: groupedURL))
        XCTAssertEqual(manifest.operations.count, 1)
        let record = try XCTUnwrap(manifest.operations.first)
        XCTAssertEqual(record.outputBundlePaths.sorted(), [
            "filtered-a.\(FASTQBundle.directoryExtension)",
            "filtered-b.\(FASTQBundle.directoryExtension)",
        ])
        XCTAssertEqual(record.inputBundlePaths.sorted(), [
            "../input-a.\(FASTQBundle.directoryExtension)",
            "../input-b.\(FASTQBundle.directoryExtension)",
        ])
    }

    func testBundleImporterWrapsRawFASTQOutputsIntoBundles() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecImport")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = try FASTQOperationTestHelper.makeBundle(named: "source", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(
            to: sourceBundle.fastqURL,
            readCount: 4,
            readLength: 20
        )

        let stagingDir = tempDir.appendingPathComponent("staging", isDirectory: true)
        let destinationDir = tempDir.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let stagedFASTQ = stagingDir.appendingPathComponent("filtered.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: stagedFASTQ, readCount: 2, readLength: 14)

        let importer = BundleFASTQOperationImporter(destinationDirectory: destinationDir)
        let request = FASTQOperationLaunchRequest.derivative(
            request: .lengthFilter(min: 10, max: 40),
            inputURLs: [sourceBundle.bundleURL],
            outputMode: .perInput
        )

        let imported = try await importer.importOutputs(
            at: [stagedFASTQ],
            forResolvedRequest: request,
            originalRequest: request,
            outputDirectory: stagingDir
        )

        XCTAssertEqual(imported.count, 1)
        let bundleURL = try XCTUnwrap(imported.first)
        XCTAssertTrue(FASTQBundle.isBundleURL(bundleURL))
        let bundledFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundledFASTQ.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFASTQ.path))
    }

    func testBundleImporterRefreshesDerivedManifestStatisticsFromQCSummary() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecImport")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = try FASTQOperationTestHelper.makeBundle(named: "root", in: tempDir)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: root.fastqURL, readCount: 10, readLength: 30)

        let derivedBundle = tempDir.appendingPathComponent(
            "subset.\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: derivedBundle, withIntermediateDirectories: true)
        let initialManifest = FASTQDerivedBundleManifest(
            name: "subset",
            parentBundleRelativePath: "../\(root.bundleURL.lastPathComponent)",
            rootBundleRelativePath: "../\(root.bundleURL.lastPathComponent)",
            rootFASTQFilename: root.fastqURL.lastPathComponent,
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .subsampleCount, count: 2),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 30),
            pairingMode: nil
        )
        try FASTQBundle.saveDerivedManifest(initialManifest, in: derivedBundle)

        let reportURL = tempDir.appendingPathComponent("qc-summary.json")
        let report = TestFastqQCSummaryReport(
            inputs: [
                .init(
                    input: derivedBundle.path,
                    statistics: FASTQDatasetStatistics(
                        readCount: 4,
                        baseCount: 120,
                        meanReadLength: 30,
                        minReadLength: 20,
                        maxReadLength: 40,
                        medianReadLength: 30,
                        n50ReadLength: 30,
                        meanQuality: 35,
                        q20Percentage: 100,
                        q30Percentage: 95,
                        gcContent: 0.5,
                        readLengthHistogram: [30: 4],
                        qualityScoreHistogram: [:],
                        perPositionQuality: []
                    )
                )
            ]
        )
        let reportData = try JSONEncoder().encode(report)
        try reportData.write(to: reportURL, options: .atomic)

        let importer = BundleFASTQOperationImporter(destinationDirectory: tempDir)
        let request = FASTQOperationLaunchRequest.refreshQCSummary(inputURLs: [derivedBundle])

        let imported = try await importer.importOutputs(
            at: [reportURL],
            forResolvedRequest: request,
            originalRequest: request,
            outputDirectory: tempDir
        )

        XCTAssertEqual(imported, [derivedBundle])
        let updatedManifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: derivedBundle))
        XCTAssertEqual(updatedManifest.cachedStatistics.readCount, 4)
        XCTAssertEqual(updatedManifest.cachedStatistics.baseCount, 120)
    }

    func testMapLaunchBuildsTopLevelMapInvocation() throws {
        let request = FASTQOperationLaunchRequest.map(
            inputURLs: [
                URL(fileURLWithPath: "/tmp/R1.fastq"),
                URL(fileURLWithPath: "/tmp/R2.fastq"),
            ],
            referenceURL: URL(fileURLWithPath: "/tmp/ref.fasta"),
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(invocation.subcommand, "map")
        XCTAssertEqual(invocation.arguments, [
            "/tmp/R1.fastq",
            "/tmp/R2.fastq",
            "--reference",
            "/tmp/ref.fasta",
            "--paired",
        ])
    }

    func testAssemblyLaunchBuildsAssemblerAwareInvocation() throws {
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.fastq.gz")],
                projectName: "Demo",
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                threads: 8,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(
            invocation,
            CLIInvocation(
                subcommand: "assemble",
                arguments: [
                    "/tmp/sample.fastq.gz",
                    "--assembler", "spades",
                    "--read-type", "illumina-short-reads",
                    "--project-name", "Demo",
                    "--threads", "8",
                    "--output", "<derived>",
                ]
            )
        )
    }

    func testAssemblyLaunchPreservesExplicitPairedTopology() throws {
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/sample_R1.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/sample_R2.fastq.gz"),
                ],
                projectName: "Demo",
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                pairedEnd: true,
                threads: 8,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(
            invocation.arguments,
            [
                "/tmp/sample_R1.fastq.gz",
                "/tmp/sample_R2.fastq.gz",
                "--paired",
                "--assembler", "spades",
                "--read-type", "illumina-short-reads",
                "--project-name", "Demo",
                "--threads", "8",
                "--output", "<derived>",
            ]
        )
    }

    func testAssemblyLaunchDoesNotInferPairedFromTwoInputFilesAlone() throws {
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/chunk-a.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/chunk-b.fastq.gz"),
                ],
                projectName: "Demo",
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                pairedEnd: false,
                threads: 8,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertFalse(invocation.arguments.contains("--paired"))
    }

    func testAssemblyLaunchBuildsGenericManagedInvocationForMegahit() throws {
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .megahit,
                readType: .illuminaShortReads,
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.fastq.gz")],
                projectName: "Demo",
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                threads: 8,
                memoryGB: 24,
                minContigLength: 1000,
                selectedProfileID: "meta-sensitive",
                extraArguments: ["--k-min", "21"]
            ),
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        #if os(macOS) && arch(arm64)
        let expectedThreads = "2"
        #else
        let expectedThreads = "8"
        #endif

        XCTAssertEqual(
            invocation.arguments,
            [
                "/tmp/sample.fastq.gz",
                "--assembler", "megahit",
                "--read-type", "illumina-short-reads",
                "--project-name", "Demo",
                "--threads", expectedThreads,
                "--output", "<derived>",
                "--memory-gb", "24",
                "--min-contig-length", "1000",
                "--profile", "meta-sensitive",
                "--extra-arg", "--k-min",
                "--extra-arg", "21",
            ]
        )
    }

    func testAssemblyLaunchBuildsHifiasmProfileInvocationWithoutCuratedFlagDuplication() throws {
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .hifiasm,
                readType: .pacBioHiFi,
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.fastq.gz")],
                projectName: "Demo",
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                threads: 8,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: "haploid-viral",
                extraArguments: ["--primary"]
            ),
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(
            invocation.arguments,
            [
                "/tmp/sample.fastq.gz",
                "--assembler", "hifiasm",
                "--read-type", "pacbio-hifi",
                "--project-name", "Demo",
                "--threads", "8",
                "--output", "<derived>",
                "--profile", "haploid-viral",
                "--extra-arg", "--primary",
            ]
        )
        XCTAssertFalse(invocation.arguments.contains("--n-hap"))
        XCTAssertFalse(invocation.arguments.contains("-l0"))
        XCTAssertFalse(invocation.arguments.contains("-f0"))
    }

    func testAssemblyLaunchNormalizesZeroMinContigLengthToOne() throws {
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .skesa,
                readType: .illuminaShortReads,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/sample_R1.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/sample_R2.fastq.gz"),
                ],
                projectName: "Demo",
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                pairedEnd: true,
                threads: 8,
                memoryGB: nil,
                minContigLength: 0,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .groupedResult
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        let minContigIndex = try XCTUnwrap(invocation.arguments.firstIndex(of: "--min-contig-length"))
        XCTAssertEqual(invocation.arguments[minContigIndex + 1], "1")
    }

    func testExecuteKeepsPairedAssemblyAsSinglePerInputPlan() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let assemblyRequest = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/sample_R1.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/sample_R2.fastq.gz"),
                ],
                projectName: "Demo",
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                pairedEnd: true,
                threads: 8,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .perInput
        )

        let resolver = SpyInputResolver(resolvedRequest: assemblyRequest)
        let runner = SpyCommandRunner { invocation, outputDirectory in
            let reportedOutput = outputDirectory.appendingPathComponent("assembly-result")
            try FileManager.default.createDirectory(at: reportedOutput, withIntermediateDirectories: true)
            return FASTQCLIExecutionResult(outputURLs: [reportedOutput])
        }
        let importer = SpyDirectImporter()
        importer.resultURLs = [tempDir.appendingPathComponent("imported-result")]
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        _ = try await service.execute(
            request: assemblyRequest,
            workingDirectory: tempDir
        )

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(
            runner.invocations[0].arguments.prefix(3),
            [
                "/tmp/sample_R1.fastq.gz",
                "/tmp/sample_R2.fastq.gz",
                "--paired",
            ]
        )
    }

    func testExecuteDiscoversAssemblyResultDirectoryWhenAssemblerWritesSidecar() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputDirectory = tempDir.appendingPathComponent("analysis-output", isDirectory: true)
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .megahit,
                readType: .illuminaShortReads,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/sample_R1.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/sample_R2.fastq.gz"),
                ],
                projectName: "Demo",
                outputDirectory: outputDirectory,
                pairedEnd: true,
                threads: 2,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .perInput
        )

        let resolver = SpyInputResolver(resolvedRequest: request)
        let runner = SpyCommandRunner { _, workingDirectory in
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            let contigsURL = workingDirectory.appendingPathComponent("contigs.fasta")
            try ">contig1\nAACCGGTT\n".write(to: contigsURL, atomically: true, encoding: .utf8)
            let result = AssemblyResult(
                tool: .megahit,
                readType: .illuminaShortReads,
                contigsPath: contigsURL,
                graphPath: nil,
                logPath: nil,
                assemblerVersion: "test",
                commandLine: "megahit",
                outputDirectory: workingDirectory,
                statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
                wallTimeSeconds: 1
            )
            try result.save(to: workingDirectory)
            return FASTQCLIExecutionResult(outputURLs: [])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        let result = try await service.execute(
            request: request,
            workingDirectory: outputDirectory
        )

        XCTAssertEqual(result.importedURLs, [outputDirectory])
        XCTAssertEqual(importer.calls, [[outputDirectory]])
    }

    func testExecuteDiscoversAssemblyResultFromInvocationOutputDirectory() async throws {
        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputDirectory = tempDir.appendingPathComponent("analysis-output", isDirectory: true)
        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .megahit,
                readType: .illuminaShortReads,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/sample_R1.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/sample_R2.fastq.gz"),
                ],
                projectName: "Demo",
                outputDirectory: outputDirectory,
                pairedEnd: true,
                threads: 2,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .perInput
        )

        let resolver = SpyInputResolver(resolvedRequest: request)
        let runner = SpyCommandRunner { invocation, workingDirectory in
            let outputFlagIndex = try XCTUnwrap(invocation.arguments.firstIndex(of: "--output"))
            let resultDirectory = URL(
                fileURLWithPath: invocation.arguments[outputFlagIndex + 1],
                isDirectory: true
            )

            XCTAssertEqual(workingDirectory.standardizedFileURL, outputDirectory.standardizedFileURL)

            try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
            let contigsURL = resultDirectory.appendingPathComponent("contigs.fasta")
            try ">contig1\nAACCGGTT\n".write(to: contigsURL, atomically: true, encoding: .utf8)
            let result = AssemblyResult(
                tool: .megahit,
                readType: .illuminaShortReads,
                contigsPath: contigsURL,
                graphPath: nil,
                logPath: nil,
                assemblerVersion: "test",
                commandLine: "megahit",
                outputDirectory: resultDirectory,
                statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
                wallTimeSeconds: 1
            )
            try result.save(to: resultDirectory)
            return FASTQCLIExecutionResult(outputURLs: [])
        }
        let importer = SpyDirectImporter()
        let service = FASTQOperationExecutionService(
            inputResolver: resolver,
            commandRunner: runner,
            directImporter: importer
        )

        let result = try await service.execute(
            request: request,
            workingDirectory: outputDirectory
        )

        XCTAssertEqual(result.importedURLs, [outputDirectory])
        XCTAssertEqual(importer.calls, [[outputDirectory]])
    }

    func testExecuteWithLiveRunnerDrainsVerboseAssemblyProcessOutput() async throws {
        actor ResultBox {
            var result: FASTQOperationExecutionResult?
            var error: Error?

            func store(result: FASTQOperationExecutionResult) {
                self.result = result
            }

            func store(error: Error) {
                self.error = error
            }
        }

        let tempDir = try FASTQOperationTestHelper.makeTempDir(prefix: "FASTQExecService")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputDirectory = tempDir.appendingPathComponent("analysis-output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let fakeCLI = tempDir.appendingPathComponent("fake-lungfish-cli.sh")
        let script = """
        #!/bin/bash
        set -euo pipefail
        head -c 1048576 /dev/zero | tr '\\0' 'x'
        head -c 1048576 /dev/zero | tr '\\0' 'y' >&2
        cat > contigs.fasta <<'EOF'
        >contig1
        AACCGGTT
        EOF
        output_dir="$PWD"
        cat > assembly-result.json <<EOF
        {
          "schemaVersion": 2,
          "tool": "megahit",
          "readType": "illuminaShortReads",
          "contigsPath": "contigs.fasta",
          "graphPath": null,
          "logPath": null,
          "scaffoldsPath": null,
          "paramsPath": null,
          "assemblerVersion": "test",
          "commandLine": "fake-lungfish-cli",
          "outputDirectory": "$output_dir",
          "statistics": {
            "contigCount": 1,
            "gcFraction": 0.5,
            "l50": 1,
            "largestContigBP": 8,
            "meanLengthBP": 8,
            "n50": 8,
            "n90": 8,
            "smallestContigBP": 8,
            "totalLengthBP": 8
          },
          "wallTimeSeconds": 1
        }
        EOF
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        XCTAssertEqual(setenv("LUNGFISH_CLI_PATH", fakeCLI.path, 1), 0)
        defer { unsetenv("LUNGFISH_CLI_PATH") }

        let request = FASTQOperationLaunchRequest.assemble(
            request: AssemblyRunRequest(
                tool: .megahit,
                readType: .illuminaShortReads,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/sample_R1.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/sample_R2.fastq.gz"),
                ],
                projectName: "VerboseRunner",
                outputDirectory: outputDirectory,
                pairedEnd: true,
                threads: 2,
                memoryGB: nil,
                minContigLength: nil,
                selectedProfileID: nil,
                extraArguments: []
            ),
            outputMode: .perInput
        )

        let service = FASTQOperationExecutionService(
            inputResolver: SpyInputResolver(resolvedRequest: request),
            directImporter: SpyDirectImporter()
        )
        let resultBox = ResultBox()
        let finished = expectation(description: "live runner completed")

        Task {
            do {
                let result = try await service.execute(
                    request: request,
                    workingDirectory: outputDirectory
                )
                await resultBox.store(result: result)
            } catch {
                await resultBox.store(error: error)
            }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 5.0)

        let error = await resultBox.error
        XCTAssertNil(error)
        let result = await resultBox.result
        XCTAssertEqual(result?.importedURLs, [outputDirectory])
    }

    func testRefreshQCSummaryLaunchBuildsFastqQCSummaryInvocation() throws {
        let request = FASTQOperationLaunchRequest.refreshQCSummary(
            inputURLs: [
                URL(fileURLWithPath: "/tmp/input-1.fastq"),
                URL(fileURLWithPath: "/tmp/input-2.fastq"),
            ]
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(invocation.arguments, [
            "qc-summary",
            "/tmp/input-1.fastq",
            "/tmp/input-2.fastq",
            "--output",
            "<derived>",
        ])
    }

    @MainActor
    func testPrepareForRunSynthesizesConcreteDerivativeRequest() throws {
        let state = FASTQOperationDialogState(
            initialCategory: .readProcessing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/input.fastq")],
            projectURL: nil
        )
        state.selectTool(.orientReads)
        state.setAuxiliaryInput(URL(fileURLWithPath: "/tmp/reference.fasta"), for: .referenceSequence)

        state.prepareForRun()

        guard case .derivative(let request, let inputURLs, let outputMode)? = state.pendingLaunchRequest else {
            return XCTFail("Expected concrete derivative launch request")
        }

        XCTAssertEqual(inputURLs, [URL(fileURLWithPath: "/tmp/input.fastq")])
        XCTAssertEqual(outputMode, .perInput)
        XCTAssertEqual(request, .orient(
            referenceURL: URL(fileURLWithPath: "/tmp/reference.fasta"),
            wordLength: 12,
            dbMask: "dust",
            saveUnoriented: false
        ))
    }

    func testDerivativeLaunchBuildsConcreteFastqInvocation() throws {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .subsampleProportion(0.25),
            inputURLs: [URL(fileURLWithPath: "/tmp/input.fastq")],
            outputMode: .perInput
        )

        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)

        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(invocation.arguments, [
            "subsample",
            "/tmp/input.fastq",
            "--proportion",
            "0.25",
            "-o",
            "<derived>",
        ])
    }

    func testDerivativeLaunchRejectsAdapterRequestsThatNeedMultipleAdapterShapes() {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .adapterTrim(
                mode: .specified,
                sequence: "AGATCGGAAGAGC",
                sequenceR2: "GCTCTTCCGATCT",
                fastaFilename: nil
            ),
            inputURLs: [URL(fileURLWithPath: "/tmp/input.fastq")],
            outputMode: .perInput
        )

        XCTAssertThrowsError(try FASTQOperationExecutionService().buildInvocation(for: request)) { error in
            guard let execError = error as? FASTQOperationExecutionError else {
                return XCTFail("Expected FASTQOperationExecutionError")
            }
            XCTAssertTrue(execError.errorDescription?.contains("sequenceR2") == true)
        }
    }

    func testDerivativeLaunchRejectsPrimerRequestsOutsideTheCliSubset() {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .primerRemoval(
                configuration: FASTQPrimerTrimConfiguration(
                    source: .literal,
                    readMode: .paired,
                    mode: .linked,
                    forwardSequence: "AGATCGGAAGAGC",
                    reverseSequence: "GCTCTTCCGATCT",
                    tool: .cutadapt
                )
            ),
            inputURLs: [URL(fileURLWithPath: "/tmp/input.fastq")],
            outputMode: .perInput
        )

        XCTAssertThrowsError(try FASTQOperationExecutionService().buildInvocation(for: request)) { error in
            guard let execError = error as? FASTQOperationExecutionError else {
                return XCTFail("Expected FASTQOperationExecutionError")
            }
            XCTAssertTrue(execError.errorDescription?.contains("bbduk") == true)
        }
    }

    func testDerivativeLaunchRejectsDemultiplexRequestsWithSampleAssignments() {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .demultiplex(
                kitID: "test-kit",
                customCSVPath: nil,
                location: "bothends",
                symmetryMode: .symmetric,
                maxDistanceFrom5Prime: 0,
                maxDistanceFrom3Prime: 0,
                errorRate: 0.15,
                trimBarcodes: true,
                sampleAssignments: [
                    FASTQSampleBarcodeAssignment(sampleID: "sample-1", forwardBarcodeID: "BC01")
                ],
                kitOverride: nil
            ),
            inputURLs: [URL(fileURLWithPath: "/tmp/input.fastq")],
            outputMode: .fixedBatch
        )

        XCTAssertThrowsError(try FASTQOperationExecutionService().buildInvocation(for: request)) { error in
            XCTAssertTrue(error.localizedDescription.contains("demultiplex"))
            XCTAssertTrue(error.localizedDescription.contains("sampleAssignments"))
        }
    }

    func testDerivativeLaunchRejectsOrientRequestsThatAskToSaveUnorientedReads() {
        let request = FASTQOperationLaunchRequest.derivative(
            request: .orient(
                referenceURL: URL(fileURLWithPath: "/tmp/reference.fasta"),
                wordLength: 12,
                dbMask: "dust",
                saveUnoriented: true
            ),
            inputURLs: [URL(fileURLWithPath: "/tmp/input.fastq")],
            outputMode: .perInput
        )

        XCTAssertThrowsError(try FASTQOperationExecutionService().buildInvocation(for: request)) { error in
            XCTAssertTrue(error.localizedDescription.contains("orient"))
            XCTAssertTrue(error.localizedDescription.contains("saveUnoriented"))
        }
    }

    func testClassificationLaunchesMapToTopLevelCommands() throws {
        let baseInput = [URL(fileURLWithPath: "/tmp/input.fastq")]

        let kraken2 = try FASTQOperationExecutionService().buildInvocation(
            for: .classify(tool: .kraken2, inputURLs: baseInput, databaseName: "kraken-db")
        )
        XCTAssertEqual(kraken2.subcommand, "classify")

        let esviritu = try FASTQOperationExecutionService().buildInvocation(
            for: .classify(tool: .esViritu, inputURLs: baseInput, databaseName: "esv-db")
        )
        XCTAssertEqual(esviritu.subcommand, "esviritu")

        let taxtriage = try FASTQOperationExecutionService().buildInvocation(
            for: .classify(tool: .taxTriage, inputURLs: baseInput, databaseName: "tax-db")
        )
        XCTAssertEqual(taxtriage.subcommand, "taxtriage")
    }
}

private struct TestFastqQCSummaryReport: Codable {
    let inputs: [Entry]

    struct Entry: Codable {
        let input: String
        let statistics: FASTQDatasetStatistics
    }
}

private final class SpyInputResolver: @unchecked Sendable, FASTQOperationInputResolving {
    let resolvedRequest: FASTQOperationLaunchRequest
    private(set) var requests: [FASTQOperationLaunchRequest] = []

    init(resolvedRequest: FASTQOperationLaunchRequest) {
        self.resolvedRequest = resolvedRequest
    }

    func resolve(
        request: FASTQOperationLaunchRequest,
        tempDirectory: URL
    ) async throws -> FASTQOperationLaunchRequest {
        _ = tempDirectory
        requests.append(request)
        return resolvedRequest
    }
}

private final class SpyDirectImporter: @unchecked Sendable, FASTQOperationDirectImporting {
    private(set) var calls: [[URL]] = []
    var resultURLs: [URL] = []

    func importOutputs(
        at outputURLs: [URL],
        forResolvedRequest request: FASTQOperationLaunchRequest,
        originalRequest: FASTQOperationLaunchRequest,
        outputDirectory: URL
    ) async throws -> [URL] {
        _ = request
        _ = originalRequest
        _ = outputDirectory
        calls.append(outputURLs)
        return resultURLs.isEmpty ? outputURLs : resultURLs
    }
}

private final class SpyCommandRunner: @unchecked Sendable, FASTQOperationCommandRunning {
    private(set) var invocations: [CLIInvocation] = []
    private let handler: @Sendable (CLIInvocation, URL) throws -> FASTQCLIExecutionResult

    init(
        handler: @escaping @Sendable (CLIInvocation, URL) throws -> FASTQCLIExecutionResult = { _, _ in
            FASTQCLIExecutionResult(outputURLs: [])
        }
    ) {
        self.handler = handler
    }

    func run(invocation: CLIInvocation, outputDirectory: URL) async throws -> FASTQCLIExecutionResult {
        invocations.append(invocation)
        return try handler(invocation, outputDirectory)
    }
}
