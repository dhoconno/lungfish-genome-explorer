import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

final class FASTQProjectSimulationTests: XCTestCase {
    private func makeProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQProjectSimulation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFASTQBundle(
        named name: String,
        in directory: URL,
        fastqFilename: String = "reads.fastq"
    ) throws -> (bundleURL: URL, fastqURL: URL) {
        let bundleURL = directory.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return (bundleURL, bundleURL.appendingPathComponent(fastqFilename))
    }

    private func writeFASTQ(
        records: [(id: String, description: String?, sequence: String)],
        to url: URL
    ) throws {
        let lines = records.flatMap { record -> [String] in
            let header = record.description.map { "@\(record.id) \($0)" } ?? "@\(record.id)"
            return [
                header,
                record.sequence,
                "+",
                String(repeating: "I", count: record.sequence.count),
            ]
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeFASTA(records: [(id: String, description: String?, sequence: String)], to url: URL) throws {
        let content = records.map { record in
            let header = record.description.map { ">\(record.id) \($0)" } ?? ">\(record.id)"
            return "\(header)\n\(record.sequence)"
        }.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func loadFASTQRecords(from url: URL) async throws -> [FASTQRecord] {
        let reader = FASTQReader(validateSequence: false)
        var records: [FASTQRecord] = []
        for try await record in reader.records(from: url) {
            records.append(record)
        }
        return records
    }

    private func exportRecords(
        service: FASTQDerivativeService,
        from bundleURL: URL,
        in tempDir: URL,
        named name: String
    ) async throws -> [FASTQRecord] {
        let outputURL = tempDir.appendingPathComponent(name)
        try await service.exportMaterializedFASTQ(fromDerivedBundle: bundleURL, to: outputURL)
        return try await loadFASTQRecords(from: outputURL)
    }

    func testSimulatedProjectImportsReferenceBundle() throws {
        let projectURL = try makeProject()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let sourceFASTA = projectURL.appendingPathComponent("mhc-reference.fsa")
        try writeFASTA(
            records: [
                (id: "ref1", description: "synthetic", sequence: "AACCGGTTAACCGGTTAACCGGTT"),
            ],
            to: sourceFASTA
        )

        let bundleURL = try ReferenceSequenceFolder.importReference(from: sourceFASTA, into: projectURL, displayName: "Synthetic Reference")
        XCTAssertEqual(bundleURL.pathExtension, "lungfishref")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))

        let listed = ReferenceSequenceFolder.listReferences(in: projectURL)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.manifest.name, "Synthetic Reference")

        let fastaURL = try XCTUnwrap(ReferenceSequenceFolder.fastaURL(in: bundleURL))
        XCTAssertEqual(fastaURL.lastPathComponent, "sequence.fasta")
        XCTAssertEqual(try String(contentsOf: fastaURL, encoding: .utf8), try String(contentsOf: sourceFASTA, encoding: .utf8))
    }

