// ViewportHost+ViewMemory.swift - The host captures each view, restores it before the install and draws the reset line
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension ViewportHost {
    /// Keeps the installed view without removing it (VS S1). The host's window-close observer calls it, and so does
    /// the quit, for every live host before the store's flush. A project close needs no call of its own, since its
    /// view is captured when the next show or clear removes it, at the window's close or at the quit, and the store
    /// keeps a project's entries for the whole run.
    public func captureActive() {
        viewMemorySession?.capture()
    }

    /// Removes the installed item's kept view, leaves its retire mark and shows the view it started from (VS U3).
    public func resetViewMemory() {
        viewMemorySession?.reset()
    }

    /// Whether the installed view differs from the view it started from, which enables View > Reset View (VS U3). One
    /// capture of the installed view and one compare on the main actor, with no store read.
    public var viewMemoryDiffersFromStart: Bool {
        viewMemorySession?.differs() ?? false
    }

    /// The step between `load` and the install: when the surface adopts view memory and its project's entries are
    /// read, it gets its kept view now, or its handle when its own load is pending.
    func prepareViewMemory(for viewport: any ResultViewport) -> ViewMemoryOpening? {
        guard let adopter = viewport as? any ViewMemoryAdopting else { return nil }
        return openViewMemory(adopter)
    }

    private func openViewMemory<Adopter: ViewMemoryAdopting>(_ adopter: Adopter) -> ViewMemoryOpening? {
        guard let item = adopter.viewMemoryItem, let key = viewMemoryStore.key(for: item) else { return nil }
        let store = viewMemoryStore
        let start = ViewMemoryStart(adopter.captureViewMemory())
        var words: String?
        var kept: (view: Adopter.ViewState, dataKey: String?, selectionDropped: Bool)?
        switch store.restorable(Adopter.ViewState.self, for: key, folder: item.folder) {
        case .nothing:
            break
        case .folderChanged:
            words = ViewMemoryWords.viewReset
        case .view(let view, let dataKey, let selectionDropped):
            kept = (view, dataKey, selectionDropped)
        }
        var pending: ViewMemoryHandle<Adopter.ViewState>?
        if adopter.viewMemoryLoadIsPending {
            // Every pending adopter gets a handle, kept view or none, so its apply always moves the start (VS A2, S3).
            // A late apply reaches only the installed surface, so its line never draws over another one.
            let handle = ViewMemoryHandle<Adopter.ViewState> { [weak self, weak adopter] startingView in
                guard let self, let adopter, self.activeViewport === adopter else { return }
                if let startingView { start.view = startingView }
                guard !start.resetBeforeApply, let kept, adopter.captureViewMemory() == start.view else { return }
                let changed = Self.dataChanged(from: kept.dataKey, to: adopter.viewMemoryDataKey)
                let loss = adopter.restoreViewMemory(kept.view, dataChanged: changed)
                if let line = ViewMemoryWords.line(loss: loss, selectionDropped: kept.selectionDropped) {
                    self.showResetLine(line)
                }
                adopter.announceViewMemory()
            }
            adopter.viewMemoryHandle = handle
            pending = handle
        } else if let kept {
            let changed = Self.dataChanged(from: kept.dataKey, to: adopter.viewMemoryDataKey)
            let loss = adopter.restoreViewMemory(kept.view, dataChanged: changed)
            words = ViewMemoryWords.line(loss: loss, selectionDropped: kept.selectionDropped)
        }
        let session = ViewMemorySession(
            capture: { [weak adopter, pending] in
                // Before the adopter's own load commits its starting view is not known, so nothing tells a person's
                // change from the app's own default. A visit that ends then keeps what the store holds.
                guard let adopter, pending?.isApplied ?? true else { return }
                store.keep(adopter.captureViewMemory(), startingView: start.view, for: key,
                           dataKey: adopter.viewMemoryDataKey, folder: item.folder)
            },
            reset: { [weak self, weak adopter, pending] in
                store.reset(key, kind: Adopter.ViewState.kind, folder: item.folder)
                if pending?.isApplied == false { start.resetBeforeApply = true }
                self?.removeResetLine()
                _ = adopter?.restoreViewMemory(start.view, dataChanged: false)
                // The view the reset shows is the start from now on, as the reference and genotype viewers re-base
                // theirs, so a restore that cannot give back the start exactly still leaves the item off (VS-INSP).
                if let adopter { start.view = adopter.captureViewMemory() }
                adopter?.announceViewMemory()
            },
            announce: { [weak adopter] in adopter?.announceViewMemory() },
            differs: { [weak adopter] in adopter.map { $0.captureViewMemory() != start.view } ?? false })
        return ViewMemoryOpening(session: session, words: words, announcesAtInstall: pending == nil)
    }

    /// Has the installed adopter announce its view on the main actor's next turn (SWIFT SF-1). The restore runs
    /// inside `show`, and a route wires the surface's callbacks, such as the Inspector's, after `show` returns in the
    /// same turn, so this one call in the host reaches every adopter's listeners and no route adds a line. Nothing is
    /// told when another show or a clear removed the surface first.
    func announceAfterTheRoute(_ opening: ViewMemoryOpening) {
        guard opening.announcesAtInstall else { return }
        let session = opening.session
        Task { @MainActor [weak self] in
            guard let self, self.viewMemorySession === session else { return }
            session.announce()
        }
    }

    /// Whether the data changed since the view was kept. A key part not read never compares equal (VS B1).
    static func dataChanged(from kept: String?, to current: String?) -> Bool {
        guard let kept, let current else { return true }
        return kept != current
    }

    /// Draws the reset line above the installed surface, in the container the host owns, and reads it once to
    /// VoiceOver (VS U2). The next show removes it with the surface.
    ///
    /// The line starts at the container's safe-area top on every surface. The main window draws its content under the
    /// title bar and toolbar, and a surface that keeps the default pin starts at the container's edge and clears them
    /// with its own safe-area constraint, which the line has none of. At that edge the toolbar covered every line
    /// (2026.11.17 walk, row F1 C1b, VS-HOST-LINE). The surface's top follows the line's bottom, where it has no band
    /// left to clear, so its first row starts right below the line.
    ///
    /// The line is first in what stands above the surface. A view the container's owner hung the surface from, such as
    /// the viewer's affected-results strip, moves down to start at the line's bottom and keeps the surface under it.
    /// So a line drawn after the strip, as a late apply draws it, stacks as the install's line does: the line, the
    /// strip, the surface (VS-HOST-LINE continuation 1).
    func showResetLine(_ words: String) {
        guard let containerView, let installed = activeViewport?.viewController.view, let pin = installedTop else {
            return
        }
        removeResetLine()
        let line = ViewMemoryResetLineView(words: words)
        containerView.addSubview(line)
        let first = Self.firstView(above: installed, in: containerView)
        pin.constraint.isActive = false
        first.top?.isActive = false
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor),
            line.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            first.view.topAnchor.constraint(equalTo: line.bottomAnchor),
        ])
        resetLine = line
        line.announce()
    }

    /// Removes the reset line, and what started at its bottom takes its place. The installed surface goes back on its
    /// own pin. A view placed above the surface goes back to the safe-area top, where the line was, and the surface
    /// stays under it, so nothing moves above the container's edge.
    func removeResetLine() {
        guard let line = resetLine else { return }
        resetLine = nil
        let below = containerView.flatMap { Self.view(hangingFrom: line, in: $0) }
        line.removeFromSuperview()
        if let containerView, let below, below !== activeViewport?.viewController.view,
           below.superview === containerView {
            below.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor).isActive = true
        } else {
            installedTop?.constraint.isActive = true
        }
    }

    /// The top constraint the host gave the installed surface, at the container's edge or at its safe-area top. The
    /// line or a view placed above the surface turns it off while it shows, and the last of them to go turns it back
    /// on, so a view the viewer places keeps it to put back after the line went.
    public var installedSurfaceTopPin: NSLayoutConstraint? { installedTop?.constraint }

    /// The first of what stands above `surface` in `container`, with its active top constraint: the surface itself,
    /// or the view its top hangs from, and so on up to the one whose top holds to the container.
    private static func firstView(
        above surface: NSView, in container: NSView
    ) -> (view: NSView, top: NSLayoutConstraint?) {
        var view = surface
        for _ in container.subviews {
            guard let top = topConstraint(of: view, in: container) else { return (view, nil) }
            guard top.secondAttribute == .bottom, let above = top.secondItem as? NSView, above.superview === container
            else { return (view, top) }
            view = above
        }
        return (view, topConstraint(of: view, in: container))
    }

    private static func topConstraint(of view: NSView, in container: NSView) -> NSLayoutConstraint? {
        container.constraints.first { $0.isActive && $0.firstItem === view && $0.firstAttribute == .top }
    }

    /// The view whose top starts at `line`'s bottom.
    private static func view(hangingFrom line: NSView, in container: NSView) -> NSView? {
        container.constraints.first {
            $0.isActive && $0.firstAttribute == .top && $0.secondItem === line && $0.secondAttribute == .bottom
        }?.firstItem as? NSView
    }

    /// Signs the host up for its window's close and for the quit.
    func startViewMemory() {
        windowCloseObserver = ViewMemoryWindowCloseObserver(host: self)
        ViewMemoryQuit.register(self)
    }
}

