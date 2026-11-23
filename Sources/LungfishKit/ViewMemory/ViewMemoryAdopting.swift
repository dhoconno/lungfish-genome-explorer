// ViewMemoryAdopting.swift - The hook a result surface adopts to keep its view, and the words of a view not kept
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// A result surface that keeps its view for each item (VS A2).
///
/// ``ViewportHost`` captures the view before it removes the surface, and at window close, project close and quit.
/// After `load` returns with its token current and before the host installs the surface, the host hands it the kept
/// view, so the first frame is the restored view. The adopter owns the clamp or drop rule of each field, by the
/// shared rules of VS B2 to B7, and the store never reads scientific data.
@MainActor
public protocol ViewMemoryAdopting: ResultViewport {
    /// The view the adopter keeps, one struct beside the surface.
    associatedtype ViewState: ViewMemoryState

    /// Where the item lives, read off the main actor in `load` with ``ViewMemoryItem/read(at:)``. Nil keeps nothing.
    var viewMemoryItem: ViewMemoryItem? { get }

    /// The data key of VS B1, read in `load` from a manifest or a record, never by hashing a file at open. Nil was
    /// not read and never compares equal.
    var viewMemoryDataKey: String? { get }

    /// Whether the adopter's own load runs on after `load` returns, so the host hands it a ``ViewMemoryHandle`` in
    /// place of the kept view, and keeps nothing for the visit until the handle applies (VS A2).
    var viewMemoryLoadIsPending: Bool { get }

    /// The handle the host sets after `load` when the adopter's own load is pending.
    var viewMemoryHandle: ViewMemoryHandle<ViewState>? { get set }

    /// The view as it stands, copied from the injected model.
    func captureViewMemory() -> ViewState

    /// Applies a kept view. `dataChanged` says the data key differs or was not read, so each field clamps or drops by
    /// its rule. It returns what it could not bring back, where a clamp alone is no loss. It starts nothing: no write,
    /// tool, search or long load, and a restored selection runs no command (VS S4).
    func restoreViewMemory(_ state: ViewState, dataChanged: Bool) -> ViewMemoryLoss

    /// Tells what listens to the surface, such as the Inspector, the view it shows now, as a person's change would.
    /// A route wires those callbacks after `show` returns, which is after the restore, so the host calls this on the
    /// main actor's next turn after the install, when the route has wired them, and at once after a late apply or a
    /// reset. No route adds a line for it. It starts nothing a click does not (VS S4).
    func announceViewMemory()
}

extension ViewMemoryAdopting {
    /// An adopter with no listeners of its own tells nothing.
    public func announceViewMemory() {}

    /// An adopter whose view is whole when `load` returns has no load of its own pending.
    public var viewMemoryLoadIsPending: Bool { false }

    /// An adopter with no pending load holds no handle.
    public var viewMemoryHandle: ViewMemoryHandle<ViewState>? {
        get { nil }
        set {}
    }
}

/// What the host hands an adopter whose own load runs on after `load` returns (VS A2).
@MainActor
public final class ViewMemoryHandle<State: ViewMemoryState> {
    private let apply: (_ startingView: State?) -> Void
    private var applied = false

    init(apply: @escaping (_ startingView: State?) -> Void) {
        self.apply = apply
    }

    /// Whether the adopter's own load has committed. Until it has, the host keeps nothing for the visit.
    var isApplied: Bool { applied }

    /// Applies the kept view when the adopter's own load commits, under its own load counter. It applies only while
    /// the view still equals `startingView`, or the view the host saw after `load` when that is nil, so a sort, a pick
    /// or typed text made before it is never overwritten. `startingView` is also the view a later capture compares
    /// with (VS S3), and the host keeps nothing for the visit before this call. A second call, or a call after the
    /// host removed the surface, does nothing.
    public func applyPending(startingView: State? = nil) {
        guard !applied else { return }
        applied = true
        apply(startingView)
    }
}

/// The words a view shows when it lost part or all of its kept view (VS U2, words 2 to 4). Each is one line of at
/// most 20 words, and VoiceOver reads the same words once.
public enum ViewMemoryWords {
    /// Word 3, when the record dropped whole because another folder stands at the item's path.
    public static let viewReset = "The data changed since your last visit, so the view was reset."

    /// Word 4, when a selection passed its cap and was dropped whole.
    public static let selectionTooLarge = "Your selection was too large to keep, so it was cleared."

    /// Word 2 for what `loss` names, in the order place, selection, filters and sample choice, or nil for none.
    public static func dataChanged(_ loss: ViewMemoryLoss) -> String? {
        let phrases: [(ViewMemoryLoss, String)] = [
            (.place, "place"), (.selection, "selection"), (.filters, "filters"), (.sampleChoice, "sample choice"),
        ]
        let nouns = phrases.filter { loss.contains($0.0) }.map(\.1)
        guard let last = nouns.last else { return nil }
        let list = nouns.count == 1 ? last : nouns.dropLast().joined(separator: ", ") + " and " + last
        let verb = nouns.count > 1 || last == "filters" ? "were" : "was"
        return "The data changed since your last visit, so your \(list) \(verb) not kept."
    }

    /// The one line a restore shows: word 2 when fields were dropped, else word 4 when the selection passed its cap.
    static func line(loss: ViewMemoryLoss, selectionDropped: Bool) -> String? {
        dataChanged(loss) ?? (selectionDropped ? selectionTooLarge : nil)
    }
}

/// The installed adopter's capture, reset and announce, which the host keeps while the surface is installed.
@MainActor
final class ViewMemorySession {
    let capture: () -> Void
    let reset: () -> Void
    let announce: () -> Void

    init(capture: @escaping () -> Void, reset: @escaping () -> Void, announce: @escaping () -> Void) {
        self.capture = capture
        self.reset = reset
        self.announce = announce
    }
}

/// A session and the words of its reset line, from the step between `load` and the install. A pending adopter
/// announces its view when it applies, not at the install.
struct ViewMemoryOpening {
    let session: ViewMemorySession
    let words: String?
    let announcesAtInstall: Bool
}

/// The view an adopter started from, which a pending adopter may move once its own load commits.
@MainActor
final class ViewMemoryStart<State: ViewMemoryState> {
    var view: State

    init(_ view: State) {
        self.view = view
    }
}
