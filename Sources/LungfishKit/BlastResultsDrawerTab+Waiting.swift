// BlastResultsDrawerTab+Waiting.swift - The pane's waiting state, with Check Now, Send Again and Stop
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

/// The pane's words and buttons for a search with no result to show (UX-BLAST-WORDS Q1 and Q3).
@MainActor
public final class BlastWaitingPaneView: NSView {
    public let headingLabel = NSTextField(labelWithString: "")
    public let bodyLabel = NSTextField(wrappingLabelWithString: "")
    /// Each request ID, as selectable text.
    public let requestIDsLabel = NSTextField(wrappingLabelWithString: "")
    private let clockIcon = NSImageView()
    private let movingBar = NSProgressIndicator()
    private let buttonRow = NSStackView()
    public private(set) var state: BlastSearchPaneState?
    private var checkAgain: Task<Void, Never>?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        headingLabel.font = .systemFont(ofSize: 13, weight: .medium)
        headingLabel.alignment = .center
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .center
        requestIDsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        requestIDsLabel.textColor = .tertiaryLabelColor
        requestIDsLabel.alignment = .center
        requestIDsLabel.isSelectable = true
        clockIcon.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        clockIcon.contentTintColor = .secondaryLabelColor
        movingBar.style = .bar
        movingBar.isIndeterminate = true
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [clockIcon, movingBar, headingLabel, bodyLabel, requestIDsLabel, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            bodyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            requestIDsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            movingBar.widthAnchor.constraint(equalToConstant: 240),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func show(_ state: BlastSearchPaneState) {
        self.state = state
        headingLabel.stringValue = state.heading
        bodyLabel.stringValue = state.body
        requestIDsLabel.stringValue = state.requestIDs.joined(separator: "  ")
        clockIcon.isHidden = !state.holdsStill
        movingBar.isHidden = state.holdsStill
        if state.holdsStill { movingBar.stopAnimation(nil) } else { movingBar.startAnimation(nil) }
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for model in state.buttons {
            let button = NSButton(title: model.title, target: self, action: #selector(buttonPressed(_:)))
            button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier(model.action.rawValue)
            button.isEnabled = model.isEnabled
            button.toolTip = model.reason ?? (model.action == .stop ? Self.stopTip : nil)
            button.setAccessibilityHelp(button.toolTip)
            buttonRow.addArrangedSubview(button)
        }
        checkAgain?.cancel()
        checkAgain = nil
        guard let again = state.checkAgainAt else { return }
        let delay = max(again.timeIntervalSinceNow, 0)
        checkAgain = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let button = self?.button(for: .checkNow) else { return }
            button.isEnabled = true
            button.toolTip = nil
            button.setAccessibilityHelp(nil)
        }
    }

    /// The tooltip of Stop, which does not say it ends the search at NCBI, since it does not.
    public static let stopTip = "Stop this search. LGE stops checking, and NCBI may still finish it."

    /// The button that offers `action`, nil when this state does not.
    public func button(for action: BlastSearchPaneState.Action) -> NSButton? {
        buttonRow.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == action.rawValue }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let state, let raw = sender.identifier?.rawValue, let action = BlastSearchPaneState.Action(rawValue: raw) else { return }
        BlastSearchPaneActions.perform?(action, state.folder)
    }
}

extension BlastResultsDrawerTab {
    /// The noun of this pane's search, as its presentation style names what it sends.
    var searchNoun: String {
        switch presentationStyle {
        case .verification: return "reads"
        case .contigBlast: return "contigs"
        case .sequenceBlast: return "sequences"
        }
    }

    /// Puts the waiting pane in place, hidden until a state shows it.
    func setupWaitingPane() {
        addSubview(waitingPane)
        waitingPane.isHidden = true
        NSLayoutConstraint.activate([
            waitingPane.topAnchor.constraint(equalTo: topAnchor),
            waitingPane.leadingAnchor.constraint(equalTo: leadingAnchor),
            waitingPane.trailingAnchor.constraint(equalTo: trailingAnchor),
            waitingPane.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Shows `search` in its state's words, or the empty pane once it has its record, which a restore then reads.
    package func showWaiting(_ search: BlastLiveSearch, now: Date = Date()) {
        guard let state = BlastSearchPaneState.make(search, noun: searchNoun, now: now) else { return }
        showWaiting(state)
    }

    /// Shows `state`. No moving bar from row 5 on, no `Phase 2 of 3`, and no state opens the pane by itself.
    public func showWaiting(_ state: BlastSearchPaneState) {
        displayState = .waiting(state)
        waitingPane.show(state)
        showState(.waiting(state))
    }

    /// Whether a run's progress or a search's state fills the pane, which holds no verdict.
    public var showsASearchInProgress: Bool {
        switch displayState {
        case .loading, .waiting: return true
        case .empty, .results: return false
        }
    }

    /// The one writer of Re-run BLAST's enabled state and its reason, for a pane whose Re-run sends the picked rows again
    /// (ROWPANE-UX R4). A hidden Re-run stays as ``onRerunBlast`` left it. Send Again is a button of its own in the waiting
    /// pane, whose reason comes from the search and never from this rule.
    public func setRerunRule(enabled: Bool, reason: String?) {
        rerunBlastButton.isEnabled = enabled
        rerunBlastButton.toolTip = enabled ? nil : reason
        rerunBlastButton.setAccessibilityHelp(enabled ? nil : reason)
    }
}
