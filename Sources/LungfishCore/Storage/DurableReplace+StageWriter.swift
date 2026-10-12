// DurableReplace+StageWriter.swift - The stage file a streaming publication writes into
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

extension DurableReplace {
    /// The open stage file of one publication, handed to the `body` of
    /// ``replace(named:in:recovery:beforePublish:observe:writing:)``.
    ///
    /// It appends with `write(2)`, retries a write that a signal interrupted,
    /// continues after a short write and reports every other failure as a
    /// thrown ``ReplaceError``. `FileHandle.write(_:)` raises an Objective-C
    /// exception for the same failures, which Swift cannot catch, so a full
    /// disk would end the process (Phase 2.9 lane S12). The writer is valid
    /// only inside `body`, because the publication closes the file when
    /// `body` returns.
    package struct StageWriter {
        let descriptor: Int32
        let path: String
        let writeBytes: @Sendable (Int32, UnsafeRawPointer, Int) -> Int

        /// Appends `data` to the stage file.
        package func write(_ data: Data) throws {
            try data.withUnsafeBytes { try write($0) }
        }

        /// Appends `bytes` to the stage file.
        package func write(_ bytes: UnsafeRawBufferPointer) throws {
            guard var cursor = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = writeBytes(descriptor, cursor, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw ReplaceError.systemFailure(
                        path: path,
                        operation: "write the stage file",
                        code: count < 0 ? errno : EIO
                    )
                }
                remaining -= count
                cursor = cursor.advanced(by: count)
            }
        }
    }
}
