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
        switch store.restorable(Adopter.ViewState.self, for: key, folder: item.folder) {
        case .nothing:
            break
        case .folderChanged:
            words = ViewMemoryWords.viewReset
        case .view(let kept, let keptDataKey, let selectionDropped):
            if adopter.viewMemoryLoadIsPending {
                adopter.viewMemoryHandle = ViewMemoryHandle { [weak self, weak adopter] startingView in
                    guard let adopter else { return }
                    if let startingView { start.view = startingView }
                    guard adopter.captureViewMemory() == start.view else { return }
                    let changed = Self.dataChanged(from: keptDataKey, to: adopter.viewMemoryDataKey)
                    let loss = adopter.restoreViewMemory(kept, dataChanged: changed)
                    if let line = ViewMemoryWords.line(loss: loss, selectionDropped: selectionDropped) {
                        self?.showResetLine(line)
                    }
                }
            } else {
                let changed = Self.dataChanged(from: keptDataKey, to: adopter.viewMemoryDataKey)
                let loss = adopter.restoreViewMemory(kept, dataChanged: changed)
                words = ViewMemoryWords.line(loss: loss, selectionDropped: selectionDropped)
            }
        }
        let session = ViewMemorySession(
            capture: { [weak adopter] in
                guard let adopter else { return }
                store.keep(adopter.captureViewMemory(), startingView: start.view, for: key,
                           dataKey: adopter.viewMemoryDataKey, folder: item.folder)
            },
            reset: { [weak self, weak adopter] in
                store.reset(key, kind: Adopter.ViewState.kind, folder: item.folder)
                self?.removeResetLine()
                _ = adopter?.restoreViewMemory(start.view, dataChanged: false)
            })
        return ViewMemoryOpening(session: session, words: words)
    }

    /// Whether the data changed since the view was kept. A key part not read never compares equal (VS B1).
    static func dataChanged(from kept: String?, to current: String?) -> Bool {
        guard let kept, let current else { return true }
        return kept != current
    }

    /// Draws the reset line above the installed surface, in the container the host owns, and reads it once to
    /// VoiceOver (VS U2). The next show removes it with the surface.
    func showResetLine(_ words: String) {
        guard let containerView, let installed = activeViewport?.viewController.view, let pin = installedTop else {
            return
        }
        removeResetLine()
        let line = ViewMemoryResetLineView(words: words)
        containerView.addSubview(line)
        pin.constraint.isActive = false
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: pin.anchor),
            line.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            installed.topAnchor.constraint(equalTo: line.bottomAnchor),
        ])
        resetLine = line
        line.announce()
    }

    /// Removes the reset line and pins the installed surface's top where it was.
    func removeResetLine() {
        guard let line = resetLine else { return }
        resetLine = nil
        line.removeFromSuperview()
        installedTop?.constraint.isActive = true
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
