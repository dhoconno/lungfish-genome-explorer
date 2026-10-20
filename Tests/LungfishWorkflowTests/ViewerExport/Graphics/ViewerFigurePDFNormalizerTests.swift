// ViewerFigurePDFNormalizerTests.swift - The PDF rewrite that takes out the clock and the random ID
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.28 M3 (QA ruling QA-GFX-mask, QM-2 and item 3d). Each volatile value alone is removed,
// a change anywhere else survives with another /ID, the offsets and the document stay valid, and
// a layout the normalizer cannot read is kept as written with a reason.

import CoreGraphics
import XCTest
@testable import LungfishWorkflow

private typealias Support = ViewerFigureTestSupport

final class ViewerFigurePDFNormalizerTests: XCTestCase {
    private func asWritten() throws -> Data {
        try ViewerFigureRasterizer.pdfAsWritten(Support.sampleScene())
    }

    private func normalized(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> Data {
        switch ViewerFigurePDFNormalizer.normalize(data) {
        case .normalized(let bytes):
            return bytes
        case .keptAsWritten(_, let reason):
            XCTFail("kept as written: \(reason)", file: file, line: line)
            return data
        }
    }

    /// `data` with the byte at `offset` set to another digit, which is also a hex digit.
    private func changing(_ data: Data, at offset: Int) -> Data {
        var bytes = [UInt8](data)
        bytes[offset] = bytes[offset] == UInt8(ascii: "1") ? UInt8(ascii: "2") : UInt8(ascii: "1")
        return Data(bytes)
    }

    func testEachVolatileValueAloneIsRemoved() throws {
        let pdf = try asWritten()
        let expected = normalized(pdf)
        let ranges = ViewerFigurePDFNormalizer.volatileRanges(pdf)
        XCTAssertEqual(ranges.map(\.count), [1, 1, 1])
        let creation = try XCTUnwrap(ranges[0].first), modification = try XCTUnwrap(ranges[1].first)
        let idDigits = try XCTUnwrap(Support.pdfIDDigitRanges(pdf).first)
        // The last of the 14 digits of each date, and the first hex digit of the /ID.
        for (name, offset) in [
            ("/CreationDate", creation.lowerBound + "/CreationDate (D:".count + 13),
            ("/ModDate", modification.lowerBound + "/ModDate (D:".count + 13),
            ("/ID", idDigits.lowerBound),
        ] {
            let changed = changing(pdf, at: offset)
            XCTAssertNotEqual(changed, pdf, name)
            XCTAssertEqual(normalized(changed), expected, "a change inside \(name) alone is removed")
        }
    }

    func testAChangeOutsideTheThreeValuesSurvives() throws {
        let pdf = try asWritten()
        let expected = normalized(pdf)
        let text = try XCTUnwrap(String(data: pdf, encoding: .isoLatin1)) as NSString
        let producer = text.range(of: "/Producer (macOS Version ")
        XCTAssertNotEqual(producer.location, NSNotFound)
        let flate = text.range(of: "/FlateDecode")
        XCTAssertNotEqual(flate.location, NSNotFound)
        let stream = text.range(of: "stream\n", range: NSRange(location: flate.location, length: text.length - flate.location))
        XCTAssertNotEqual(stream.location, NSNotFound)
        for (name, offset) in [("/Producer", NSMaxRange(producer)), ("the first /FlateDecode stream", NSMaxRange(stream))] {
            let result = normalized(changing(pdf, at: offset))
            XCTAssertNotEqual(result, expected, "a change in \(name) survives")
            XCTAssertNotEqual(Support.pdfIDStrings(result), Support.pdfIDStrings(expected), "a change in \(name) gives another /ID")
        }
    }

    func testOffsetsAndDocumentStayValid() throws {
        let pdf = normalized(try asWritten())
        let text = try XCTUnwrap(String(data: pdf, encoding: .isoLatin1)) as NSString
        let xref = text.range(of: "\nxref\n", options: .backwards)
        let trailer = text.range(of: "trailer", options: .backwards)
        XCTAssertNotEqual(xref.location, NSNotFound)
        XCTAssertNotEqual(trailer.location, NSNotFound)
        let table = text.substring(with: NSRange(location: NSMaxRange(xref), length: trailer.location - NSMaxRange(xref)))
        let lines = table.split(whereSeparator: \.isNewline).map { $0.split(separator: " ") }
        var number = try XCTUnwrap(Int(try XCTUnwrap(lines.first?.first)))
        var inUse = 0
        for entry in lines.dropFirst() {
            defer { number += 1 }
            guard entry.count == 3, entry[2] == "n", let offset = Int(entry[0]) else { continue }
            inUse += 1
            let header = "\(number) 0 obj"
            XCTAssertEqual(text.substring(with: NSRange(location: offset, length: header.utf16.count)), header)
        }
        XCTAssertGreaterThan(inUse, 5, "the table lists the figure's objects")

        let provider = try XCTUnwrap(CGDataProvider(data: pdf as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(document.numberOfPages, 1)
        let derived = Support.derivedPDFID(pdf)
        let identifier = try XCTUnwrap(document.fileIdentifier)
        XCTAssertEqual(CGPDFArrayGetCount(identifier), 2)
        for index in 0 ..< 2 {
            var string: CGPDFStringRef?
            XCTAssertTrue(CGPDFArrayGetString(identifier, index, &string))
            let value = try XCTUnwrap(string)
            let bytes = UnsafeBufferPointer(start: CGPDFStringGetBytePtr(value), count: CGPDFStringGetLength(value))
            XCTAssertEqual(bytes.map { String(format: "%02x", $0) }.joined(), derived, "/ID string \(index)")
        }
        let info = try XCTUnwrap(document.info)
        var creator: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetString(info, "Creator", &creator))
        for key in ["CreationDate", "ModDate"] {
            var object: CGPDFObjectRef?
            XCTAssertFalse(CGPDFDictionaryGetObject(info, key, &object), key)
        }
    }

    func testAnUnexpectedLayoutIsKeptAsWritten() {
        let twoDates = Data("""
            %PDF-1.3
            1 0 obj
            << /Type /Catalog >>
            endobj
            2 0 obj
            << /CreationDate (D:20261020142225Z00'00') /CreationDate (D:20261020142226Z00'00') >>
            endobj
            trailer
            << /Size 3 /Root 1 0 R /Info 2 0 R /ID [ <00112233445566778899aabbccddeeff> <00112233445566778899aabbccddeeff> ] >>
            startxref
            0
            %%EOF

            """.utf8)
        let noTrailer = Data("%PDF-1.3\n1 0 obj\n<< /CreationDate (D:20261020142225Z00'00') >>\nendobj\n%%EOF\n".utf8)
        for (name, input) in [("two /CreationDate entries", twoDates), ("no trailer", noTrailer)] {
            guard case .keptAsWritten(let bytes, let reason) = ViewerFigurePDFNormalizer.normalize(input) else {
                XCTFail("\(name) was rewritten")
                continue
            }
            XCTAssertEqual(bytes, input, name)
            XCTAssertFalse(reason.isEmpty, name)
        }
    }

    func testTheIDFollowsTheContent() throws {
        let scene = Support.sampleScene()
        let one = try ViewerFigureRasterizer.render(scene, format: .pdf)
        let two = try ViewerFigureRasterizer.render(scene, format: .pdf)
        let items = scene.items.map { item -> ViewerFigureItem in
            guard case .text(let text) = item, text.string == "ACGT" else { return item }
            return .text(ViewerFigureText(
                string: "ACGA", fontName: text.fontName, fontSize: text.fontSize, point: text.point,
                anchor: text.anchor, paint: text.paint
            ))
        }
        let changed = ViewerFigureScene(
            width: scene.width, height: scene.height, appearance: scene.appearance, background: scene.background,
            frame: scene.frame, fonts: scene.fonts, items: items
        )
        XCTAssertNotEqual(changed, scene)
        let three = try ViewerFigureRasterizer.render(changed, format: .pdf)
        XCTAssertEqual(Support.pdfIDStrings(one).count, 2)
        XCTAssertEqual(Support.pdfIDStrings(one), Support.pdfIDStrings(two), "one figure gets one /ID")
        XCTAssertNotEqual(Support.pdfIDStrings(one), Support.pdfIDStrings(three), "another figure gets another /ID")
    }
}
