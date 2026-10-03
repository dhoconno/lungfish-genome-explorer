import CryptoKit
import Darwin
import Foundation
import LungfishIO

actor ProjectStorageCleanupIdentityGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    static let shared = ProjectStorageCleanupIdentityGate()

    private var held: Set<FileSystemObjectIdentity> = []
    private var waiters: [FileSystemObjectIdentity: [Waiter]] = [:]

    func acquire(_ identity: FileSystemObjectIdentity) async throws {
        try Task.checkCancellation()
        if !held.contains(identity) {
            held.insert(identity)
            return
        }
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[identity, default: []].append(
                    Waiter(id: waiterID, continuation: continuation)
                )
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    identity: identity,
                    waiterID: waiterID
                )
            }
        }
        guard acquired else { throw CancellationError() }
        guard !Task.isCancelled else {
            release(identity)
            throw CancellationError()
        }
    }

    func release(_ identity: FileSystemObjectIdentity) {
        if var queued = waiters[identity], !queued.isEmpty {
            let waiter = queued.removeFirst()
            waiters[identity] = queued.isEmpty ? nil : queued
            waiter.continuation.resume(returning: true)
        } else {
            held.remove(identity)
        }
    }

    private func cancelWaiter(
        identity: FileSystemObjectIdentity,
        waiterID: UUID
    ) {
        guard var queued = waiters[identity],
              let index = queued.firstIndex(where: { $0.id == waiterID })
        else {
            return
        }
        let waiter = queued.remove(at: index)
        waiters[identity] = queued.isEmpty ? nil : queued
        waiter.continuation.resume(returning: false)
    }
}
