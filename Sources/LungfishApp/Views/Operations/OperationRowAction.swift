// OperationRowAction.swift - Commands that act on one Operations panel row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// One command that acts on a single ``OperationCenter/Item``.
///
/// Adopts ``RowCommand``, the shape every row-command enum in the app shares.
///
/// The Operations panel offers these commands from three places that must
/// always agree: the row's context menu, the log drawer's Actions pull-down,
/// and the row's accessibility custom actions. The Operations menu in the
/// menu bar offers the same commands for the selected row through the
/// responder chain (``OperationRowMenuActions``). ``available(for:)`` is the
/// single source of truth for which commands apply to an item, so no surface
/// can drift from the others.
enum OperationRowAction: String, CaseIterable, RowCommand, Sendable {
    case removePartialOutput
    case revealInterruptedRun
    case revealOutputs
    case runAgain
    case copyCLICommand
    case copyLog
    case viewLog
    case revealLog
    case copyFailureReport
    case openGitHubIssue
    case revealFailureReport
    case cancel
    case clear

    /// Menu title, as shown in the context menu and the menu bar.
    var title: String {
        switch self {
        case .removePartialOutput: return "Remove Partial Output\u{2026}"
        case .revealInterruptedRun: return "Reveal in Finder"
        case .revealOutputs: return "Reveal Output Files"
        case .runAgain: return "Run Again\u{2026}"
        case .copyCLICommand: return "Copy CLI Command"
        case .copyLog: return "Copy Log"
        case .viewLog: return "View Log"
        case .revealLog: return "Reveal Log in Finder"
        case .copyFailureReport: return "Copy Failure Report"
        case .openGitHubIssue: return "Open GitHub Issue"
        case .revealFailureReport: return "Reveal Failure Report in Finder"
        case .cancel: return "Cancel"
        case .clear: return "Clear"
        }
    }

    /// Title used in the menu bar, where "Cancel" alone would be ambiguous.
    var menuBarTitle: String {
        switch self {
        case .revealInterruptedRun: return "Reveal Interrupted Run in Finder"
        case .cancel: return "Cancel Selected Operation"
        case .clear: return "Clear Selected Operation"
        default: return title
        }
    }

    /// Stable identifier suffix shared by the menu bar item and the AX action.
    var identifierSlug: String {
        switch self {
        case .removePartialOutput: return "remove-partial-output"
        case .revealInterruptedRun: return "reveal-interrupted-run"
        case .revealOutputs: return "reveal-outputs"
        case .runAgain: return "run-again"
        case .copyCLICommand: return "copy-cli-command"
        case .copyLog: return "copy-log"
        case .viewLog: return "view-log"
        case .revealLog: return "reveal-log"
        case .copyFailureReport: return "copy-failure-report"
        case .openGitHubIssue: return "open-github-issue"
        case .revealFailureReport: return "reveal-failure-report"
        case .cancel: return "cancel"
        case .clear: return "clear"
        }
    }

    /// Key equivalent for the menu bar item, if the command has one.
    ///
    /// Option-Command letters are free of the app's existing bindings and of
    /// the genotype matrix's local Option-Command P, X, R and M keys.
    var keyEquivalent: RowCommandKeyEquivalent? {
        switch self {
        case .copyCLICommand: return RowCommandKeyEquivalent("c", [.command, .option])
        case .viewLog: return RowCommandKeyEquivalent("l", [.command, .option])
        case .revealOutputs: return RowCommandKeyEquivalent("o", [.command, .option])
        default: return nil
        }
    }