/// The one line a view shows when it lost part or all of its kept view (VS U2).
@MainActor
public final class ViewMemoryResetLineView: NSView {
    /// The line's words.
    public let label: NSTextField

    public init(words: String) {
        label = NSTextField(wrappingLabelWithString: words)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityIdentifier("view-memory-reset-line")
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The words the line shows.
    public var words: String { label.stringValue }

    /// Reads the words once to VoiceOver, with no alert.
    func announce() {
        NSAccessibility.post(element: label, notification: .announcementRequested, userInfo: [
            .announcement: words,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

/// Has its host keep the installed view when the host's window closes, since no route removes the surface on that
/// way out (`MainWindowController+GenotypeRemoval.swift`).
@MainActor
final class ViewMemoryWindowCloseObserver: NSObject {
    private weak var host: ViewportHost?

    init(host: ViewportHost) {
        self.host = host
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let host, let window = notification.object as? NSWindow, host.containerWindow === window else { return }
        host.captureActive()
    }
}

/// The quit of view memory (VS A1, S1). At `NSApplication.willTerminateNotification` every live host keeps its
/// installed view, and then each store writes its changed items and joins its writer, so `AppDelegate.swift` gains no
/// line. Nothing removes the active surface on the way out, so the views stand as the person left them. The app posts
/// the notification on the main thread, where a selector observer runs it with no escape hatch.
@MainActor
final class ViewMemoryQuit: NSObject {
    private struct WeakHost {
        weak var host: ViewportHost?
    }

    private static var hosts: [WeakHost] = []
    private static var observer: ViewMemoryQuit?

    static func register(_ host: ViewportHost) {
        hosts.removeAll { $0.host == nil }
        hosts.append(WeakHost(host: host))
        guard observer == nil else { return }
        let quit = ViewMemoryQuit()
        NotificationCenter.default.addObserver(
            quit, selector: #selector(applicationWillTerminate(_:)), name: NSApplication.willTerminateNotification,
            object: nil)
        observer = quit
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        Self.captureEveryHostAndFlush()
    }

    /// Has every live host capture, then flushes each store once.
    static func captureEveryHostAndFlush() {
        let live = hosts.compactMap(\.host)
        live.forEach { $0.captureActive() }
        var flushed: Set<ObjectIdentifier> = []
        for host in live where flushed.insert(ObjectIdentifier(host.viewMemoryStore)).inserted {
            host.viewMemoryStore.flushSynchronously()
        }
    }
}
