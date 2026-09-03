// FASTQPaletteTests.swift - Palette color resolution guarantees
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishApp

/// Guards the fix for a real freeze: `FASTQPalette.readFill` used to be a
/// file-scope global initialized by `NSColor(named:bundle:)`. Swift runs a
/// global's initializer once, under a one-time-initialization lock, at first
/// access -- and first access was inside `FASTQSparklineStrip.draw(_:)`. The
/// catalog read walks the bundle directory, so under heavy filesystem load the
/// main thread parked inside that lock and the whole app went unresponsive.
final class FASTQPaletteTests: XCTestCase {

    /// The teal is expected to match the LungfishTeal colorset it replaced.
    private let expectedLight = (red: CGFloat(0), green: CGFloat(0.627), blue: CGFloat(0.690))
    private let expectedDark = (red: CGFloat(0), green: CGFloat(0.769), blue: CGFloat(0.851))

    private func components(
        of color: NSColor,
        in appearanceName: NSAppearance.Name
    ) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        var result: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var resolutionFailure: Error?
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = color.usingColorSpace(.sRGB) else {
                resolutionFailure = CocoaError(.featureUnsupported)
                return
            }
            result = (srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent)
        }
        if let resolutionFailure { throw resolutionFailure }
        return result
    }

    /// The core regression: resolving the palette must never consult the asset
    /// catalog, because that is the call that can block. Asserting "it is fast"
    /// would be a flaky proxy; asserting the blocking call is never made is the
    /// real invariant.
    ///
    /// Caveat this test cannot escape: a stored color is resolved lazily, so if
    /// some earlier test already touched `FASTQPalette` the catalog call would
    /// have happened before the swizzle was installed. The appearance tests
    /// below are what actually pin the implementation; this one guards the
    /// per-draw resolution path, which is where the observed freeze occurred.
    func testResolvingReadFillDuringDrawNeverConsultsTheAssetCatalog() throws {
        let recorder = try XCTUnwrap(CatalogLookupRecorder())
        defer { recorder.restore() }

        // Force full resolution in both appearances, which is everything a draw
        // pass would do, including any dynamic provider block.
        _ = try components(of: FASTQPalette.readFill, in: .aqua)
        _ = try components(of: FASTQPalette.readFill, in: .darkAqua)
        _ = try components(of: FASTQPalette.readFillFaded, in: .aqua)
        _ = try components(of: FASTQPalette.readFillFaded, in: .darkAqua)

        XCTAssertEqual(
            recorder.lookupCount, 0,
            "Resolving the FASTQ palette called +[NSColor colorNamed:bundle:], which walks the "
            + "bundle directory and can park the main thread during draw."
        )
    }

    func testReadFillKeepsBothCatalogAppearances() throws {
        let light = try components(of: FASTQPalette.readFill, in: .aqua)
        let dark = try components(of: FASTQPalette.readFill, in: .darkAqua)

        XCTAssertEqual(light.red, expectedLight.red, accuracy: 0.002)
        XCTAssertEqual(light.green, expectedLight.green, accuracy: 0.002)
        XCTAssertEqual(light.blue, expectedLight.blue, accuracy: 0.002)
        XCTAssertEqual(light.alpha, 1, accuracy: 0.002)

        XCTAssertEqual(dark.red, expectedDark.red, accuracy: 0.002)
        XCTAssertEqual(dark.green, expectedDark.green, accuracy: 0.002)
        XCTAssertEqual(dark.blue, expectedDark.blue, accuracy: 0.002)
        XCTAssertEqual(dark.alpha, 1, accuracy: 0.002)

        XCTAssertNotEqual(
            light.green, dark.green, accuracy: 0.001,
            "Light and dark must stay distinct; a flat fallback would silently lose the dark variant."
        )
    }

    /// `readFillFaded` is derived with `withAlphaComponent(0.15)`. A dynamic
    /// color must survive that derivation still appearance-aware rather than
    /// snapshotting whichever appearance happened to be current.
    func testFadedReadFillStaysAppearanceAwareAfterAlphaDerivation() throws {
        let light = try components(of: FASTQPalette.readFillFaded, in: .aqua)
        let dark = try components(of: FASTQPalette.readFillFaded, in: .darkAqua)

        XCTAssertEqual(light.alpha, 0.15, accuracy: 0.002)
        XCTAssertEqual(dark.alpha, 0.15, accuracy: 0.002)

        XCTAssertEqual(light.green, expectedLight.green, accuracy: 0.002)
        XCTAssertEqual(dark.green, expectedDark.green, accuracy: 0.002)
    }
}

/// Swizzles `+[NSColor colorNamed:bundle:]` so a test can prove the palette
/// never reaches the asset catalog.
private final class CatalogLookupRecorder {
    /// The swizzled implementation is a C function pointer with no context, so
    /// the counter has to be reachable globally. A locked box keeps that safe
    /// under strict concurrency.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static let counter = Counter()

    private let original: IMP
    private let method: Method

    init?() {
        let selector = NSSelectorFromString("colorNamed:bundle:")
        guard let method = class_getClassMethod(NSColor.self, selector) else { return nil }
        self.method = method

        let counter = Self.counter
        let replacement: @convention(block) (AnyObject, NSString, Bundle?) -> NSColor? = { _, _, _ in
            counter.increment()
            // Returning nil keeps the test from depending on catalog contents;
            // production code under test must not be calling this at all.
            return nil
        }
        original = method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    var lookupCount: Int { Self.counter.current }

    func restore() {
        method_setImplementation(method, original)
    }
}