    /// The responder-chain selector the menu bar item sends.
    var menuSelector: Selector {
        switch self {
        case .removePartialOutput: return #selector(OperationRowMenuActions.removeSelectedOperationPartialOutput(_:))
        case .revealInterruptedRun: return #selector(OperationRowMenuActions.revealSelectedOperationInterruptedRun(_:))
        case .revealOutputs: return #selector(OperationRowMenuActions.revealSelectedOperationOutputs(_:))
        case .runAgain: return #selector(OperationRowMenuActions.runSelectedOperationAgain(_:))
        case .copyCLICommand: return #selector(OperationRowMenuActions.copySelectedOperationCLICommand(_:))
        case .copyLog: return #selector(OperationRowMenuActions.copySelectedOperationLog(_:))
        case .viewLog: return #selector(OperationRowMenuActions.viewSelectedOperationLog(_:))
        case .revealLog: return #selector(OperationRowMenuActions.revealSelectedOperationLog(_:))
        case .copyFailureReport: return #selector(OperationRowMenuActions.copySelectedOperationFailureReport(_:))
        case .openGitHubIssue: return #selector(OperationRowMenuActions.openSelectedOperationGitHubIssue(_:))
        case .revealFailureReport: return #selector(OperationRowMenuActions.revealSelectedOperationFailureReport(_:))
        case .cancel: return #selector(OperationRowMenuActions.cancelSelectedOperation(_:))
        case .clear: return #selector(OperationRowMenuActions.clearSelectedOperation(_:))
        }
    }

    /// The action a menu bar selector maps to, if any.
    static func action(for selector: Selector?) -> OperationRowAction? {
        command(for: selector)
    }

    /// Whether the command applies to the item right now.
    @MainActor
    func isAvailable(for item: OperationCenter.Item) -> Bool {
        switch self {
        case .removePartialOutput, .revealInterruptedRun:
            return item.state == .interrupted && item.interruptedRunDirectory != nil
        case .revealOutputs:
            return !item.outputURLs.isEmpty || !item.bundleURLs.isEmpty
        case .runAgain:
            return WorkflowOperationsWindowController.replaySourceBundleURL(for: item) != nil
        case .copyCLICommand:
            return item.cliCommand != nil
        case .copyLog, .viewLog, .revealLog:
            return !item.logEntries.isEmpty
        case .copyFailureReport, .openGitHubIssue:
            return item.state == .failed
        case .revealFailureReport:
            return item.state == .failed && item.failureReportURL != nil
        case .cancel:
            return item.isCancellable
        case .clear:
            return !item.isCancellable && !item.state.isActive
        }
    }

    /// The commands that apply to the item, in menu order.
    @MainActor
    static func available(for item: OperationCenter.Item) -> [OperationRowAction] {
        allCases.filter { $0.isAvailable(for: item) }
    }

    /// Menu sections in display order. A separator is drawn between sections
    /// that both contain at least one available command.
    static let menuSections: [[OperationRowAction]] = [
        [.removePartialOutput, .revealInterruptedRun, .revealOutputs, .runAgain,
         .copyCLICommand, .copyLog, .viewLog, .revealLog,
         .copyFailureReport, .openGitHubIssue, .revealFailureReport],
        [.cancel, .clear],
    ]
}

/// A context-menu item's payload: which command, on which operation.
struct OperationRowActionRequest {
    let action: OperationRowAction
    let itemID: UUID
}

/// Menu bar handlers for the selected Operations panel row.
///
/// The items in Operations > Selected Operation send these to the first
/// responder, so they are enabled only while the Operations window is key and
/// ``OperationsPanelViewController`` validates them against its selection.
@MainActor
@objc protocol OperationRowMenuActions {
    func removeSelectedOperationPartialOutput(_ sender: Any?)
    func revealSelectedOperationInterruptedRun(_ sender: Any?)
    func revealSelectedOperationOutputs(_ sender: Any?)
    func runSelectedOperationAgain(_ sender: Any?)
    func copySelectedOperationCLICommand(_ sender: Any?)
    func copySelectedOperationLog(_ sender: Any?)
    func viewSelectedOperationLog(_ sender: Any?)
    func revealSelectedOperationLog(_ sender: Any?)
    func copySelectedOperationFailureReport(_ sender: Any?)
    func openSelectedOperationGitHubIssue(_ sender: Any?)
    func revealSelectedOperationFailureReport(_ sender: Any?)
    func cancelSelectedOperation(_ sender: Any?)
    func clearSelectedOperation(_ sender: Any?)
}
