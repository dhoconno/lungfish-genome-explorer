// ReferenceSequenceSortKey.swift - Presort keys for the record table's sequence column
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

/// Presort keys that order sequence names the way `localizedStandardCompare` orders
/// the names references use. They are built once per row, so the record table sorts
/// 905,628 sequences with about one comparator call each rather than about 28.
///
/// A key folds letters to lowercase and writes each run of digits as its count of
/// significant digits followed by those digits, so runs order by value. Space and
/// punctuation rank below digits and digits below letters, in the comparator's order,
/// and bytes outside ASCII pass through. The keys only arrange the rows. The table's
/// comparator still decides the order (see `BatchTableDisplayOrder`), so a name the
/// keys place wrongly, such as one that differs from another only in case or leading
/// zeros, costs a little time and never order.
enum ReferenceSequenceSortKey {

    /// Keys for `names`, in the same order.
    static func keys(for names: [String]) -> [String] {
        var key: [UInt8] = []
        return names.map { name in
            key.removeAll(keepingCapacity: true)
            var name = name
            name.withUTF8 { appendKey(of: $0, to: &key) }
            return String(decoding: key, as: UTF8.self)
        }
    }

    /// Space, then ASCII punctuation, in the order `localizedStandardCompare` sorts them.
    private static let punctuationInOrder = Array(" _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$".utf8)

    /// The key byte of each ASCII byte, with `0` marking a digit, which starts a run.
    /// Control characters take the lowest byte.
    private static let asciiKeyBytes: [UInt8] = {
        var table = [UInt8](repeating: 1, count: 128)
        for (rank, byte) in punctuationInOrder.enumerated() {
            table[Int(byte)] = 2 + UInt8(rank)
        }
        for byte in UInt8(ascii: "0")...UInt8(ascii: "9") {
            table[Int(byte)] = 0
        }
        for byte in UInt8(ascii: "a")...UInt8(ascii: "z") {
            table[Int(byte)] = byte
            table[Int(byte) - 32] = byte
        }
        return table
    }()

    /// A digit run's first key byte is this plus its count of significant digits,
    /// which places it above every punctuation byte and, up to the cap, below every letter.
    private static let digitRunBase: UInt8 = 0x23
    private static let longestCountedRun = 60

    private static func appendKey(of bytes: UnsafeBufferPointer<UInt8>, to key: inout [UInt8]) {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte < 0x80, asciiKeyBytes[Int(byte)] == 0 else {
                key.append(byte < 0x80 ? asciiKeyBytes[Int(byte)] : byte)
                index += 1
                continue
            }
            var end = index + 1
            while end < bytes.count, (0x30...0x39).contains(bytes[end]) { end += 1 }
            var start = index
            while start < end - 1, bytes[start] == 0x30 { start += 1 }
            key.append(digitRunBase + UInt8(min(end - start, longestCountedRun)))
            key.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<end]))
            index = end
        }
    }
}
