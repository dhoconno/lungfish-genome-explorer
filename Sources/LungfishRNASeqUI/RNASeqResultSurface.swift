// RNASeqResultSurface.swift - An RNA-seq result as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// What a `.lungfishrnaseq` folder says about itself, spelled as its manifest spells it. The surface shows these
/// facts and computes nothing from the tables (`docs/formats/rnaseq-bundle.md`).
public struct RNASeqResultFacts: Equatable, Sendable {
    public var name: String
    /// `bulk`, `single-cell` or `cell-map`, as the manifest writes it.
    public var modality: String
    /// The origin kind, then the tool and version that made the files when the manifest names them.
    public var origin: String
    /// The route id, then its tool and version.
    public var route: String
    public var sampleCount: Int

    public init(name: String, modality: String, origin: String, route: String, sampleCount: Int) {
        self.name = name
        self.modality = modality
        self.origin = origin
        self.route = route
        self.sampleCount = sampleCount
    }

    public init(result: RNASeqResult) {
        let manifest = result.manifest
        let made = [manifest.origin.tool, manifest.origin.toolVersion].compactMap { $0 }.joined(separator: " ")
        self.init(
            name: manifest.name,
            modality: manifest.modality.rawValue,
            origin: made.isEmpty ? manifest.origin.kind.rawValue : "\(manifest.origin.kind.rawValue), \(made)",
            route: "\(manifest.route.id), \(manifest.route.tool) \(manifest.route.toolVersion)",
            sampleCount: result.samples.count)
    }

    /// The label and value of each line the header shows, in order.
    public var rows: [(label: String, value: String)] {
        [("Name", name), ("Modality", modality), ("Origin", origin), ("Route", route), ("Samples", String(sampleCount))]
    }
}

/// What reading a result gave. It holds no state of the main actor, so a detached task can return it.
public enum RNASeqResultLoadOutcome: Equatable, Sendable {
    case loaded(RNASeqResult)
    /// The words of the reader's error, which are the words of `docs/formats/rnaseq-bundle.md`.
    case failed(String)
}

/// The RNA-seq result viewer as a ``ResultViewport``. Its input is the `URL` of the `.lungfishrnaseq` folder. The
/// surface reads the folder with ``RNASeqResultBundle`` off the main actor and writes nothing into it. A newer schema
/// or an unreadable manifest shows its words in the view and does not throw into the route.
@MainActor
public final class RNASeqResultSurface: ResultViewport {
    /// The container the host installs. It hosts the bulk or the single-cell view by the manifest's modality.
    public let controller: RNASeqResultViewController

    private let configure: @MainActor (RNASeqResultSurface) -> Void

    /// Called after a result is shown, so the App can give the Inspector the result's name and record.
    public var onLoaded: (@MainActor (RNASeqResultFacts, URL) -> Void)?

    /// Called with a cell map's fact lines (label and value) on each refresh of its view, and with none when the map
    /// closes or a reread fails, so the App can show them in the Inspector. The values are already on the main actor.
    public var onCellMapFacts: (@MainActor ([(label: String, value: String)], URL) -> Void)? {
        get { controller.onCellMapFacts }
        set { controller.onCellMapFacts = newValue }
    }

    /// Called with Save Selection as Labels Table… or Pseudobulk Selected Cells… of a cell map's view, so the App launches
    /// `lungfish-cli rnaseq cell-map select`. The module writes nothing itself.
    public var onSelectionAction: (@MainActor (RNASeqEmbeddingSelectionAction) -> Void)? {
        get { controller.onSelectionAction }
        set { controller.onSelectionAction = newValue }
    }

    public init(configure: @escaping @MainActor (RNASeqResultSurface) -> Void = { _ in }) {
        self.controller = RNASeqResultViewController(nibName: nil, bundle: nil)
        self.configure = configure
    }

    /// The factory the App registers, which makes a new surface for each show.
    public static func factory(
        configure: @escaping @MainActor (RNASeqResultSurface) -> Void = { _ in }
    ) -> SurfaceRegistry.Factory {
        { RNASeqResultSurface(configure: configure) }
    }

    public var viewController: NSViewController { controller }

    public var surfaceKind: SurfaceKind { .bundle(.rnaseqResult) }

