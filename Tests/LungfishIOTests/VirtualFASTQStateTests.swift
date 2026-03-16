import XCTest
@testable import LungfishIO

final class VirtualFASTQStateTests: XCTestCase {

    // MARK: - MaterializationState Codable Round-Trip

    func testVirtualStateRoundTrips() throws {
        let state = MaterializationState.virtual
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(MaterializationState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testMaterializingStateRoundTrips() throws {
        let taskID = UUID()
        let state = MaterializationState.materializing(taskID: taskID)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(MaterializationState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testMaterializedStateRoundTrips() throws {
        let state = MaterializationState.materialized(checksum: "abc123def456")
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(MaterializationState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testMaterializationStateEquality() {
        XCTAssertEqual(MaterializationState.virtual, MaterializationState.virtual)
        let id = UUID()
        XCTAssertEqual(
            MaterializationState.materializing(taskID: id),
            MaterializationState.materializing(taskID: id)
        )
        XCTAssertNotEqual(
            MaterializationState.materializing(taskID: UUID()),
            MaterializationState.materializing(taskID: UUID())
        )
        XCTAssertEqual(
            MaterializationState.materialized(checksum: "abc"),
            MaterializationState.materialized(checksum: "abc")
        )
        XCTAssertNotEqual(
            MaterializationState.virtual,
            MaterializationState.materialized(checksum: "")
        )
    }

    // MARK: - FASTQDerivedBundleManifest.resolvedState

    func testResolvedStateDefaultsToVirtualForSubset() {
        let manifest = makeManifest(payload: .subset(readIDListFilename: "ids.txt"))
        XCTAssertEqual(manifest.resolvedState, .virtual)
    }

    func testResolvedStateDefaultsToVirtualForTrim() {
        let manifest = makeManifest(payload: .trim(trimPositionFilename: "trims.tsv"))
        XCTAssertEqual(manifest.resolvedState, .virtual)
    }

    func testResolvedStateDefaultsToMaterializedForFull() {
        let manifest = makeManifest(payload: .full(fastqFilename: "output.fastq"))
        if case .materialized = manifest.resolvedState {
            // Expected
        } else {
            XCTFail("Expected .materialized for .full payload")
        }
    }

    func testResolvedStateDefaultsToMaterializedForFullPaired() {
        let manifest = makeManifest(payload: .fullPaired(r1Filename: "r1.fq", r2Filename: "r2.fq"))
        if case .materialized = manifest.resolvedState {
            // Expected
        } else {
            XCTFail("Expected .materialized for .fullPaired payload")
        }
    }

    func testResolvedStateDefaultsToMaterializedForFullFASTA() {
        let manifest = makeManifest(payload: .fullFASTA(fastaFilename: "out.fasta"))
        if case .materialized = manifest.resolvedState {
            // Expected
        } else {
            XCTFail("Expected .materialized for .fullFASTA payload")
        }
    }

    func testResolvedStateDefaultsToVirtualForOrientMap() {
        let manifest = makeManifest(payload: .orientMap(orientMapFilename: "map.tsv", previewFilename: "preview.fq"))
        XCTAssertEqual(manifest.resolvedState, .virtual)
    }

    func testResolvedStateReturnsMaterializedWhenExplicitlySet() {
        var manifest = makeManifest(payload: .subset(readIDListFilename: "ids.txt"))
        manifest.materializationState = .materialized(checksum: "abc123")
        XCTAssertEqual(manifest.resolvedState, .materialized(checksum: "abc123"))
    }

    func testResolvedStateTreatsStaleMaterializingAsVirtual() {
        var manifest = makeManifest(payload: .subset(readIDListFilename: "ids.txt"))
        manifest.materializationState = .materializing(taskID: UUID())
        XCTAssertEqual(manifest.resolvedState, .virtual)
    }

    func testIsMaterializedProperty() {
        var manifest = makeManifest(payload: .subset(readIDListFilename: "ids.txt"))
        XCTAssertFalse(manifest.isMaterialized)

        manifest.materializationState = .materialized(checksum: "abc")
        XCTAssertTrue(manifest.isMaterialized)
    }

    // MARK: - Manifest with materializationState Round-Trip

    func testManifestWithMaterializationStateRoundTrips() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VirtualFASTQStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("test.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        var manifest = makeManifest(payload: .subset(readIDListFilename: "ids.txt"))
        manifest.materializationState = .materialized(checksum: "deadbeef")

        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.materializationState, .materialized(checksum: "deadbeef"))
        XCTAssertEqual(loaded?.resolvedState, .materialized(checksum: "deadbeef"))
        XCTAssertEqual(loaded?.isMaterialized, true)
    }

    func testManifestWithoutMaterializationStateDecodesNil() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VirtualFASTQStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("test.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Save WITHOUT setting materializationState
        let manifest = makeManifest(payload: .trim(trimPositionFilename: "trims.tsv"))
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)

        XCTAssertNotNil(loaded)
        XCTAssertNil(loaded?.materializationState)
        XCTAssertEqual(loaded?.resolvedState, .virtual)
    }

    // MARK: - VirtualFASTQDescriptor

    func testDescriptorFromManifest() {
        let manifest = makeManifest(payload: .subset(readIDListFilename: "ids.txt"))
        let bundleURL = URL(fileURLWithPath: "/tmp/test.lungfishfastq")
        let descriptor = VirtualFASTQDescriptor(bundleURL: bundleURL, manifest: manifest)

        XCTAssertEqual(descriptor.id, manifest.id)
        XCTAssertEqual(descriptor.bundleURL, bundleURL)
        XCTAssertEqual(descriptor.rootBundleRelativePath, manifest.rootBundleRelativePath)
        XCTAssertEqual(descriptor.rootFASTQFilename, manifest.rootFASTQFilename)
        XCTAssertEqual(descriptor.payload, manifest.payload)
        XCTAssertEqual(descriptor.lineage.count, manifest.lineage.count)
        XCTAssertEqual(descriptor.pairingMode, manifest.pairingMode)
        XCTAssertEqual(descriptor.sequenceFormat, manifest.sequenceFormat)
    }

    func testDescriptorResolvesRootBundleURL() {
        let manifest = makeManifest(payload: .subset(readIDListFilename: "ids.txt"))
        let bundleURL = URL(fileURLWithPath: "/projects/myproject/sample.lungfishfastq/derivatives/trimmed.lungfishfastq")
        let descriptor = VirtualFASTQDescriptor(bundleURL: bundleURL, manifest: manifest)

        let rootURL = descriptor.resolvedRootBundleURL
        // The root relative path is "../../sample.lungfishfastq" from derivatives/trimmed.lungfishfastq
        // But since our test uses "../parent.lungfishfastq", it resolves from the parent of bundleURL
        XCTAssertTrue(rootURL.path.contains("parent.lungfishfastq"))
    }

    func testDescriptorEquality() {
        let manifest = makeManifest(payload: .subset(readIDListFilename: "ids.txt"))
        let url = URL(fileURLWithPath: "/tmp/test.lungfishfastq")
        let d1 = VirtualFASTQDescriptor(bundleURL: url, manifest: manifest)
        let d2 = VirtualFASTQDescriptor(bundleURL: url, manifest: manifest)
        XCTAssertEqual(d1, d2)
    }

    // MARK: - Helpers

    private func makeManifest(payload: FASTQDerivativePayload) -> FASTQDerivedBundleManifest {
        let op = FASTQDerivativeOperation(kind: .subsampleCount, count: 100)
        return FASTQDerivedBundleManifest(
            name: "test-derivative",
            parentBundleRelativePath: "../parent.lungfishfastq",
            rootBundleRelativePath: "../parent.lungfishfastq",
            rootFASTQFilename: "reads.fastq.gz",
            payload: payload,
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: .singleEnd
        )
    }
}
