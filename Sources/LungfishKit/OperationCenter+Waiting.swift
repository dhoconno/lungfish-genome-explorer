// OperationCenter+Waiting.swift - The row state of work that waits on someone else, with no process behind it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public extension OperationCenter.Item.State {
    /// Whether the row has reached its end, the one set a person can clear. A waiting row has not, though it is not active.
    var hasEnded: Bool {
        !isActive && self != .waiting
    }
}

public extension OperationCenter {
    /// Parks a running row as waiting, with `detail` as its words (ARCH-BLAST-RESILIENCE section 6).
    ///
    /// No process sits behind a waiting row. So it is not among ``activeItems``, it raises no quit or close alert,
    /// ``cancelAll()`` leaves it alone, and it holds no bundle lock, since the lock check counts only active rows.
    /// - Returns: Whether the row took the state, which it does only while it runs or already waits.
    @discardableResult
    func park(id: UUID, detail: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .running || items[index].state == .waiting else { return false }
        let wasRunning = items[index].state == .running
        items[index].state = .waiting
        items[index].detail = detail
        items[index].progressEvidence = nil
        changes.send(.updated(id: id, index: index))
        if wasRunning { postStateChangedNotification(id: id, state: .waiting) }
        return true
    }

    /// Sets what a waiting row's Cancel runs, once the process that began the row has gone.
    func setWaitingCancelCallback(id: UUID, callback: @escaping @Sendable () -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .waiting else { return }
        items[index].onCancel = callback
    }

    /// Takes a waiting row back to running, for a pass that has something to bring back.
    /// - Returns: Whether the row took the state.
    @discardableResult
    func reopen(id: UUID, detail: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .waiting else { return false }
        items[index].state = .running
        items[index].detail = detail
        changes.send(.updated(id: id, index: index))
        postStateChangedNotification(id: id, state: .running)
        return true
    }

    /// Gives a row that has settled Cancelled the words of a person's Stop, which say more than `Cancelled by user`.
    func setStoppedWords(id: UUID, words: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .cancelled else { return }
        items[index].detail = words
        changes.send(.updated(id: id, index: index))
    }

    /// Records the command that goes on with a waiting row, the pattern of ``setCommand(id:command:)``, which takes only
    /// an active row.
    func setWaitingCommand(id: UUID, command: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .waiting else { return }
        items[index].cliCommand = command
        changes.send(.updated(id: id, index: index))
    }
}
