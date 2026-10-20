// TrackRendererSendableTests.swift - the value types the track draw functions take are Sendable
//
// RULING 2.5 of lane 13.29 says a track renderer is a synchronous function of Sendable values. The scene builders
// of M3 are `ViewerFigureTrackBuilding: Sendable` and store these values. A public type does not infer Sendable,
// so each type the read and variant draw functions take or return is named here. The assertion is that this file
// compiles, because `requireSendable` accepts only a type that conforms.

import XCTest
@testable import LungfishWorkflow

final class TrackRendererSendableTests: XCTestCase {

    func testDrawFunctionParametersAreSendable() {
        func requireSendable<T: Sendable>(_ type: T.Type) {}

        // `drawPackedReads` and `drawBaseReads` take the settings and the layout, `zoomTier(scale:)` returns the tier.
        requireSendable(ReadTrackRenderer.DisplaySettings.self)
        requireSendable(ReadTrackRenderer.ZoomTier.self)
        requireSendable(PackedReadLayout.self)

        // The values the same functions took before this lane and the frame and theme every draw function takes.
        requireSendable(ReadMismatchCache.self)
        requireSendable(ReadPackFrame.self)
        requireSendable(VariantSampleGutterCache.self)
        requireSendable(ViewerFigureFrame.self)
        requireSendable(ViewerFigureTheme.self)
    }
}