    public func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let bundleURL = try expectInput(input, as: URL.self)
        configure(self)
        let outcome = await Task.detached(priority: .userInitiated) { RNASeqResultSurface.read(bundleURL) }.value
        try Task.checkCancellation()
        // A cell map's coordinates and colours are read inside this load, the host's `loadTask`, so the memory guard's
        // cancel of that task reaches the read (`Sources/LungfishApp/Services/AppMemoryGuard.swift`, cancelLoads).
        var cellMap: RNASeqCellMapLoadOutcome?
        if case .loaded(let result) = outcome, result.manifest.modality == .cellMap {
            cellMap = await RNASeqCellMapLoader.load(result: result, bundleURL: bundleURL)
            try Task.checkCancellation()
        }
        present(outcome, bundleURL: bundleURL, cellMap: cellMap)
    }

    /// Called when the host removes this viewer, with the folder it showed, so the App can take that result's rows out
    /// of the Inspector. A dataset or result that sets no Inspector document of its own would otherwise show under them.
    public var onWillDeactivate: (@MainActor (URL) -> Void)?

    /// The folder ``present(_:bundleURL:cellMap:)`` last showed.
    private var shownURL: URL?

    /// Stops the cell map's reads, which publish their empty lines, tells the App which result goes, then drops the
    /// App's closures.
    public func willDeactivate(replacedBy next: SurfaceKind?) {
        controller.cellMap?.close()
        onCellMapFacts = nil
        if let shownURL { onWillDeactivate?(shownURL) }
        onWillDeactivate = nil
    }

    /// Shows what the read gave and tells the App when it was a result. A cell map shows `cellMap`, or reads its own
    /// when the caller read none.
    public func present(_ outcome: RNASeqResultLoadOutcome, bundleURL: URL, cellMap: RNASeqCellMapLoadOutcome? = nil) {
        shownURL = bundleURL
        controller.show(outcome, bundleURL: bundleURL, cellMap: cellMap)
        if case .loaded(let result) = outcome {
            onLoaded?(RNASeqResultFacts(result: result), bundleURL)
        }
    }

    /// Reads the folder. It only reads, so a result is never changed by being opened.
    public nonisolated static func read(_ bundleURL: URL) -> RNASeqResultLoadOutcome {
        do {
            return .loaded(try RNASeqResultBundle.load(from: bundleURL))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// The container of a result. A header lists the facts, and the view of the modality sits under it.
@MainActor
public final class RNASeqResultViewController: NSViewController {
    public static let accessibilityID = "rnaseq-result-view"

    public private(set) var facts: RNASeqResultFacts?
    /// The reader's words when the folder could not be shown, and nil otherwise.
    public private(set) var failureWords: String?
    public private(set) var bulk: RNASeqBulkViewController?
    public private(set) var singleCell: RNASeqSingleCellViewController?
    /// The embedding view of a cell map (5.5 O1 (a)).
    public private(set) var cellMap: RNASeqCellMapViewController?
    /// The selection actions of a cell map's view, handed to each view this container hosts.
    public var onSelectionAction: (@MainActor (RNASeqEmbeddingSelectionAction) -> Void)? {
        didSet { cellMap?.onSelectionAction = onSelectionAction }
    }
    /// The App's closure for a cell map's fact lines, which each hosted cell map view publishes through.
    var onCellMapFacts: (@MainActor ([(label: String, value: String)], URL) -> Void)?

    private let header = NSStackView()
    private let body = NSView()

    public override func loadView() {
        let root = NSView()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityIdentifier(Self.accessibilityID)
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(body)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// Shows the facts and hosts the view of the modality, or shows the words of the failure.
    public func show(_ outcome: RNASeqResultLoadOutcome, bundleURL: URL, cellMap shownMap: RNASeqCellMapLoadOutcome? = nil) {
        _ = view
        cellMap?.close()
        for line in header.arrangedSubviews {
            header.removeArrangedSubview(line)
            line.removeFromSuperview()
        }
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        bulk = nil
        singleCell = nil
        cellMap = nil
        switch outcome {
        case .failed(let words):
            facts = nil
            failureWords = words
            header.addArrangedSubview(Self.text(words, id: "rnaseq-result-failure", wraps: true))
        case .loaded(let result):
            let shown = RNASeqResultFacts(result: result)
            facts = shown
            failureWords = nil
            for row in shown.rows {
                header.addArrangedSubview(Self.fact(row.label, row.value, id: "rnaseq-result-\(row.label.lowercased())"))
            }
            host(result, bundleURL: bundleURL, cellMap: shownMap)
        }
    }

    private func host(_ result: RNASeqResult, bundleURL: URL, cellMap shownMap: RNASeqCellMapLoadOutcome?) {
        switch result.manifest.modality {
        case .bulk:
            let child = RNASeqBulkViewController(nibName: nil, bundle: nil)
            child.configure(result: result, bundleURL: bundleURL)
            install(child)
            bulk = child
        case .singleCell:
            let child = RNASeqSingleCellViewController(nibName: nil, bundle: nil)
            child.configure(result: result, bundleURL: bundleURL)
            install(child)
            singleCell = child
        case .cellMap:
            let child = RNASeqCellMapViewController(nibName: nil, bundle: nil)
            child.onSelectionAction = onSelectionAction
            child.onFacts = { [weak self] lines in self?.onCellMapFacts?(lines, bundleURL) }
            child.configure(result: result, bundleURL: bundleURL, outcome: shownMap)
            install(child)
            cellMap = child
        }
    }

    private func install(_ child: NSViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: body.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
    }

    /// A line of read-only text that a person can select and copy.
    private static func text(_ string: String, id: String, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: string) : NSTextField(labelWithString: string)
        field.isEditable = false
        field.isSelectable = true
        field.setAccessibilityIdentifier(id)
        return field
    }

    private static func fact(_ label: String, _ value: String, id: String) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.textColor = .secondaryLabelColor
        name.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [name, text(value, id: id)])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        return row
    }
}