    func testSimulatedProjectVirtualOperationsCreateConsistentChildBundles() async throws {
        let projectURL = try makeProject()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let source = try makeFASTQBundle(named: "synthetic", in: projectURL)
        try writeFASTQ(
            records: [
                (id: "alpha", description: "sample=alpha motif=keep", sequence: "AACCGGTTAACC"),
                (id: "beta", description: "sample=beta motif=match", sequence: "TTTGGGCCAA"),
                (id: "gamma", description: "sample=beta motif=match", sequence: "TTTGGGCCAA"),
            ],
            to: source.fastqURL
        )

        let service = FASTQDerivativeService()

        let trimBundle = try await service.createDerivative(
            from: source.bundleURL,
            request: .fixedTrim(from5Prime: 2, from3Prime: 1)
        )
        let trimManifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: trimBundle))
        if case .trim(let filename) = trimManifest.payload {
            XCTAssertEqual(filename, FASTQBundle.trimPositionFilename)
        } else {
            XCTFail("Expected trim payload")
        }
        XCTAssertEqual(trimManifest.parentBundleRelativePath, "../..")
        XCTAssertEqual(trimManifest.rootBundleRelativePath, "../..")

        let filteredBundle = try await service.createDerivative(
            from: trimBundle,
            request: .lengthFilter(min: 8, max: 9)
        )
        let filteredPreview = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: filteredBundle))
        XCTAssertEqual(filteredPreview.lastPathComponent, "preview.fastq")
        let filteredManifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: filteredBundle))
        XCTAssertEqual(filteredManifest.cachedStatistics.readCount, 1)
        XCTAssertEqual(filteredManifest.cachedStatistics.readLengthHistogram, [9: 1])

        let filteredRecords = try await exportRecords(
            service: service,
            from: filteredBundle,
            in: projectURL,
            named: "filtered.fastq"
        )
        XCTAssertEqual(filteredRecords.map(\.identifier), ["alpha"])
        XCTAssertEqual(filteredRecords.first?.description, "sample=alpha motif=keep")
        XCTAssertEqual(filteredRecords.first?.sequence, "CCGGTTAAC")

        let searchBundle = try await service.createDerivative(
            from: source.bundleURL,
            request: .searchText(query: "alpha", field: .id, regex: false)
        )
        let searchRecords = try await exportRecords(
            service: service,
            from: searchBundle,
            in: projectURL,
            named: "search.fastq"
        )
        XCTAssertEqual(searchRecords.map(\.identifier), ["alpha"])
        XCTAssertEqual(searchRecords.first?.description, "sample=alpha motif=keep")

        let motifBundle = try await service.createDerivative(
            from: source.bundleURL,
            request: .searchMotif(pattern: "GGG", regex: false)
        )
        let motifRecords = try await exportRecords(
            service: service,
            from: motifBundle,
            in: projectURL,
            named: "motif.fastq"
        )
        XCTAssertEqual(Set(motifRecords.map(\.identifier)), Set(["beta", "gamma"]))

        let dedupBundle = try await service.createDerivative(
            from: source.bundleURL,
            request: .deduplicate(preset: .exactPCR, substitutions: 0, optical: false, opticalDistance: 40)
        )
        let dedupRecords = try await exportRecords(
            service: service,
            from: dedupBundle,
            in: projectURL,
            named: "dedup.fastq"
        )
        XCTAssertEqual(dedupRecords.count, 2)
        XCTAssertTrue(dedupRecords.map(\.identifier).contains("alpha"))
        XCTAssertEqual(Set(dedupRecords.map(\.sequence)).count, 2)
    }

    func testSimulatedProjectPrimerTrimStoresVirtualTrimAndPreservesDescriptions() async throws {
        let projectURL = try makeProject()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let source = try makeFASTQBundle(named: "primers", in: projectURL)
        let primer = "ACGTACGT"
        try writeFASTQ(
            records: [
                (id: "trimmed", description: "sample=primer-hit", sequence: primer + "TTGGCCAATT"),
                (id: "other", description: "sample=untrimmed", sequence: "GGGGTTTTAAAA"),
            ],
            to: source.fastqURL
        )

        let configuration = FASTQPrimerTrimConfiguration(
            source: .literal,
            readMode: .single,
            mode: .fivePrime,
            forwardSequence: primer,
            anchored5Prime: true,
            errorRate: 0.12,
            minimumOverlap: 8,
            allowIndels: true,
            keepUntrimmed: false,
            searchReverseComplement: true
        )

        let service = FASTQDerivativeService()
        let trimmedBundle = try await service.createDerivative(
            from: source.bundleURL,
            request: .primerRemoval(configuration: configuration)
        )

        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: trimmedBundle))
        XCTAssertEqual(manifest.operation.kind, .primerRemoval)
        if case .trim(let filename) = manifest.payload {
            XCTAssertEqual(filename, FASTQBundle.trimPositionFilename)
        } else {
            XCTFail("Expected primer trim payload")
        }

        let records = try await exportRecords(
            service: service,
            from: trimmedBundle,
            in: projectURL,
            named: "primer-trimmed.fastq"
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.identifier, "trimmed")
        XCTAssertEqual(records.first?.description, "sample=primer-hit")
        XCTAssertEqual(records.first?.sequence, "TTGGCCAATT")
    }

    func testSimulatedProjectDemultiplexCreatesPerBarcodeVirtualBundles() async throws {
        let projectURL = try makeProject()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let source = try makeFASTQBundle(named: "barcoded", in: projectURL)
        let kit = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "ont-nbd114"))
        let barcode13 = try XCTUnwrap(kit.barcodes.first(where: { $0.id == "barcode13" }))
        let barcode14 = try XCTUnwrap(kit.barcodes.first(where: { $0.id == "barcode14" }))
        let context = ONTNativeAdapterContext()

        let insert13 = "GATTACAGATTACA"
        let insert14 = "CCGGTTAACCGGTT"
        let read13 = context.fivePrimeSpec(barcodeSequence: barcode13.i7Sequence)
            + insert13
            + context.threePrimeSpec(barcodeSequence: barcode13.i7Sequence)
        let read14 = context.fivePrimeSpec(barcodeSequence: barcode14.i7Sequence)
            + insert14
            + context.threePrimeSpec(barcodeSequence: barcode14.i7Sequence)

        try writeFASTQ(
            records: [
                (id: "read13", description: "sample=barcode13", sequence: read13),
                (id: "read14", description: "sample=barcode14", sequence: read14),
            ],
            to: source.fastqURL
        )

        let service = FASTQDerivativeService()
        _ = try await service.createDerivative(
            from: source.bundleURL,
            request: .demultiplex(
                kitID: kit.id,
                customCSVPath: nil,
                location: "bothEnds",
                symmetryMode: nil,
                maxDistanceFrom5Prime: 0,
                maxDistanceFrom3Prime: 0,
                errorRate: 0.0,
                trimBarcodes: true,
                sampleAssignments: nil,
                kitOverride: kit
            )
        )

        let demuxDirectory = source.bundleURL.appendingPathComponent("demux", isDirectory: true)
        let barcode13Bundle = demuxDirectory.appendingPathComponent("barcode13.\(FASTQBundle.directoryExtension)", isDirectory: true)
        let barcode14Bundle = demuxDirectory.appendingPathComponent("barcode14.\(FASTQBundle.directoryExtension)", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: barcode13Bundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: barcode14Bundle.path))

        for (bundleURL, expectedID, expectedSequence) in [
            (barcode13Bundle, "read13", insert13),
            (barcode14Bundle, "read14", insert14),
        ] {
            let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleURL))
            if case .demuxedVirtual(_, _, let previewFilename, let trimFilename, _) = manifest.payload {
                XCTAssertEqual(previewFilename, "preview.fastq")
                XCTAssertNotNil(trimFilename)
            } else {
                XCTFail("Expected demuxed virtual payload")
            }
            let previewURL = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
            XCTAssertEqual(previewURL.lastPathComponent, "preview.fastq")

            let records = try await exportRecords(
                service: service,
                from: bundleURL,
                in: projectURL,
                named: "\(expectedID).fastq"
            )
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.identifier, expectedID)
            XCTAssertTrue(records.first?.sequence.contains(expectedSequence) == true)
            XCTAssertLessThan(records.first?.sequence.count ?? 0, bundleURL == barcode13Bundle ? read13.count : read14.count)
        }
    }

    func testFASTQDerivativeParameterValidationRejectsInvalidRequests() async throws {
        let projectURL = try makeProject()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let source = try makeFASTQBundle(named: "invalid", in: projectURL)
        try writeFASTQ(records: [(id: "r1", description: nil, sequence: "AACCGGTT")], to: source.fastqURL)

        let service = FASTQDerivativeService()

        await XCTAssertThrowsErrorAsync(
            try await service.createDerivative(from: source.bundleURL, request: .lengthFilter(min: nil, max: nil))
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid FASTQ operation: Specify a minimum length, a maximum length, or both.")
        }

        await XCTAssertThrowsErrorAsync(
            try await service.createDerivative(from: source.bundleURL, request: .lengthFilter(min: 10, max: 5))
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid FASTQ operation: Minimum length cannot exceed maximum length.")
        }

        let invalidPrimerConfiguration = FASTQPrimerTrimConfiguration(
            source: .literal,
            readMode: .single,
            mode: .fivePrime,
            forwardSequence: "ACGT",
            errorRate: 0.12,
            minimumOverlap: 0
        )
        await XCTAssertThrowsErrorAsync(
            try await service.createDerivative(from: source.bundleURL, request: .primerRemoval(configuration: invalidPrimerConfiguration))
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid FASTQ operation: Primer minimum overlap must be > 0.")
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message.isEmpty ? "Expected error to be thrown" : message, file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
