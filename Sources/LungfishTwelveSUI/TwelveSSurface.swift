// TwelveSSurface.swift - The 12S amplicon result as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// The 12S amplicon result viewer as a ``ResultViewport``.
///
/// Its input is the ``TwelveSAmpliconResultBundleData`` the caller has already read,
/// so its load does not suspend and the host installs it before `show` returns. The
/// App registers ``factory(configure:)`` for `.bundle(.twelveSResult)`.
@MainActor
public final class TwelveSSurface: ResultViewport {
    /// The result viewer the host installs.
    public let controller: TwelveSAmpliconResultViewController

    private let configure: @MainActor (TwelveSAmpliconResultViewController) -> Void

    /// A surface whose `configure` wires what the App owns, such as the BLAST
    /// submission of unresolved sequences, before the result is shown.
    public init(configure: @escaping @MainActor (TwelveSAmpliconResultViewController) -> Void = { _ in }) {
        self.controller = TwelveSAmpliconResultViewController()
        self.configure = configure
    }

    /// The factory the App registers, which makes a new surface for each show.
    public static func factory(
        configure: @escaping @MainActor (TwelveSAmpliconResultViewController) -> Void
    ) -> SurfaceRegistry.Factory {
        { TwelveSSurface(configure: configure) }
    }

    public var viewController: NSViewController { controller }

    public var surfaceKind: SurfaceKind { .bundle(.twelveSResult) }

    /// Shows the result and wires the multi-sample picker (the NAO-MGS and NVD
    /// idiom). Each entry's metric is the sample's exact-match read count.
    public func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let result = try expectInput(input, as: TwelveSAmpliconResultBundleData.self)
        configure(controller)
        controller.configure(result: result)

        let sampleEntries = result.samples.map { sample in
            TwelveSSampleEntry(
                id: sample.sampleID,
                displayName: sample.displayName,
                exactReads: sample.exactMatchReads
            )
        }
        let pickerState = ClassifierSamplePickerState(allSamples: Set(sampleEntries.map(\.id)))
        controller.configureSamples(sampleEntries, state: pickerState)
    }
}
