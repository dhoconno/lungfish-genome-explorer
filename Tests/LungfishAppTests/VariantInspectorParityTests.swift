import XCTest
import AppKit
import LungfishKit
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

@MainActor
final class VariantInspectorParityTests: XCTestCase {
    func testSelectWithoutDatabaseKeepsProjectedInfoIncludingZeroValues() {
        let model = VariantSectionViewModel()
        model.select(variant: makeResult(info: ["AF": "0", "ALT_FREQ": "0.0000"]))

        XCTAssertEqual(Dictionary(uniqueKeysWithValues: model.infoFields.map { ($0.key, $0.value) }), [
            "AF": "0",
            "ALT_FREQ": "0.0000",
        ])
    }

    func testDatabaseInfoMergesWithProjectedInfoAndProjectedValueWins() async throws {
        let database = try makeDatabase(info: "AF=0.25;DP=40")
        let model = VariantSectionViewModel()
        model.variantDatabase = database
        model.select(variant: makeResult(info: ["AF": "0.375", "ALT_FREQ": "0.375"]))
        await model.awaitGenotypeSummaryLoadForTesting()

        let fields = Dictionary(uniqueKeysWithValues: model.infoFields.map { ($0.key, $0.value) })
        XCTAssertEqual(fields["AF"], "0.375")
        XCTAssertEqual(fields["ALT_FREQ"], "0.375")
        XCTAssertEqual(fields["DP"], "40")
    }

    func testExplicitUnmatchedTrackDoesNotUseArbitraryDatabase() async throws {
        let model = VariantSectionViewModel()
        model.variantDatabasesByTrackId = ["actual-track": try makeDatabase(info: "DP=40")]
        model.select(variant: makeResult(trackID: "different-track", info: ["AF": "0.1"]))
        await model.awaitGenotypeSummaryLoadForTesting()

        XCTAssertFalse(model.hasGenotypes)
        XCTAssertEqual(model.infoFields.map(\.key), ["AF"])
    }

    func testPresentationAndCopyIncludeEveryDynamicField() {
        let model = VariantSectionViewModel()
        let info = Dictionary(uniqueKeysWithValues: (0..<25).map { ("FIELD_\($0)", "value-\($0)") })
        model.select(
            variant: makeResult(info: info),
            tableFields: [VariantInspectorField(key: "track_name", label: "Variant Track", value: "iVar")]
        )

        XCTAssertEqual(model.infoFields.count, 25)
        let copy = model.copyText(for: try! XCTUnwrap(model.selectedVariant))
        XCTAssertTrue(copy.contains("Variant Track: iVar"))
        XCTAssertTrue(copy.contains("FIELD_0: value-0"))
        XCTAssertTrue(copy.contains("FIELD_24: value-24"))
    }

    func testDrawerPresentationFieldsMatchEveryFixedVariantColumn() {
        let drawer = AnnotationTableDrawerView(frame: .zero)
        let result = makeResult(
            trackID: "ivar-track",
            trackName: "iVar Calls",
            info: [
                "GENE": "S",
                "Consequence": "missense_variant",
                "HGVSp": "p.D614G",
            ]
        )

        let fields = drawer.variantInspectorFields(for: result)

        XCTAssertEqual(fields.count, AnnotationTableDrawerView.variantColumnDefs.count)
        for (field, definition) in zip(fields, AnnotationTableDrawerView.variantColumnDefs) {
            XCTAssertEqual(field.key, definition.4)
            XCTAssertEqual(field.label, definition.1)
            XCTAssertEqual(field.value, drawer.variantColumnValue(result, key: definition.4))
        }
        XCTAssertEqual(fields.first(where: { $0.key == "track_name" })?.value, "iVar Calls")
        XCTAssertEqual(fields.first(where: { $0.key == "coding_feature" })?.value, "S")
        XCTAssertEqual(fields.first(where: { $0.key == "consequence" })?.value, "missense_variant")
        XCTAssertEqual(fields.first(where: { $0.key == "aa_change" })?.value, "p.D614G")
    }

    func testInspectorNotificationPassesOptionalTableContextWithinScope() {
        let inspector = InspectorViewController()
        let scope = WindowStateScope()
        inspector.testingWindowStateScope = scope
        let fields = [VariantInspectorField(key: "caller_settings", label: "Caller Settings", value: "Minimum depth: 10")]

        inspector.handleVariantSelected(Notification(
            name: .variantSelected,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.windowStateScope: scope,
                NotificationUserInfoKey.searchResult: makeResult(),
                NotificationUserInfoKey.variantInspectorFields: fields,
            ]
        ))

        XCTAssertEqual(inspector.variantSectionViewModel.tableFields, fields)
    }

    func testShowInInspectorNotificationCarriesResolvedTableContext() {
        let drawer = AnnotationTableDrawerView(frame: .zero)
        let result = makeResult(
            trackID: "ivar-track",
            trackName: "iVar Calls",
            info: ["GENE": "S", "Consequence": "missense_variant", "HGVSp": "p.D614G"]
        )
        let capture = VariantInspectorFieldsCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .variantSelected,
            object: drawer,
            queue: nil
        ) { notification in
            capture.record(notification.userInfo?[NotificationUserInfoKey.variantInspectorFields])
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let item = NSMenuItem()
        item.representedObject = result

        drawer.showInInspectorAction(item)

        XCTAssertEqual(capture.fields, drawer.variantInspectorFields(for: result))
    }

    private func makeResult(
        trackID: String = "variants",
        trackName: String? = nil,
        info: [String: String] = [:]
    ) -> AnnotationSearchIndex.SearchResult {
        AnnotationSearchIndex.SearchResult(
            name: "variant-1",
            chromosome: "chr1",
            start: 99,
            end: 100,
            trackId: trackID,
            trackName: trackName,
            type: "SNP",
            strand: ".",
            ref: "A",
            alt: "G",
            quality: 30,
            filter: "PASS",
            sampleCount: 1,
            variantRowId: 1,
            infoDict: info,
            sourceFile: "calls.vcf"
        )
    }

    private func makeDatabase(info: String) throws -> VariantDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("variant-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let vcfURL = directory.appendingPathComponent("calls.vcf")
        try """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1
        chr1\t100\tvariant-1\tA\tG\t30\tPASS\t\(info)\tGT\t0/1
        """.write(to: vcfURL, atomically: true, encoding: .utf8)
        let databaseURL = directory.appendingPathComponent("calls.sqlite")
        _ = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: databaseURL, parseGenotypes: true)
        return try VariantDatabase(url: databaseURL)
    }
}

private final class VariantInspectorFieldsCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFields: [VariantInspectorField]?

    var fields: [VariantInspectorField]? {
        lock.lock()
        defer { lock.unlock() }
        return storedFields
    }

    func record(_ value: Any?) {
        lock.lock()
        storedFields = value as? [VariantInspectorField]
        lock.unlock()
    }
}
