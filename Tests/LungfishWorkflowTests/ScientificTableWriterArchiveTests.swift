import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

/// Lane 13.50 (XLSX-FIXED). One table exported twice gives equal bytes and an equal report (BIO 6, X10), whatever the
/// clock, the zone, the umask or `ZIPOPT` say. Each test here fails at the base d3a1fcdd8 (predictions P3 to P6).
final class ScientificTableWriterArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestTempDirectory.make(prefix: "ScientificTableWriterArchiveTests")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(directory)
    }

    /// The names the archive stores, in byte order.
    private static let sortedNames = [
        "[Content_Types].xml", "_rels/", "_rels/.rels", "xl/", "xl/_rels/", "xl/_rels/workbook.xml.rels",
        "xl/styles.xml", "xl/workbook.xml", "xl/worksheets/", "xl/worksheets/sheet1.xml",
    ]

    func testTwoExportsOfOneTableAreEqualInBytesAndReport() throws {
        let first = try XLSXArchiveProbe.export("first.xlsx", in: directory)
        // A ZIP entry time has a resolution of 2 seconds, so the second export starts more than 2 seconds later.
        Thread.sleep(forTimeInterval: 2.1)
        let second = try XLSXArchiveProbe.export("second.xlsx", in: directory)

        XCTAssertEqual(try Data(contentsOf: first.url), try Data(contentsOf: second.url))
        XCTAssertEqual(first.report, second.report)
    }

    func testTheRecordedArgvIsConstantAndNamesNoRunSpecificPath() throws {
        let report = try XLSXArchiveProbe.export("argv.xlsx", in: directory).report

        XCTAssertEqual(report.archiveToolPath, "/usr/bin/zip")
        XCTAssertEqual(report.archiveArgv, ["/usr/bin/zip", "-X", "-q", "table.xlsx"] + Self.sortedNames)
        let temporary = FileManager.default.temporaryDirectory.path
        XCTAssertFalse(
            (report.archiveArgv ?? []).contains { $0.contains(temporary) || UUID(uuidString: $0) != nil },
            "no element holds the temporary folder or a UUID"
        )
        XCTAssertNotNil(report.archiveToolVersion)
    }

    func testEntriesAreSortedWithTheEpochTimeNoExtraFieldAndFixedModes() throws {
        let archive = try XLSXArchiveProbe.export("entries.xlsx", in: directory).url
        let entries = try XLSXArchiveProbe.entries(of: archive)

        XCTAssertEqual(entries.map(\.name), Self.sortedNames, "the entries are stored in byte order of their names")
        XCTAssertEqual(entries.map(\.name), entries.map(\.name).sorted())
        XCTAssertTrue(entries.allSatisfy { $0.time == "19800101.000000" }, "\(entries)")
        XCTAssertTrue(entries.allSatisfy { $0.flags.last == "-" }, "no entry has an extra field, \(entries)")
        for entry in entries {
            XCTAssertEqual(entry.mode, entry.name.hasSuffix("/") ? "drwxr-xr-x" : "-rw-r--r--", entry.name)
        }
    }

    /// The zone, the umask and `ZIPOPT` of the user changed the bytes at the base (the zone east of UTC, a mask of 077
    /// and `ZIPOPT=-0` each gave another archive), so the writer fixes all three.
    func testBytesDoNotFollowTheZoneTheUmaskOrZIPOPT() throws {
        let plain = try Data(contentsOf: try XLSXArchiveProbe.export("plain.xlsx", in: directory).url)

        let savedMask = umask(0o077)
        let savedZone = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", "Pacific/Auckland", 1)
        tzset()
        setenv("ZIPOPT", "-0", 1)
        defer {
            umask(savedMask)
            if let savedZone { setenv("TZ", savedZone, 1) } else { unsetenv("TZ") }
            tzset()
            unsetenv("ZIPOPT")
        }
        let varied = try Data(contentsOf: try XLSXArchiveProbe.export("varied.xlsx", in: directory).url)

        XCTAssertEqual(plain, varied)
    }
}
